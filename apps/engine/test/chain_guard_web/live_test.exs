defmodule ChainGuardWeb.LiveTest do
  use ChainGuardWeb.ConnCase, async: false
  import Phoenix.ChannelTest
  import ChainGuard.Fixtures

  @endpoint ChainGuardWeb.Endpoint

  alias ChainGuard.{Chain, Stats}
  alias ChainGuard.Alerts.Manager

  setup do
    Chain.reset()
    Manager.reset()
    Stats.reset()
    ChainGuard.Invariants.reset()
    :ok
  end

  test "alerts channel: snapshot on join, then live pushes" do
    {:ok, reply, _socket} =
      socket(ChainGuardWeb.UserSocket)
      |> subscribe_and_join(ChainGuardWeb.AlertsChannel, "alerts:global")

    assert reply.alerts == []

    b = block(10)
    Enum.each(adopt(1, b, euler_like_drain(b)), &Chain.handle/1)
    assert_push "alert:raised", %{rule_id: "flash-loan-drain", severity: :critical}

    Chain.handle(orphan(7, b))
    assert_push "alert:retracted", %{status: :retracted}
  end

  test "live channel streams block summaries with notable flows" do
    {:ok, _reply, _socket} =
      socket(ChainGuardWeb.UserSocket) |> subscribe_and_join(ChainGuardWeb.LiveChannel, "live:1")

    b = block(10)
    Enum.each(adopt(1, b, euler_like_drain(b)), &Chain.handle/1)

    assert_push "block", %{
      number: 10,
      records: 5,
      txs: 1,
      alerts: [_, _],
      notable: notable,
      flows: flows
    }

    assert Enum.any?(notable, &(&1.kind == "flash_loan"))
    # Fund-flow edges for the graph, largest first, with labels.
    assert [%{usd: top, from_label: %{"name" => "Euler Finance (main proxy)"}} | _] = flows
    assert top == 38_904_507.0
    assert_push "invariants", %{statuses: statuses}
    assert [%{number: 10, edges: [_ | _]}] = ChainGuard.Chain.recent_flows(1)
    Chain.handle(orphan(7, b))
    assert ChainGuard.Chain.recent_flows(1) == [], "orphaned flows leave the graph"
    assert %{state: :breached} = Enum.find(statuses, &(&1.id == "euler-outflow"))

    assert {:error, %{reason: "unknown chain"}} =
             socket(ChainGuardWeb.UserSocket)
             |> subscribe_and_join(ChainGuardWeb.LiveChannel, "live:abc")
  end

  test "JSON API", %{conn: conn} do
    # A live block (timestamped now), so it feeds the latency figures.
    b = %{block(10) | "timestamp" => System.system_time(:second)}
    Enum.each(adopt(1, b, euler_like_drain(b)), &Chain.handle/1)

    assert %{"status" => "ok", "read_only" => true, "rules_loaded" => 5, "rule_errors" => []} =
             conn |> get("/api/health") |> json_response(200)

    assert %{"rules" => rules} = conn |> get("/api/rules") |> json_response(200)
    assert Enum.all?(rules, &(&1["weakness"]["class"] != nil))

    assert %{"alerts" => [_, _] = alerts} =
             conn |> get("/api/alerts?limit=5") |> json_response(200)

    assert Enum.all?(alerts, &(&1["severity"] == "critical" and &1["evidence"] != []))
    assert %{"id" => id} = Enum.find(alerts, &(&1["lane"] == "rule"))
    assert Enum.any?(alerts, &(&1["lane"] == "invariant"))

    assert %{"id" => ^id} = conn |> get("/api/alerts/#{id}") |> json_response(200)
    assert conn |> get("/api/alerts/nope") |> json_response(404)

    assert %{
             "counters" => %{"blocks" => 1, "records" => 5, "replayed_blocks" => 0},
             "latency_ms" => %{"detect" => %{"samples" => 1}}
           } =
             conn |> get("/api/stats") |> json_response(200)
  end

  test "CORS allows the configured dashboard origin only", %{conn: conn} do
    ok = conn |> put_req_header("origin", "http://localhost:4300") |> get("/api/health")
    assert get_resp_header(ok, "access-control-allow-origin") == ["http://localhost:4300"]
    other = build_conn() |> put_req_header("origin", "https://evil.example") |> get("/api/health")
    assert get_resp_header(other, "access-control-allow-origin") == []
  end
end
