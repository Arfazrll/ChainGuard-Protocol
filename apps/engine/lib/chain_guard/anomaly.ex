defmodule ChainGuard.Anomaly do
  @moduledoc """
  The ML lane: a client for the Python anomaly service (`services/anomaly`).

  Off the hot path by construction. Rules and invariants run inline on every
  block; this process receives each completed block *asynchronously*, sends
  a compact copy to the service and turns what comes back into alerts. If
  the service is slow or down, blocks are skipped (and counted) instead of
  queuing, and the lane reports itself `degraded`: detection by the other
  two lanes is never delayed by ML.

  Severity policy: an anomaly is a statistical signal, not proof. The ML lane
  can raise at most `medium` (novel patterns: `low`), whatever the service
  returns. It never pages on its own; it adds context and asks for a human.

  Reorgs: orphaned blocks are forwarded so the service unlearns them, and
  alerts built on them are retracted by the alert manager like any other.
  """

  use GenServer
  require Logger

  alias ChainGuard.Alerts.Manager
  alias ChainGuard.{Record, Stats}
  alias ChainGuard.Rules.Rule

  @max_backlog 20
  @max_backoff_ms 60_000
  @skip_kinds ~w(unknown undecodable)

  # The ceiling is the point: ML alone never raises high or critical.
  @ceiling :medium

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Hand a completed block to the ML lane. Never blocks the caller."
  def observe(ctx) do
    case enabled?() && Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, n} when n >= @max_backlog -> Stats.incr(:ml_skipped)
          _ -> GenServer.cast(pid, {:observe, ctx})
        end

      _ ->
        :ok
    end
  end

  def orphan(chain_id, block_hash) do
    if enabled?(), do: GenServer.cast(__MODULE__, {:orphan, chain_id, block_hash})
    :ok
  end

  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Wait until every queued block has been processed (tests)."
  def sync, do: GenServer.call(__MODULE__, :sync, 30_000)

  def ceiling, do: @ceiling

  defp config, do: Application.get_env(:chain_guard, :anomaly)
  defp enabled?, do: match?([_ | _], config())

  @doc false
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_), do: {:ok, initial()}

  defp initial,
    do: %{
      failures: 0,
      # nil = not backing off (monotonic time can be negative: no 0 sentinel)
      down_until: nil,
      last_error: nil,
      scored: 0,
      raised: 0,
      model: nil,
      last_block: nil
    }

  @impl true
  def handle_cast({:observe, ctx}, s) do
    now = System.monotonic_time(:millisecond)

    if s.down_until && now < s.down_until do
      Stats.incr(:ml_skipped)
      {:noreply, s}
    else
      {:noreply, score(ctx, s, now)}
    end
  end

  def handle_cast({:orphan, chain_id, hash}, s) do
    _ = post("/v1/orphan", %{chain_id: chain_id, block_hash: hash})
    {:noreply, s}
  end

  @impl true
  def handle_call(:sync, _from, s), do: {:reply, :ok, s}
  def handle_call(:reset, _from, _s), do: {:reply, :ok, initial()}

  def handle_call(:status, _from, s) do
    cfg = config()

    state =
      cond do
        not enabled?() -> :disabled
        s.failures > 0 -> :degraded
        s.scored == 0 -> :starting
        true -> :ok
      end

    {:reply,
     %{
       state: state,
       url: cfg && cfg[:url],
       severity_ceiling: @ceiling,
       blocks_scored: s.scored,
       alerts_raised: s.raised,
       consecutive_failures: s.failures,
       last_error: s.last_error,
       last_block: s.last_block,
       model: s.model
     }, s}
  end

  defp score(ctx, s, now) do
    payload = %{
      chain_id: ctx.chain_id,
      block: Map.take(ctx.block, ["number", "hash", "timestamp"]),
      records: for(r <- ctx.records, Record.get(r, "kind") not in @skip_kinds, do: compact(r))
    }

    case post("/v1/blocks", payload) do
      {:ok, %{"anomalies" => anomalies} = body} ->
        by_id = Map.new(ctx.records, &{&1["id"], &1})
        candidates = Enum.flat_map(anomalies, &candidate(&1, by_id, ctx))
        raised = candidates |> Manager.submit() |> length()
        Stats.incr(:ml_blocks)

        %{
          s
          | failures: 0,
            down_until: nil,
            last_error: nil,
            scored: s.scored + 1,
            raised: s.raised + raised,
            model: body["model"],
            last_block: ctx.block["number"]
        }

      {:error, reason} ->
        failures = s.failures + 1
        backoff = min(@max_backoff_ms, 1_000 * Integer.pow(2, min(failures, 6)))
        if failures == 1, do: Logger.warning("ML lane degraded: #{reason}")
        Stats.incr(:ml_errors)
        %{s | failures: failures, down_until: now + backoff, last_error: reason}
    end
  end

  defp post(path, body) do
    cfg = config() || []

    opts =
      [
        url: cfg[:url] <> path,
        json: body,
        receive_timeout: cfg[:timeout_ms] || 3_000,
        connect_options: [timeout: 1_000],
        retry: false
      ] ++ Keyword.take(cfg, [:plug])

    case Req.post(opts) do
      {:ok, %Req.Response{status: 200, body: %{} = b}} -> {:ok, b}
      {:ok, %Req.Response{status: st}} -> {:error, "HTTP #{st}"}
      {:error, e} -> {:error, Exception.message(e)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc false
  def compact(r) do
    %{
      id: r["id"],
      tx: r["tx_hash"],
      log: r["log_index"],
      contract: r["contract"],
      kind: Record.get(r, "kind"),
      event: Map.delete(r["event"] || %{}, "kind"),
      value_usd: Record.get(r, "value_usd"),
      token: Record.get(r, "token.symbol"),
      labels:
        Enum.map(
          Record.labels(r),
          &Map.take(&1, ["role", "address", "name", "category", "protocol"])
        )
    }
  end

  @doc false
  def candidate(%{"kind" => kind, "key" => key, "title" => title} = a, by_id, ctx) do
    evidence = a |> Map.get("record_ids", []) |> Enum.map(&by_id[&1]) |> Enum.reject(&is_nil/1)

    # Every alert carries on-chain evidence (invariant 5); an anomaly the
    # service cannot tie to records of this block is dropped.
    if evidence == [] do
      []
    else
      severity = if kind == "novel_pattern", do: :low, else: @ceiling

      [
        %{
          rule: rule(kind, severity),
          lane: "ml",
          dedup_key: key,
          title: title,
          evidence: evidence,
          block: ctx.block,
          chain_id: ctx.chain_id,
          notes:
            List.wrap(a["reasons"]) ++
              [
                "ML lane (score #{fmt(a["score"])}, threshold #{fmt(a["threshold"])}): a statistical signal, capped at #{@ceiling}; corroborate before acting"
              ]
        }
      ]
    end
  end

  def candidate(_, _, _), do: []

  defp rule(kind, severity) do
    id = "ml-" <> String.replace(kind, "_", "-")

    %Rule{
      id: id,
      version: 1,
      name: "ML anomaly: #{String.replace(kind, "_", " ")}",
      description: "Raised by the anomaly service (services/anomaly).",
      severity: severity,
      weakness: %{class: "anomalous-behavior", refs: []},
      scope: :ml,
      dedup_window_s: 3_600,
      rate_per_minute: 5,
      source: "services/anomaly"
    }
  end

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt(n), do: to_string(n)
end
