defmodule ChainGuard.AnomalyTest do
  use ExUnit.Case, async: false

  alias ChainGuard.{Anomaly, Chain, Invariants, Stats}
  alias ChainGuard.Alerts.Manager
  alias ChainGuard.Rules.{Evaluator, Rule}
  import ChainGuard.Fixtures

  setup do
    Chain.reset()
    Manager.reset()
    Stats.reset()
    Invariants.reset()
    Anomaly.reset()
    Application.put_env(:chain_guard, :anomaly, url: "http://ml.test", plug: {Req.Test, :ml})
    # The ML client is a long-lived named process: share stubs with it (async: false).
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Application.put_env(:chain_guard, :anomaly, nil) end)
    :ok
  end

  defp quiet_block(n) do
    b = block(n)
    {b, [transfer(b, 0, addr("a"), addr("b"), 50.0)]}
  end

  test "ML lane: anomalies become alerts capped at medium, with evidence and reasons" do
    {b, [r]} = quiet_block(10)
    test = self()

    Req.Test.stub(:ml, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posted, conn.request_path, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "anomalies" => [
          %{
            "kind" => "tx_graph",
            "key" => "tx_graph:#{r["tx_hash"]}",
            "score" => 0.81,
            "threshold" => 0.66,
            "title" => "Unusual fund-flow graph",
            "reasons" => ["total usd $197,836,015 (p99.9 of normal: $6,526,924)"],
            "record_ids" => [r["id"]]
          }
        ],
        "model" => %{"blocks_learned" => 1}
      })
    end)

    Anomaly.observe(Evaluator.context(1, b, [r]))
    Anomaly.sync()

    assert_received {:posted, "/v1/blocks",
                     %{"chain_id" => 1, "block" => %{"number" => 10}, "records" => [compact]}}

    assert compact["kind"] == "erc20_transfer" and compact["value_usd"] == 50.0

    assert [a] = Manager.recent()
    assert a.lane == "ml" and a.rule_id == "ml-tx-graph"
    assert a.severity == :medium
    assert [%{record_id: id}] = a.evidence
    assert id == r["id"]
    assert Enum.any?(a.notes, &(&1 =~ "p99.9 of normal"))
    assert Enum.any?(a.notes, &(&1 =~ "capped at medium"))
    assert %{state: :ok, blocks_scored: 1, alerts_raised: 1} = Anomaly.status()
  end

  test "ML lane never raises above medium, even if a candidate asks for critical" do
    {b, [r]} = quiet_block(11)

    rule = %Rule{
      id: "ml-tx-graph",
      version: 1,
      severity: :critical,
      weakness: %{class: "anomalous-behavior", refs: []},
      dedup_window_s: 60,
      rate_per_minute: 5
    }

    [a] =
      Manager.submit([
        %{
          rule: rule,
          lane: "ml",
          dedup_key: "k",
          title: "t",
          evidence: [r],
          block: b,
          chain_id: 1
        }
      ])

    assert a.severity == :medium and a.requested_severity == :critical
    assert hd(a.notes) =~ "the ML lane never raises high or critical"
  end

  test "an anomaly the service cannot tie to this block's records is dropped" do
    {b, [r]} = quiet_block(12)

    Req.Test.stub(:ml, fn conn ->
      Req.Test.json(conn, %{
        "anomalies" => [
          %{"kind" => "protocol_flow", "key" => "k", "title" => "t", "record_ids" => ["0xnope"]}
        ]
      })
    end)

    Anomaly.observe(Evaluator.context(1, b, [r]))
    Anomaly.sync()
    assert Manager.recent() == []
  end

  test "service down: the lane degrades and skips blocks; rules and invariants are unaffected" do
    Req.Test.stub(:ml, &Req.Test.transport_error(&1, :econnrefused))
    b = block(13)
    msgs = adopt(1, b, euler_like_drain(b))
    Enum.each(msgs, &(:ok = Chain.handle(&1)))
    Anomaly.sync()

    assert %{state: :degraded, consecutive_failures: 1, last_error: err} = Anomaly.status()
    assert err =~ "connection refused"
    # The other two lanes raised their alerts regardless.
    assert Enum.map(Manager.recent(), & &1.lane) |> Enum.sort() == ["invariant", "rule"]

    # While backing off, the next block is skipped, not queued.
    {b2, rs} = quiet_block(14)
    Anomaly.observe(Evaluator.context(1, b2, rs))
    Anomaly.sync()
    assert Stats.snapshot().counters.ml_skipped == 1
  end

  test "orphaned blocks are forwarded so the model unlearns them" do
    test = self()

    Req.Test.stub(:ml, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posted, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, %{"unlearned" => true})
    end)

    b = block(15)
    Anomaly.orphan(1, b["hash"])
    Anomaly.sync()
    assert_received {:posted, "/v1/orphan", %{"chain_id" => 1, "block_hash" => hash}}
    assert hash == b["hash"]
  end

  test "disabled when not configured" do
    Application.put_env(:chain_guard, :anomaly, nil)
    {b, rs} = quiet_block(16)
    Anomaly.observe(Evaluator.context(1, b, rs))
    Anomaly.sync()
    assert %{state: :disabled, blocks_scored: 0} = Anomaly.status()
  end
end
