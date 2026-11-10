defmodule ChainGuard.InvariantsTest do
  use ExUnit.Case, async: false

  alias ChainGuard.{Chain, Invariants, Stats}
  alias ChainGuard.Alerts.Manager
  alias ChainGuard.Invariants.{Check, Invariant, Monitor}
  alias ChainGuard.Rules.Evaluator
  import ChainGuard.Fixtures

  @fixtures Path.expand("../fixtures", __DIR__)
  @agg "0x00000000000000000000000000000000000000aa"

  defp inv!(yaml) do
    {:ok, inv} = Invariant.from_yaml(yaml)
    inv
  end

  defp peg,
    do:
      inv!("""
      id: test-peg
      kind: peg
      name: TEST holds its peg
      protocol: test
      weakness: { class: stablecoin-depeg }
      feed: { name: TEST/USD, decimals: 8, aggregators: ["#{@agg}"] }
      peg_usd: 1.0
      bands:
        - { deviation: 0.05, severity: critical }
        - { deviation: 0.02, severity: high }
      """)

  defp oracle,
    do:
      inv!("""
      id: test-oracle
      kind: oracle
      name: TEST/USD fresh and sane
      protocol: test
      weakness: { class: oracle-manipulation }
      feed: { name: TEST/USD, decimals: 8, aggregators: ["#{@agg}"] }
      max_jump: 0.10
      max_age_seconds: 3600
      """)

  defp outflow(limit \\ 5_000_000, within \\ 3),
    do:
      inv!("""
      id: test-outflow
      kind: outflow
      name: Vault outflow
      protocol: vault
      weakness: { class: abnormal-tvl-drawdown }
      within_blocks: #{within}
      max_net_outflow_usd: #{limit}
      severity: critical
      """)

  defp answer(block, i, price, opts \\ []) do
    record(
      block,
      i,
      %{
        "kind" => "oracle_answer_updated",
        "answer" => Integer.to_string(round(price * 1.0e8)),
        "round_id" => to_string(block["number"]),
        "updated_at" => block["timestamp"]
      },
      Keyword.put_new(opts, :contract, @agg)
    )
  end

  defp ctx(block, records), do: Evaluator.context(1, block, records)

  defp run(inv, steps) do
    Enum.reduce(steps, {[], Check.init(inv)}, fn {b, recs}, {acc, st} ->
      {cs, st} = Check.evaluate(inv, st, ctx(b, recs))
      {acc ++ cs, st}
    end)
  end

  defp vault(role), do: label(role, addr("vault"), "Vault", "lending", "vault")

  describe "definitions" do
    test "every bundled invariant loads and validates" do
      {invs, errors} = Invariants.load_dir(Invariants.dir())
      assert errors == []
      assert length(invs) == 9
      assert Enum.all?(invs, &(&1.weakness.class != nil))
      assert MapSet.new(invs, & &1.kind) == MapSet.new([:peg, :oracle, :outflow])
    end

    test "typos and bad values are rejected with a reason" do
      assert {:error, msg} =
               Invariant.from_yaml("""
               id: x-peg
               kind: peg
               name: x
               protocol: x
               weakness: { class: depeg }
               feed: { name: X, decimals: 8, aggregators: ["#{@agg}"] }
               peg_usd: 1
               bands: [{ deviation: 2, severity: high }]
               """)

      assert msg =~ "between 0 and 1"

      assert {:error, msg} =
               Invariant.from_yaml("""
               id: x-out
               kind: outflow
               name: x
               protocol: x
               weakness: { class: drawdown }
               within_blocks: 10
               max_net_outflow: 5
               severity: high
               """)

      assert msg =~ "unknown field(s) max_net_outflow"

      assert {:error, msg} =
               Invariant.from_yaml("""
               id: x-oracle
               kind: oracle
               name: x
               protocol: x
               weakness: { class: oracle }
               feed: { name: X, decimals: 8, aggregators: ["not-an-address"] }
               max_jump: 0.1
               max_age_seconds: 60
               """)

      assert msg =~ "aggregators"
    end
  end

  describe "peg" do
    test "fires when the price leaves the band, escalates once, stays quiet inside a band" do
      [b1, b2, b3, b4, b5] = Enum.map(1..5, &block/1)

      {cs, st} =
        run(peg(), [
          {b1, [answer(b1, 0, 0.995)]},
          {b2, [answer(b2, 0, 0.975)]},
          {b3, [answer(b3, 0, 0.972)]},
          {b4, [answer(b4, 0, 0.94)]},
          {b5, [answer(b5, 0, 0.93)]}
        ])

      assert [%{rule: %{severity: :high}} = high, %{rule: %{severity: :critical}} = crit] = cs
      assert high.title == "TEST/USD at $0.9750: 2.50% off its $1.0000 peg (band 2.00%)"
      assert high.lane == "invariant"
      assert crit.block["number"] == 4
      assert %{state: :breached, value: 0.93} = Check.status(peg(), st)
    end

    test "re-arms after recovering into the band" do
      [b1, b2, b3] = Enum.map(1..3, &block/1)

      {cs, _} =
        run(peg(), [
          {b1, [answer(b1, 0, 0.97)]},
          {b2, [answer(b2, 0, 0.999)]},
          {b3, [answer(b3, 0, 0.97)]}
        ])

      assert [%{dedup_key: k}, %{dedup_key: k}] = cs,
             "same key: the manager merges, never re-pages"
    end

    test "ignores updates from other aggregators" do
      b = block(1)
      {cs, st} = run(peg(), [{b, [answer(b, 0, 0.5, contract: addr("other"))]}])
      assert cs == []
      assert %{state: :warming_up} = Check.status(peg(), st)
    end
  end

  describe "oracle" do
    test "flags a jump larger than max_jump in one update" do
      [b1, b2, b3] = Enum.map(1..3, &block/1)

      {cs, _} =
        run(oracle(), [
          {b1, [answer(b1, 0, 2000.0)]},
          {b2, [answer(b2, 0, 2100.0)]},
          {b3, [answer(b3, 0, 2600.0)]}
        ])

      assert [%{rule: %{severity: :high}, title: title}] = cs
      assert title =~ "moved +23.81% in one update ($2100.0000 → $2600.0000; limit 10.00%)"
    end

    test "flags staleness once, judged at block time, and clears on the next update" do
      b1 = block(1)
      late = %{block(2) | "timestamp" => b1["timestamp"] + 3_601}
      later = %{block(3) | "timestamp" => b1["timestamp"] + 7_200}
      fresh = %{block(4) | "timestamp" => b1["timestamp"] + 7_212}

      {cs, st} =
        run(oracle(), [
          {b1, [answer(b1, 0, 2000.0)]},
          {late, []},
          {later, []},
          {fresh, [answer(fresh, 0, 2001.0)]}
        ])

      assert [%{rule: %{severity: :medium}, title: title, evidence: [ev]}] = cs
      assert title =~ "is stale: no update for 1.0 h at block #2"
      assert ev["block"]["number"] == 1, "evidence is the last update actually seen"
      assert %{state: :ok, age_s: 0} = Check.status(oracle(), st)
    end
  end

  describe "outflow" do
    test "sums net outflow over the window, then re-arms only after recovering" do
      [b1, b2, b3, b4, b5, b6] = Enum.map(1..6, &block/1)

      out = fn b, i, usd ->
        transfer(b, i, addr("vault"), addr("x"), usd, labels: [vault("from")])
      end

      inn = fn b, i, usd ->
        transfer(b, i, addr("x"), addr("vault"), usd, labels: [vault("to")])
      end

      {cs, st} =
        run(outflow(), [
          {b1, [out.(b1, 0, 2_000_000.0)]},
          {b2, [out.(b2, 0, 2_000_000.0), inn.(b2, 1, 500_000.0)]},
          {b3, [out.(b3, 0, 2_000_000.0)]},
          {b4, [out.(b4, 0, 2_000_000.0)]},
          {b5, []},
          {b6, []}
        ])

      # 2.0 + 1.5 + 2.0 = 5.5M within 3 blocks at block 3: fires once.
      assert [%{title: title, evidence: ev, block: %{"number" => 3}}] = cs
      assert title == "Vault net outflow $5,500,000 within 3 blocks; limit $5,000,000"
      assert length(ev) == 3
      # Block 4's $2M is still in the window, below half the limit: re-armed.
      assert %{state: :ok, value: 2_000_000.0} = Check.status(outflow(), st)
    end

    test "transfers between the protocol's own contracts cancel out" do
      b = block(1)

      internal =
        transfer(b, 0, addr("vault"), addr("vault2"), 9_000_000.0,
          labels: [vault("from"), label("to", addr("vault2"), "Vault 2", "lending", "vault")]
        )

      assert {+0.0, []} = Check.net_flow("vault", [internal])
      {cs, _} = run(outflow(), [{b, [internal]}])
      assert cs == []
    end
  end

  describe "monitor processes" do
    test "a reorg rolls the monitor back to before the orphaned block" do
      inv = outflow(5_000_000, 50)
      {:ok, pid} = start_supervised({Monitor, inv}, id: :outflow_monitor)
      b1 = block(1)
      b2 = block(2)
      b2c = block(2, "canonical")

      drain = fn b ->
        [transfer(b, 0, addr("vault"), addr("x"), 6_000_000.0, labels: [vault("from")])]
      end

      assert [] = Monitor.evaluate(pid, ctx(b1, []))
      assert [_] = Monitor.evaluate(pid, ctx(b2, drain.(b2)))
      assert %{state: :breached} = Monitor.status(pid)

      assert :rolled_back = Monitor.orphan(pid, 1, b2["hash"])
      assert %{state: :ok, value: +0.0} = Monitor.status(pid)

      assert [_] = Monitor.evaluate(pid, ctx(b2c, drain.(b2c))),
             "fires again on the canonical block"

      assert :unknown_block = Monitor.orphan(pid, 1, block(99)["hash"])
    end

    test "a crashing monitor restarts alone; the others keep running" do
      [{pid, _}] = Registry.lookup(ChainGuard.Invariants.Registry, "usdc-peg")
      others = Registry.lookup(ChainGuard.Invariants.Registry, "eth-usd-oracle")
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}

      Stream.repeatedly(fn -> Registry.lookup(ChainGuard.Invariants.Registry, "usdc-peg") end)
      |> Enum.find(&match?([{p, _}] when p != pid, &1))

      assert Registry.lookup(ChainGuard.Invariants.Registry, "eth-usd-oracle") == others
      assert length(Invariants.list()) == 9
    end
  end

  describe "historical incident replay through the Broadway pipeline" do
    setup do
      Chain.reset()
      Manager.reset()
      Stats.reset()
      Invariants.reset()
      :ok
    end

    test "USDC depeg, 2023-03-11: quiet at $0.9821 (block 16,802,107), high at $0.9765 (16,802,135)" do
      path = Path.join(@fixtures, "incidents/usdc-depeg-2023-03-11.jsonl")

      start_supervised!(
        {ChainGuard.Ingest.Pipeline,
         name: :replay_usdc, source: {:jsonl, path: path, mode: :replay}}
      )

      Stream.repeatedly(fn -> Process.sleep(20) && Stats.snapshot().counters.blocks end)
      |> Enum.find(&(&1 >= 2))

      assert [a] = Enum.filter(Manager.recent(), &(&1.rule_id == "usdc-peg"))
      assert a.lane == "invariant"
      assert a.severity == :high
      assert a.block_number == 16_802_135
      assert a.title == "USDC/USD at $0.9765: 2.35% off its $1.0000 peg (band 2.00%)"
      assert a.min_attestations >= 2, "the oracle answer was attested by two providers"
      assert [%{kind: "oracle_answer_updated", event: %{"round_id" => "871"}}] = a.evidence
      assert a.weakness.class == "stablecoin-depeg"

      # Nothing else in either block is high or critical.
      assert Enum.filter(Manager.recent(), &(&1.severity in [:high, :critical])) == [a]
      assert %{state: :breached} = Enum.find(Invariants.statuses(), &(&1.id == "usdc-peg"))
    end
  end
end
