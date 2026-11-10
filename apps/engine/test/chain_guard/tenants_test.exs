defmodule ChainGuard.TenantsTest do
  use ChainGuard.DataCase, async: false

  import Plug.Conn
  import Phoenix.ConnTest, except: [connect: 2, connect: 3]
  import Phoenix.ChannelTest
  import ChainGuard.Fixtures

  alias ChainGuard.{Audit, Chain, Invariants, Stats, Tenants}
  alias ChainGuard.Alerts.Manager
  alias ChainGuard.Audit.Writer
  alias ChainGuard.Tenants.Matcher

  @endpoint ChainGuardWeb.Endpoint

  setup do
    Chain.reset()
    Manager.reset()
    Stats.reset()
    Invariants.reset()
    {:ok, org_a, _, key_a} = Tenants.create_org("Acme Risk")
    {:ok, org_b, _, key_b} = Tenants.create_org("Beta Fund")
    %{a: org_a, b: org_b, key_a: key_a, key_b: key_b}
  end

  defp api(key), do: build_conn() |> put_req_header("authorization", "Bearer " <> key)

  # Forward one org topic's messages to the test, tagged with `tag`.
  defp listen(org_id, tag) do
    test = self()
    ready = make_ref()

    spawn_link(fn ->
      Phoenix.PubSub.subscribe(ChainGuard.PubSub, "alerts:org:" <> org_id)
      send(test, ready)

      Stream.repeatedly(fn ->
        receive do
          {:org_alert, event, alert} -> send(test, {tag, event, alert})
        end
      end)
      |> Stream.run()
    end)

    assert_receive ^ready
  end

  defp watch(key, address),
    do: api(key) |> post("/api/org/watchlist", %{address: address, label: "treasury"})

  describe "keys and roles" do
    test "keys are shown once, stored hashed, and checked in constant time", %{a: a, key_a: key} do
      assert "cg_" <> _ = key
      assert {:ok, %{org: %{id: id}, role: "admin"}} = Tenants.authenticate(key)
      assert id == a.id

      [stored] = Tenants.list_keys(a.id)
      refute stored.secret_hash =~ key
      assert byte_size(stored.secret_hash) == 32

      assert Tenants.authenticate(key <> "x") == :error
      assert Tenants.authenticate("cg_nope_nope") == :error
      assert Tenants.authenticate("not-a-key") == :error

      {:ok, _} = Tenants.revoke_key(a.id, stored.id)
      assert Tenants.authenticate(key) == :error
    end

    test "invariant 6: roles gate what a key can do", %{a: a, key_a: admin} do
      {:ok, _, viewer} = Tenants.create_key(a, "viewer")
      {:ok, _, analyst} = Tenants.create_key(a, "analyst")
      addr = addr("wallet")

      assert build_conn() |> get("/api/org") |> json_response(401)
      assert %{"role" => "viewer"} = api(viewer) |> get("/api/org") |> json_response(200)
      assert viewer |> watch(addr) |> json_response(403)
      assert %{"address" => ^addr} = analyst |> watch(addr) |> json_response(201)
      assert api(analyst) |> get("/api/org/routes") |> json_response(403)
      assert api(admin) |> get("/api/org/routes") |> json_response(200)
    end
  end

  describe "isolation" do
    test "invariant 6: one org can never read or change another org's watchlist, routes or keys",
         %{key_a: ka, key_b: kb} do
      addr = addr("acme-treasury")
      %{"id" => watch_id} = ka |> watch(addr) |> json_response(201)

      %{"id" => route_id} =
        api(ka)
        |> post("/api/org/routes", %{
          kind: "webhook",
          min_severity: "medium",
          config: %{url: "https://hooks.acme.example/cg?token=s3cret", secret: "whsec"}
        })
        |> json_response(201)

      # B sees none of A's configuration...
      assert %{"entries" => []} = api(kb) |> get("/api/org/watchlist") |> json_response(200)
      assert %{"routes" => []} = api(kb) |> get("/api/org/routes") |> json_response(200)
      assert %{"keys" => [_only_b]} = api(kb) |> get("/api/org/keys") |> json_response(200)
      # ...and cannot delete it by id.
      assert api(kb) |> delete("/api/org/watchlist/#{watch_id}") |> response(404)
      assert api(kb) |> delete("/api/org/routes/#{route_id}") |> response(404)

      assert %{"entries" => [%{"address" => ^addr}]} =
               api(ka) |> get("/api/org/watchlist") |> json_response(200)

      # Route secrets never come back out, even to their own org.
      %{"routes" => [r]} = api(ka) |> get("/api/org/routes") |> json_response(200)
      assert r["destination"] == %{"url" => "https://hooks.acme.example/cg"}
      refute inspect(r) =~ "s3cret" or inspect(r) =~ "whsec"
    end

    test "invariant 6: an alert reaches only the orgs that watch its addresses", %{
      a: a,
      b: b,
      key_a: ka
    } do
      enable_audit()
      blk = block(10)
      records = euler_like_drain(blk)
      # A watches the drained protocol's address; B watches something else.
      ka |> watch(addr("euler")) |> json_response(201)
      {:ok, _} = Tenants.add_watch(b.id, %{address: addr("unrelated")})
      :ok = Matcher.sync()

      listen(a.id, :a)
      listen(b.id, :b)
      Enum.each(adopt(1, blk, records), &(:ok = Chain.handle(&1)))

      assert_receive {:a, :raised, %{rule_id: "flash-loan-drain"}}
      assert_receive {:a, :raised, %{rule_id: "euler-outflow"}}
      refute_receive {:b, _, _}, 100

      # A's API lists it; B's does not.
      assert %{"alerts" => [_ | _]} = api(ka) |> get("/api/org/alerts") |> json_response(200)

      # The match is in the audit chain, scoped to A.
      :ok = Writer.flush()
      assert [_ | _] = Audit.list(kind: "org.match", org_id: a.id)
      assert Audit.list(kind: "org.match", org_id: b.id) == []
      assert Audit.list(kind: "org.match") == [], "not visible on the public audit API"
      assert {:ok, _} = Audit.verify()
    end

    test "invariant 6: org channels require that org's key", %{a: a, b: b, key_a: ka} do
      {:ok, socket} = connect(ChainGuardWeb.UserSocket, %{"token" => ka})
      assert {:ok, %{alerts: []}, _} = subscribe_and_join(socket, "alerts:org:" <> a.id, %{})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, "alerts:org:" <> b.id, %{})

      {:ok, anonymous} = connect(ChainGuardWeb.UserSocket, %{})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(anonymous, "alerts:org:" <> a.id, %{})

      # Public topics stay public.
      assert {:ok, _, _} = subscribe_and_join(anonymous, "alerts:global", %{})
      # A bad token is refused outright, not downgraded to anonymous.
      assert :error = connect(ChainGuardWeb.UserSocket, %{"token" => "cg_bad_key"})
    end
  end

  describe "validation and limits" do
    test "watchlist and routes validate their input", %{key_a: ka} do
      assert %{"errors" => %{"address" => [_]}} = ka |> watch("0x123") |> json_response(422)

      assert %{"errors" => %{"config" => [msg]}} =
               api(ka)
               |> post("/api/org/routes", %{
                 kind: "webhook",
                 config: %{url: "http://evil.example", secret: "s"}
               })
               |> json_response(422)

      assert msg =~ "https"
    end

    test "the API is rate limited per key", %{key_a: ka} do
      Application.put_env(:chain_guard, :rate_limit, keyed: 3)
      on_exit(fn -> Application.delete_env(:chain_guard, :rate_limit) end)

      statuses = for _ <- 1..4, do: api(ka) |> get("/api/org") |> Map.get(:status)
      assert statuses == [200, 200, 200, 429]
    end
  end
end
