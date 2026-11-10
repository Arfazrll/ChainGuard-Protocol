defmodule ChainGuard.Stats do
  @moduledoc """
  Live counters and latency for the dashboard and `/api/stats`.

  Two latencies are tracked separately:

    * `ingest`: block timestamp → record derived by ingestd
    * `detect`: block timestamp → rules evaluated here
    * `pipeline`: ingestd derived the record → rules evaluated here
    * `rule_eval`: time spent evaluating all rules on one block

  Chain-relative figures (`ingest`, `detect`) have one-second resolution and
  depend on host clocks being in sync; they are signed, and negative values
  raise `clock_skew_suspected` instead of being hidden. `pipeline` and
  `rule_eval` do not depend on chain time.
  """

  use GenServer

  @window 200

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def incr(key, n \\ 1), do: GenServer.cast(__MODULE__, {:incr, key, n})

  def block(chain_id, block, records, alerts, latencies),
    do: GenServer.cast(__MODULE__, {:block, chain_id, block, records, alerts, latencies})

  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc false
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_), do: {:ok, empty()}

  defp empty do
    %{
      started_at_ms: System.system_time(:millisecond),
      counters: %{
        blocks: 0,
        replayed_blocks: 0,
        records: 0,
        reorgs: 0,
        duplicates: 0,
        failed_messages: 0,
        alerts: 0,
        txs: 0,
        usd_observed: 0,
        ml_blocks: 0,
        ml_skipped: 0,
        ml_errors: 0
      },
      chains: %{},
      latency: %{ingest: [], detect: [], pipeline: [], rule_eval: []}
    }
  end

  @impl true
  def handle_cast({:incr, k, n}, s),
    do: {:noreply, update_in(s.counters, &Map.update(&1, k, n, fn v -> v + n end))}

  def handle_cast({:block, chain_id, block, _records, alerts, lat}, s) do
    latency =
      Map.new(s.latency, fn {k, xs} ->
        case Map.get(lat, k) do
          v when is_integer(v) -> {k, Enum.take([v | xs], @window)}
          _ -> {k, xs}
        end
      end)

    s =
      s
      |> update_in([:counters, :blocks], &(&1 + 1))
      |> update_in([:counters, :alerts], &(&1 + alerts))
      |> put_in([:chains, chain_id], %{
        head: block["number"],
        hash: block["hash"],
        timestamp: block["timestamp"]
      })
      |> Map.put(:latency, latency)

    {:noreply, s}
  end

  @impl true
  def handle_call(:reset, _from, _s), do: {:reply, :ok, empty()}

  def handle_call(:snapshot, _from, s) do
    snap = %{
      uptime_s: div(System.system_time(:millisecond) - s.started_at_ms, 1000),
      counters: s.counters,
      chains: s.chains,
      latency_ms: Map.new(s.latency, fn {k, xs} -> {k, percentiles(xs)} end),
      # Chain-relative lags below zero mean a local clock is behind block
      # time (check NTP); those figures are then not meaningful.
      clock_skew_suspected: Enum.any?(s.latency.ingest ++ s.latency.detect, &(&1 < -2_000)),
      alerts: ChainGuard.Alerts.Manager.stats()
    }

    {:reply, snap, s}
  end

  defp percentiles([]), do: %{p50: nil, p95: nil, max: nil, samples: 0}

  defp percentiles(xs) do
    sorted = Enum.sort(xs)
    n = length(sorted)
    at = fn q -> Enum.at(sorted, min(n - 1, floor(q * n))) end
    %{p50: at.(0.5), p95: at.(0.95), max: List.last(sorted), samples: n}
  end
end
