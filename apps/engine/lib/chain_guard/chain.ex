defmodule ChainGuard.Chain do
  @moduledoc """
  Entry point for bus messages. One `ChainGuard.Chain.Server` per chain,
  started on demand under a DynamicSupervisor and found through a Registry.
  """

  alias ChainGuard.Chain.Server

  @doc "Process one decoded stream message, synchronously and in order."
  def handle(%{"chain_id" => chain_id} = msg) when is_integer(chain_id) do
    GenServer.call(server(chain_id), {:message, msg}, 30_000)
  end

  def recent_blocks(chain_id) do
    case Registry.lookup(ChainGuard.Chain.Registry, chain_id) do
      [{pid, _}] -> GenServer.call(pid, :recent_blocks)
      [] -> []
    end
  end

  def chains,
    do:
      Registry.select(ChainGuard.Chain.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]) |> Enum.sort()

  @doc false
  def reset do
    for pid <- Registry.select(ChainGuard.Chain.Registry, [{{:_, :"$1", :_}, [], [:"$1"]}]) do
      DynamicSupervisor.terminate_child(ChainGuard.Chain.Supervisor, pid)
    end

    :ok
  end

  defp server(chain_id) do
    case Registry.lookup(ChainGuard.Chain.Registry, chain_id) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(ChainGuard.Chain.Supervisor, {Server, chain_id}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end
end

defmodule ChainGuard.Chain.Server do
  @moduledoc """
  Per-chain consumer state.

  Assembles blocks from the ordered message stream (a block is complete
  once `record_count` upserts have arrived), evaluates every rule on it, and
  routes lifecycle messages:

    * `block_orphaned` → retract alerts built on that block and drop it from
      rule windows
    * `block_finalized` → alerts whose evidence is all final become final
    * `integrity_halt` → a critical system alert: the monitor itself is
      degraded and someone must look

  Messages with a `seq` at or below the last processed one are redeliveries
  and are ignored, so consumption is idempotent under at-least-once delivery.
  """

  use GenServer, restart: :transient
  require Logger

  alias ChainGuard.{Record, Rules, Stats}
  alias ChainGuard.Alerts.Manager
  alias ChainGuard.Rules.Evaluator

  @recent 30
  @notable_usd 100_000

  def start_link(chain_id),
    do:
      GenServer.start_link(__MODULE__, chain_id,
        name: {:via, Registry, {ChainGuard.Chain.Registry, chain_id}}
      )

  @impl true
  def init(chain_id), do: {:ok, %{chain_id: chain_id, last_seq: 0, pending: nil, recent: []}}

  @impl true
  def handle_call(:recent_blocks, _from, s), do: {:reply, s.recent, s}

  def handle_call({:message, %{"seq" => seq}}, _from, %{last_seq: last} = s) when seq <= last do
    Stats.incr(:duplicates)
    {:reply, :duplicate, s}
  end

  def handle_call({:message, %{"seq" => seq, "type" => type} = msg}, _from, s) do
    s = handle(type, msg, %{s | last_seq: seq})
    {:reply, :ok, s}
  end

  defp handle("block_adopted", %{"block" => block} = m, s) do
    s = flush(s)

    pending = %{
      block: block,
      expected: m["record_count"],
      records: [],
      attested_by: m["attested_by"] || []
    }

    maybe_flush(%{s | pending: pending})
  end

  defp handle("upsert", %{"record" => r}, s) do
    Stats.incr(:records)

    block_hash = get_in(r, ["block", "hash"])

    s =
      case s.pending do
        %{block: %{"hash" => ^block_hash}} ->
          s

        _ ->
          # Joined mid-block (e.g. consumer started late): assemble what we have.
          pending = %{
            block: r["block"],
            expected: nil,
            records: [],
            attested_by: r["attested_by"] || []
          }

          %{flush(s) | pending: pending}
      end

    maybe_flush(update_in(s.pending.records, &[r | &1]))
  end

  defp handle("retract", _m, s), do: s

  defp handle("block_orphaned", %{"block" => b} = m, s) do
    s = flush(s)
    Rules.orphan_block(s.chain_id, b["hash"])

    replaced = m["replaced_by"] && m["replaced_by"]["hash"]

    reason =
      "block ##{b["number"]} #{b["hash"]} orphaned by a reorg" <>
        if(replaced, do: " (replaced by #{replaced})", else: "")

    retracted = Manager.retract_block(s.chain_id, b["hash"], reason)

    broadcast(s.chain_id, "block:orphaned", %{
      block: b,
      replaced_by: m["replaced_by"],
      retracted_alerts: Enum.map(retracted, & &1.id)
    })

    %{
      s
      | recent:
          Enum.map(s.recent, fn x ->
            if x.hash == b["hash"], do: %{x | status: "orphaned"}, else: x
          end)
    }
  end

  defp handle("reorg", m, s) do
    s = flush(s)
    Stats.incr(:reorgs)

    broadcast(
      s.chain_id,
      "reorg",
      Map.take(m, ["depth", "common_ancestor", "old_tip", "new_tip"])
    )

    s
  end

  defp handle("block_finalized", %{"block" => b}, s) do
    s = flush(s)
    Manager.finalize_block(s.chain_id, b["hash"])

    %{
      s
      | recent:
          Enum.map(s.recent, fn x ->
            if x.hash == b["hash"], do: %{x | status: "final"}, else: x
          end)
    }
  end

  defp handle("integrity_halt", m, s) do
    s = flush(s)

    Manager.system_alert(
      s.chain_id,
      "Ingestion halted on chain #{s.chain_id}: integrity check failed",
      :critical,
      m["reason"] || "no reason given"
    )

    broadcast(s.chain_id, "integrity_halt", Map.take(m, ["reason", "last_good"]))
    s
  end

  defp handle(type, _m, s) do
    Logger.warning("ignoring unknown stream message type #{inspect(type)}")
    s
  end

  defp maybe_flush(%{pending: %{expected: n, records: rs}} = s)
       when is_integer(n) and length(rs) >= n, do: flush(s)

  defp maybe_flush(s), do: s

  defp flush(%{pending: nil} = s), do: s

  defp flush(%{pending: p} = s) do
    started = System.monotonic_time(:millisecond)
    ctx = Evaluator.context(s.chain_id, p.block, Enum.reverse(p.records))
    alerts = ctx |> Rules.evaluate_block() |> Manager.submit()
    eval_ms = System.monotonic_time(:millisecond) - started

    now = System.system_time(:millisecond)
    ingest_lag = ingest_lag(ctx.records, p.block)
    detect_lag = if is_integer(p.block["timestamp"]), do: now - p.block["timestamp"] * 1000
    pipeline = pipeline_ms(ctx.records, now)
    replayed = replayed?(detect_lag)

    # Replayed history (incident regression runs, catch-up) would report its
    # age as "latency"; only live blocks feed the latency figures.
    latencies =
      if replayed,
        do: %{rule_eval: eval_ms},
        else: %{ingest: ingest_lag, detect: detect_lag, pipeline: pipeline, rule_eval: eval_ms}

    Stats.block(s.chain_id, p.block, length(ctx.records), length(alerts), latencies)
    if replayed, do: Stats.incr(:replayed_blocks)

    summary = %{
      number: p.block["number"],
      hash: p.block["hash"],
      timestamp: p.block["timestamp"],
      records: length(ctx.records),
      txs: map_size(ctx.txs),
      alerts: Enum.map(alerts, & &1.id),
      attested_by: p.attested_by,
      ingest_lag_ms: ingest_lag,
      detect_lag_ms: detect_lag,
      pipeline_ms: pipeline,
      eval_ms: eval_ms,
      replayed: replayed,
      status: "provisional",
      notable: notable(ctx.records)
    }

    broadcast(s.chain_id, "block", summary)
    %{s | pending: nil, recent: Enum.take([Map.delete(summary, :notable) | s.recent], @recent)}
  end

  # Signed on purpose: a negative lag means a clock is behind block time.
  defp ingest_lag([%{"observed_at_ms" => obs} | _], %{"timestamp" => ts})
       when is_integer(obs) and is_integer(ts),
       do: obs - ts * 1000

  defp ingest_lag(_, _), do: nil

  @live_window_ms 10 * 60 * 1000

  @doc false
  def replayed?(detect_lag) when is_integer(detect_lag), do: detect_lag > @live_window_ms
  def replayed?(_), do: false

  # ingestd derived the record → rules evaluated here. Both timestamps come
  # from hosts' wall clocks but not from the chain, so with ingestd and the
  # engine on one host this is free of chain-vs-local clock skew.
  defp pipeline_ms([%{"observed_at_ms" => obs} | _], now) when is_integer(obs), do: now - obs
  defp pipeline_ms(_, _), do: nil

  # The largest priced movements and every flash loan: the live feed.
  defp notable(records) do
    records
    |> Enum.filter(fn r ->
      Record.get(r, "kind") == "flash_loan" or (Record.get(r, "value_usd") || 0) >= @notable_usd
    end)
    |> Enum.sort_by(&(-(Record.get(&1, "value_usd") || 0)))
    |> Enum.take(8)
    |> Enum.map(&Record.evidence/1)
  end

  defp broadcast(chain_id, event, payload),
    do: ChainGuardWeb.Endpoint.broadcast("live:#{chain_id}", event, payload)
end
