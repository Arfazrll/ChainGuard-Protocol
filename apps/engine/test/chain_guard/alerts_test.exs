defmodule ChainGuard.Test.Connector do
  @moduledoc false
  @behaviour ChainGuard.Alerts.Connector
  @impl true
  def deliver(event, alert, opts) do
    send(Keyword.fetch!(opts, :pid), {:delivered, event, alert})
    :ok
  end
end

defmodule ChainGuard.AlertsTest do
  use ExUnit.Case, async: false

  alias ChainGuard.Alerts.{Fanout, Manager, PagerDuty, Telegram, Webhook}
  alias ChainGuard.Rules
  alias ChainGuard.Rules.Evaluator
  import ChainGuard.Fixtures

  setup do
    Manager.reset()

    Application.put_env(:chain_guard, :connectors, [
      {ChainGuard.Test.Connector, pid: self(), min_severity: :low}
    ])

    Phoenix.PubSub.subscribe(ChainGuard.PubSub, "alerts:global")
    on_exit(fn -> Application.put_env(:chain_guard, :connectors, []) end)
    {rules, []} = Rules.load_dir(Rules.rules_dir())
    {:ok, rules: Map.new(rules, &{&1.id, &1})}
  end

  defp candidates(rule, records) do
    b = hd(records)["block"]
    {cands, _} = Evaluator.evaluate(rule, %{}, Evaluator.context(1, b, records))
    cands
  end

  test "a critical alert with two attesters stays critical and fans out", %{rules: rules} do
    [a] = Manager.submit(candidates(rules["flash-loan-drain"], euler_like_drain(block(10))))
    assert a.severity == :critical
    assert a.status == :provisional
    assert a.min_attestations == 2
    assert a.sources == ["node-a", "node-b"]
    assert a.weakness.class == "flash-loan-attack"
    assert a.tx_hashes == [hash("drain-tx")]
    assert Enum.any?(a.evidence, &(&1.kind == "flash_loan"))
    assert_receive {:delivered, :raised, ^a}
    assert_receive {:alert, :raised, ^a}
  end

  test "invariant 2: high/critical evidence from a single node is capped at medium", %{
    rules: rules
  } do
    records = euler_like_drain(block(10), attested_by: ["only-node"])
    [a] = Manager.submit(candidates(rules["flash-loan-drain"], records))
    assert a.severity == :medium
    assert a.requested_severity == :critical
    assert [note] = a.notes
    assert note =~ "attested by 1 node"
    assert Manager.stats().capped == 1
  end

  test "invariant 5: duplicates merge instead of paging again", %{rules: rules} do
    c = candidates(rules["flash-loan-drain"], euler_like_drain(block(10)))
    [a] = Manager.submit(c)
    assert_receive {:delivered, :raised, _}
    [b] = Manager.submit(c)
    assert b.id == a.id
    assert b.occurrences == 2
    refute_receive {:delivered, _, _}, 50
    assert_receive {:alert, :updated, _}
    assert length(Manager.recent()) == 1
  end

  test "invariant 5: per-rule rate limit suppresses the excess", %{rules: rules} do
    rule = rules["privileged-change"]
    pool = addr("pool")

    for i <- 1..(rule.rate_per_minute + 3) do
      b = block(100 + i)

      r =
        record(
          b,
          0,
          %{
            "kind" => "role_granted",
            "role" => hash("r"),
            "account" => addr("a#{i}"),
            "sender" => addr("s")
          },
          contract: pool,
          labels: [label("contract", pool, "Pool", "lending")]
        )

      Manager.submit(candidates(rule, [r]), 1_000_000)
    end

    assert Manager.stats().raised == rule.rate_per_minute
    assert Manager.stats().suppressed == 3
    # A minute later the bucket refills.
    b = block(999)

    r =
      record(
        b,
        0,
        %{
          "kind" => "role_granted",
          "role" => hash("r"),
          "account" => addr("late"),
          "sender" => addr("s")
        },
        contract: pool,
        labels: [label("contract", pool, "Pool", "lending")]
      )

    assert [_] = Manager.submit(candidates(rule, [r]), 1_000_000 + 60_000)
  end

  test "invariant 3: an orphaned evidence block retracts the alert and tells connectors", %{
    rules: rules
  } do
    b = block(10)
    [a] = Manager.submit(candidates(rules["flash-loan-drain"], euler_like_drain(b)))
    assert_receive {:delivered, :raised, _}
    [r] = Manager.retract_block(1, b["hash"], "block #10 orphaned by a reorg")
    assert r.id == a.id
    assert r.status == :retracted
    assert List.last(r.notes) =~ "orphaned"
    assert_receive {:delivered, :retracted, ^r}
    # The same attack re-included in the canonical block raises a fresh alert.
    [fresh] =
      Manager.submit(
        candidates(rules["flash-loan-drain"], euler_like_drain(block(10, "canonical")))
      )

    assert fresh.id != a.id
    assert fresh.status == :provisional
  end

  test "an alert becomes final once every evidence block is finalized", %{rules: rules} do
    b = block(10)
    [a] = Manager.submit(candidates(rules["flash-loan-drain"], euler_like_drain(b)))
    [f] = Manager.finalize_block(1, b["hash"])
    assert f.id == a.id and f.status == :final
    assert_receive {:alert, :finalized, _}
    assert Manager.retract_block(1, b["hash"], "late") == [], "final alerts are never retracted"
  end

  test "system alerts for monitor integrity" do
    a = Manager.system_alert(1, "Ingestion halted", :critical, "reorg below finality")
    assert a.system and a.severity == :critical
    assert_receive {:delivered, :raised, ^a}
  end

  test "connectors filter by minimum severity", %{rules: rules} do
    Application.put_env(:chain_guard, :connectors, [
      {ChainGuard.Test.Connector, pid: self(), min_severity: :high}
    ])

    tc = addr("tc")

    r =
      record(block(3), 0, %{"kind" => "unknown"},
        contract: tc,
        labels: [label("contract", tc, "Tornado", "mixer")]
      )

    [a] = Manager.submit(candidates(rules["mixer-interaction"], [r]))
    assert a.severity == :low
    refute_receive {:delivered, _, _}, 50
  end

  describe "connectors" do
    setup %{rules: rules} do
      [a] = Manager.submit(candidates(rules["flash-loan-drain"], euler_like_drain(block(10))))
      {:ok, alert: a}
    end

    test "webhook body is signed so receivers can verify and reject forgeries", %{alert: a} do
      parent = self()

      Req.Test.stub(:hook, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:hook, Plug.Conn.get_req_header(conn, "x-chainguard-signature"), body})
        Req.Test.json(conn, %{ok: true})
      end)

      assert :ok =
               Webhook.deliver(:raised, a,
                 url: "http://hooks.test/x",
                 secret: "s3cret",
                 plug: {Req.Test, :hook}
               )

      assert_receive {:hook, [sig], body}
      [_, ts, mac] = Regex.run(~r/^t=(\d+),v1=([0-9a-f]{64})$/, sig)
      assert mac == Webhook.sign("s3cret", ts, body)
      refute mac == Webhook.sign("wrong", ts, body)
      decoded = Jason.decode!(body)
      assert decoded["event"] == "alert.raised"
      assert decoded["alert"]["severity"] == "critical"
      assert decoded["alert"]["rule_id"] == "flash-loan-drain"
    end

    test "failed deliveries are retried, then given up", %{alert: a} do
      parent = self()

      Req.Test.stub(:flaky, fn conn ->
        send(parent, :attempt)
        Plug.Conn.send_resp(conn, 503, "busy")
      end)

      assert {:error, {:http_status, 503}} =
               Fanout.deliver(Webhook, :raised, a,
                 url: "http://hooks.test/x",
                 secret: "s",
                 plug: {Req.Test, :flaky},
                 attempts: 3
               )

      for _ <- 1..3, do: assert_receive(:attempt)
      refute_receive :attempt, 20
    end

    test "PagerDuty triggers on raise and resolves on retraction", %{alert: a} do
      parent = self()

      Req.Test.stub(:pd, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:pd, Jason.decode!(body)})
        conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{status: "success"})
      end)

      opts = [routing_key: "rk", plug: {Req.Test, :pd}]
      assert :ok = PagerDuty.deliver(:raised, a, opts)
      assert_receive {:pd, %{"event_action" => "trigger", "dedup_key" => key, "payload" => p}}
      assert key == a.id and p["severity"] == "critical"
      assert :ok = PagerDuty.deliver(:retracted, %{a | status: :retracted}, opts)
      assert_receive {:pd, %{"event_action" => "resolve", "dedup_key" => ^key}}
    end

    test "Telegram message is plain text with the evidence references", %{alert: a} do
      text = Telegram.text(:raised, a)
      assert text =~ "[CRITICAL]"
      assert text =~ hash("drain-tx")
      assert Telegram.text(:retracted, a) =~ "RETRACTED"
    end
  end
end
