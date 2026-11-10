defmodule ChainGuard.Alerts.Manager do
  @moduledoc """
  Turns rule candidates into alerts and owns their lifecycle.

  For every candidate, in order:

    1. **Severity gate (invariant 2).** `high` and `critical` need evidence
       attested by at least two independent nodes; otherwise severity is
       capped at `medium` and a note says why.
    2. **Dedup (invariant 5).** A candidate with the same rule and dedup key
       as a live alert inside the rule's window merges into it: the
       occurrence count goes up and evidence is appended, but connectors are
       not paged again.
    3. **Rate limit (invariant 5).** At most `rate_per_minute` new alerts per
       rule; the excess is counted and suppressed.
    4. **Fan-out.** Broadcast on `alerts:global` and deliver to connectors.

  Reorgs: when an evidence block is orphaned the alert is retracted and the
  retraction fans out too. When all evidence blocks are finalized, the alert
  becomes final.
  """

  use GenServer
  require Logger

  alias ChainGuard.Alerts.{Alert, Fanout}
  alias ChainGuard.Record
  alias ChainGuard.Rules.Rule

  @max_alerts 2_000
  @max_evidence 50
  @max_final_blocks 4_096
  @topic "alerts:global"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Submit rule candidates. Returns the alerts that were created or updated."
  def submit(candidates, now_ms \\ now()),
    do: GenServer.call(__MODULE__, {:submit, candidates, now_ms})

  def retract_block(chain_id, block_hash, reason),
    do: GenServer.call(__MODULE__, {:retract_block, chain_id, block_hash, reason})

  def finalize_block(chain_id, block_hash),
    do: GenServer.call(__MODULE__, {:finalize_block, chain_id, block_hash})

  @doc "Alerts about the monitor itself (e.g. an ingestion integrity halt)."
  def system_alert(chain_id, title, severity, details),
    do: GenServer.call(__MODULE__, {:system, chain_id, title, severity, details, now()})

  def recent(limit \\ 50), do: GenServer.call(__MODULE__, {:recent, limit})
  def get(id), do: GenServer.call(__MODULE__, {:get, id})
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc false
  def reset, do: GenServer.call(__MODULE__, :reset)

  def now, do: System.system_time(:millisecond)

  @impl true
  def init(_opts), do: {:ok, empty()}

  defp empty do
    %{
      alerts: %{},
      order: :queue.new(),
      by_dedup: %{},
      by_block: %{},
      final_blocks: MapSet.new(),
      final_order: :queue.new(),
      rate: %{},
      counters: %{raised: 0, merged: 0, suppressed: 0, retracted: 0, finalized: 0, capped: 0}
    }
  end

  @impl true
  def handle_call(:reset, _from, _s), do: {:reply, :ok, empty()}

  def handle_call({:submit, candidates, now_ms}, _from, s) do
    {touched, s} =
      Enum.reduce(candidates, {[], s}, fn c, {acc, s} ->
        case accept(c, now_ms, s) do
          {:ok, alert, s} -> {[alert | acc], s}
          {:skip, s} -> {acc, s}
        end
      end)

    {:reply, Enum.reverse(touched), s}
  end

  def handle_call({:retract_block, chain_id, hash, reason}, _from, s) do
    ids = s.by_block |> Map.get({chain_id, hash}, MapSet.new()) |> MapSet.to_list()

    {retracted, s} =
      Enum.reduce(ids, {[], s}, fn id, {acc, s} ->
        case s.alerts[id] do
          # Final alerts are never retracted; ingestion cannot orphan a
          # finalized block, and this enforces it here too.
          %Alert{status: :provisional} = a ->
            a = %{a | status: :retracted, updated_ms: now(), notes: a.notes ++ [reason]}
            emit(:retracted, a)
            {[a | acc], put_in(s.alerts[id], a) |> bump(:retracted)}

          _ ->
            {acc, s}
        end
      end)

    {:reply, retracted, %{s | by_block: Map.delete(s.by_block, {chain_id, hash})}}
  end

  def handle_call({:finalize_block, chain_id, hash}, _from, s) do
    key = {chain_id, hash}
    s = remember_final(s, key)

    {finalized, s} =
      s.by_block
      |> Map.get(key, MapSet.new())
      |> Enum.reduce({[], s}, fn id, {acc, s} ->
        a = s.alerts[id]

        if a && a.status == :provisional && all_final?(a, s) do
          a = %{a | status: :final, updated_ms: now()}
          emit(:finalized, a)
          {[a | acc], put_in(s.alerts[id], a) |> bump(:finalized)}
        else
          {acc, s}
        end
      end)

    {:reply, finalized, s}
  end

  def handle_call({:system, chain_id, title, severity, details, now_ms}, _from, s) do
    a = %Alert{
      id: id_for(["system", to_string(chain_id), title, to_string(now_ms)]),
      rule_id: "system",
      rule_version: 1,
      title: title,
      severity: severity,
      requested_severity: severity,
      weakness: %{class: "monitor-integrity", refs: []},
      chain_id: chain_id,
      first_seen_ms: now_ms,
      updated_ms: now_ms,
      notes: [details],
      status: :final,
      system: true,
      lane: "system"
    }

    emit(:raised, a)
    {:reply, a, store(s, a) |> bump(:raised)}
  end

  def handle_call({:recent, limit}, _from, s) do
    alerts =
      s.order |> :queue.to_list() |> Enum.reverse() |> Enum.take(limit) |> Enum.map(&s.alerts[&1])

    {:reply, alerts, s}
  end

  def handle_call({:get, id}, _from, s), do: {:reply, Map.get(s.alerts, id), s}

  def handle_call(:stats, _from, s),
    do: {:reply, Map.put(s.counters, :active, map_size(s.alerts)), s}

  # --- pipeline ----------------------------------------------------------------

  defp accept(%{rule: %Rule{} = rule} = c, now_ms, s) do
    dedup = {rule.id, c.dedup_key}

    case live_duplicate(s, dedup, rule, now_ms) do
      %Alert{} = existing ->
        merged = merge(existing, c, now_ms)
        emit(:updated, merged)
        {:ok, merged, index_blocks(put_in(s.alerts[merged.id], merged), merged) |> bump(:merged)}

      nil ->
        case take_rate(s, rule, now_ms) do
          {:ok, s} ->
            alert = build(c, now_ms, s)
            s = if alert.severity != alert.requested_severity, do: bump(s, :capped), else: s
            emit(:raised, alert)

            s =
              s
              |> store(alert)
              |> put_in([:by_dedup, dedup], alert.id)
              |> index_blocks(alert)
              |> bump(:raised)

            {:ok, alert, s}

          :limited ->
            Logger.warning("rate limit: suppressed alert from rule #{rule.id}")
            {:skip, bump(s, :suppressed)}
        end
    end
  end

  defp live_duplicate(s, key, rule, now_ms) do
    with id when is_binary(id) <- Map.get(s.by_dedup, key),
         %Alert{status: status} = a when status != :retracted <- Map.get(s.alerts, id),
         true <- now_ms - a.first_seen_ms <= rule.dedup_window_s * 1000 do
      a
    else
      _ -> nil
    end
  end

  defp take_rate(s, rule, now_ms) do
    {start, n} = Map.get(s.rate, rule.id, {now_ms, 0})
    {start, n} = if now_ms - start >= 60_000, do: {now_ms, 0}, else: {start, n}

    if n < rule.rate_per_minute,
      do: {:ok, put_in(s.rate[rule.id], {start, n + 1})},
      else: :limited
  end

  defp build(c, now_ms, s) do
    rule = c.rule
    evidence = Enum.map(c.evidence, &Record.evidence/1)
    attest_counts = Enum.map(c.evidence, &length(Map.get(&1, "attested_by", [])))
    min_att = Enum.min(attest_counts, fn -> 0 end)
    lane = Map.get(c, :lane, "rule")
    {severity, lane_notes} = lane_gate(lane, rule.severity)
    {severity, notes} = gate(severity, min_att)
    notes = lane_notes ++ notes ++ Map.get(c, :notes, [])
    blocks = MapSet.new(c.evidence, &{c.chain_id, Record.block_hash(&1)})

    alert = %Alert{
      id: id_for([rule.id, c.dedup_key, hd(c.evidence)["id"]]),
      rule_id: rule.id,
      rule_version: rule.version,
      lane: lane,
      title: c.title,
      severity: severity,
      requested_severity: rule.severity,
      weakness: rule.weakness,
      chain_id: c.chain_id,
      block_number: c.block["number"],
      block_hash: c.block["hash"],
      tx_hashes: c.evidence |> Enum.map(& &1["tx_hash"]) |> Enum.uniq(),
      evidence: Enum.take(evidence, @max_evidence),
      evidence_blocks: blocks,
      sources:
        c.evidence |> Enum.flat_map(&Map.get(&1, "attested_by", [])) |> Enum.uniq() |> Enum.sort(),
      min_attestations: min_att,
      dedup_key: c.dedup_key,
      first_seen_ms: now_ms,
      updated_ms: now_ms,
      detect_lag_ms: lag(c.block, now_ms),
      notes: notes
    }

    if all_final?(alert, s), do: %{alert | status: :final}, else: alert
  end

  @doc false
  def gate(severity, min_attestations) do
    if Rule.severity_rank(severity) >= Rule.severity_rank(:high) and min_attestations < 2 do
      {:medium,
       [
         "severity capped at medium: evidence attested by #{min_attestations} node(s); high and critical need at least 2"
       ]}
    else
      {severity, []}
    end
  end

  @doc false
  # The ML lane is a statistical signal: it never raises above medium, even
  # if a candidate asks for more (defence in depth behind ChainGuard.Anomaly).
  def lane_gate("ml", severity) do
    if Rule.severity_rank(severity) > Rule.severity_rank(:medium),
      do: {:medium, ["severity capped at medium: the ML lane never raises high or critical"]},
      else: {severity, []}
  end

  def lane_gate(_lane, severity), do: {severity, []}

  defp merge(a, c, now_ms) do
    evidence =
      (a.evidence ++ Enum.map(c.evidence, &Record.evidence/1)) |> Enum.uniq_by(& &1.record_id)

    blocks =
      MapSet.union(
        a.evidence_blocks,
        MapSet.new(c.evidence, &{c.chain_id, Record.block_hash(&1)})
      )

    %{
      a
      | occurrences: a.occurrences + 1,
        evidence: Enum.take(evidence, @max_evidence),
        evidence_blocks: blocks,
        tx_hashes: Enum.uniq(a.tx_hashes ++ Enum.map(c.evidence, & &1["tx_hash"])),
        updated_ms: now_ms,
        status: :provisional
    }
  end

  defp lag(%{"timestamp" => ts}, now_ms) when is_integer(ts) do
    lag = now_ms - ts * 1000
    if ChainGuard.Chain.Server.replayed?(lag), do: nil, else: lag
  end

  defp lag(_, _), do: nil

  defp all_final?(a, s),
    do: MapSet.size(a.evidence_blocks) > 0 and MapSet.subset?(a.evidence_blocks, s.final_blocks)

  defp remember_final(s, key) do
    if MapSet.member?(s.final_blocks, key) do
      s
    else
      order = :queue.in(key, s.final_order)

      {order, final} =
        if :queue.len(order) > @max_final_blocks do
          {{:value, old}, order} = :queue.out(order)
          {order, MapSet.delete(s.final_blocks, old)}
        else
          {order, s.final_blocks}
        end

      %{s | final_order: order, final_blocks: MapSet.put(final, key)}
    end
  end

  defp index_blocks(s, alert) do
    by_block =
      Enum.reduce(alert.evidence_blocks, s.by_block, fn key, acc ->
        Map.update(acc, key, MapSet.new([alert.id]), &MapSet.put(&1, alert.id))
      end)

    %{s | by_block: by_block}
  end

  defp store(s, alert) do
    s = %{s | alerts: Map.put(s.alerts, alert.id, alert), order: :queue.in(alert.id, s.order)}

    if :queue.len(s.order) > @max_alerts do
      {{:value, old}, order} = :queue.out(s.order)
      %{s | order: order, alerts: Map.delete(s.alerts, old)}
    else
      s
    end
  end

  defp bump(s, k), do: update_in(s.counters[k], &(&1 + 1))

  defp id_for(parts),
    do:
      :crypto.hash(:sha256, Enum.join(parts, "|"))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

  defp emit(event, alert) do
    Phoenix.PubSub.broadcast(ChainGuard.PubSub, @topic, {:alert, event, alert})
    Fanout.dispatch(event, alert)

    :telemetry.execute([:chain_guard, :alert, event], %{count: 1}, %{
      rule: alert.rule_id,
      severity: alert.severity
    })
  end
end
