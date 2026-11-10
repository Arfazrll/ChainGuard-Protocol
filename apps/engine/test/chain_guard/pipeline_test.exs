defmodule ChainGuard.PipelineTest do
  use ExUnit.Case, async: false

  alias ChainGuard.{Chain, Stats}
  alias ChainGuard.Alerts.Manager
  import ChainGuard.Fixtures

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    Chain.reset()
    Manager.reset()
    Stats.reset()
    ChainGuard.Invariants.reset()
    :ok
  end

  defp feed(msgs), do: Enum.each(msgs, &(:ok = Chain.handle(&1)))
  defp by_rule(id), do: Enum.filter(Manager.recent(), &(&1.rule_id == id))

  defp wait_until(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      case fun.() do
        falsy when falsy in [nil, false, []] ->
          if System.monotonic_time(:millisecond) > deadline, do: flunk("timed out waiting")
          Process.sleep(20)
          nil

        v ->
          v
      end
    end)
    |> Enum.find(& &1)
  end

  describe "chain flow (invariant 3 end to end)" do
    test "reorg retracts the alert; the canonical re-inclusion raises a new one; finality settles it" do
      Phoenix.PubSub.subscribe(ChainGuard.PubSub, "alerts:global")
      b10 = block(10)
      feed(adopt(1, b10, euler_like_drain(b10)))
      # Two lanes agree: the rule (flash-loan drain) and the invariant
      # (Euler's net outflow over 50 blocks).
      assert [%{status: :provisional} = first] = by_rule("flash-loan-drain")
      assert [%{status: :provisional, lane: "invariant"} = inv] = by_rule("euler-outflow")

      # Reorg: block 10 is replaced by 10' which carries the same attack tx.
      b10c = block(10, "canonical")
      feed([orphan(7, b10, b10c)])
      assert_receive {:alert, :retracted, %{id: id}}
      assert id in [first.id, inv.id]
      assert Enum.all?(Manager.recent(), &(&1.status == :retracted))

      # The invariant monitor rolled back too, so the canonical block raises
      # it again instead of being treated as already fired.
      feed(adopt(8, b10c, euler_like_drain(b10c)))

      for rule <- ["flash-loan-drain", "euler-outflow"] do
        assert [%{status: :provisional} = second, %{status: :retracted}] = by_rule(rule)
        assert second.id not in [first.id, inv.id]
      end

      feed([finalize(14, b10c)])

      for rule <- ["flash-loan-drain", "euler-outflow"],
          do: assert([%{status: :final}, %{status: :retracted}] = by_rule(rule))
    end

    test "redelivered messages are ignored (idempotent consumer)" do
      b = block(10)
      msgs = adopt(1, b, euler_like_drain(b))
      feed(msgs)
      Enum.each(msgs, &assert(Chain.handle(&1) == :duplicate))
      assert [_, _] = alerts = Manager.recent()
      assert Enum.all?(alerts, &(&1.occurrences == 1))
      assert Stats.snapshot().counters.duplicates == length(msgs)
    end

    test "an integrity halt becomes a critical system alert" do
      feed([
        %{
          "type" => "integrity_halt",
          "seq" => 1,
          "chain_id" => 1,
          "reason" => "reorg below finality",
          "last_good" => nil
        }
      ])

      assert [%{system: true, severity: :critical, notes: ["reorg below finality"]}] =
               Manager.recent()
    end
  end

  describe "historical incident replay through the Broadway pipeline" do
    test "Euler Finance, 2023-03-13 (block 16,817,996): flash-loan drain detected" do
      path = Path.join(@fixtures, "incidents/euler-finance-2023-03-13.jsonl")

      start_supervised!(
        {ChainGuard.Ingest.Pipeline,
         name: :replay_euler, source: {:jsonl, path: path, mode: :replay}}
      )

      wait_until(fn -> Stats.snapshot().counters.blocks >= 1 end)
      alerts = Manager.recent()
      assert [a] = Enum.filter(alerts, &(&1.rule_id == "flash-loan-drain"))

      assert a.severity == :critical
      assert a.block_number == 16_817_996
      assert a.tx_hashes == ["0xc310a0affe2169d1f6feec1c63dbc7f7c62a887fa48795d327d4d2da2d6b111d"]
      assert a.title =~ "Euler Finance (main proxy) net outflow $8,904,5"
      assert a.min_attestations >= 2, "evidence was verified by two independent RPC providers"

      assert Enum.any?(
               a.evidence,
               &(&1.kind == "flash_loan" and &1.event["provider"] == "aave_v2")
             )

      # Replayed history never feeds latency figures (its "lag" is its age).
      stats = Stats.snapshot()
      assert stats.counters.replayed_blocks == 1
      assert stats.latency_ms.detect.samples == 0
      assert stats.latency_ms.pipeline.samples == 0
      assert a.detect_lag_ms == nil

      # The invariant lane agrees independently: Euler's net outflow over 50
      # blocks breaks its $5M limit, on the same transaction.
      assert [inv] = Enum.filter(alerts, &(&1.rule_id == "euler-outflow"))
      assert inv.lane == "invariant" and inv.severity == :critical
      assert inv.tx_hashes == a.tx_hashes
      assert inv.title =~ "net outflow $8,904,5"

      # The other 354 records in the block raise nothing else high or critical.
      assert alerts
             |> Enum.filter(&(&1.severity in [:high, :critical]))
             |> Enum.map(& &1.id)
             |> Enum.sort() ==
               Enum.sort([a.id, inv.id])
    end

    test "baseline: a block of ordinary mainnet traffic raises nothing high or critical" do
      path = Path.join(@fixtures, "baseline-mainnet-26381781.jsonl")

      start_supervised!(
        {ChainGuard.Ingest.Pipeline,
         name: :replay_baseline, source: {:jsonl, path: path, mode: :replay}}
      )

      wait_until(fn -> Stats.snapshot().counters.blocks >= 1 end)
      assert Stats.snapshot().counters.records == 827
      assert Enum.filter(Manager.recent(), &(&1.severity in [:high, :critical])) == []
    end
  end

  describe "jsonl tail mode" do
    test "follows a growing file and waits for complete lines" do
      dir = Path.join(System.tmp_dir!(), "cg-tail-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "stream.jsonl")
      File.write!(path, "")

      start_supervised!(
        {ChainGuard.Ingest.Pipeline, name: :tail, source: {:jsonl, path: path, mode: :tail}}
      )

      b = block(10)
      [first | rest] = Enum.map(adopt(1, b, euler_like_drain(b)), &Jason.encode!/1)
      # Write half a line first: it must not be consumed until completed.
      {head, tail} = String.split_at(first, 20)
      File.write!(path, head, [:append])
      Process.sleep(400)
      assert Stats.snapshot().counters.blocks == 0
      File.write!(path, tail <> "\n" <> Enum.join(rest, "\n") <> "\n", [:append])

      wait_until(fn -> Stats.snapshot().counters.blocks >= 1 end)
      assert [%{rule_id: "flash-loan-drain"}] = by_rule("flash-loan-drain")
      File.rm_rf!(dir)
    end
  end
end
