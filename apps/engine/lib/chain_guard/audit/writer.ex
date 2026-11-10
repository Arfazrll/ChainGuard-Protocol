defmodule ChainGuard.Audit.Writer do
  @moduledoc """
  Writes every alert lifecycle event and every risk-score change to the
  audit chain, in the order they happened.

  It listens on PubSub, so detection never waits for the database. If
  PostgreSQL is unavailable, entries stay queued in order and are retried
  with backoff; the queue is bounded and overflow is counted, never silently
  dropped. `status/0` reports `ok`, `degraded` (retrying) or `disabled`.
  """

  use GenServer
  require Logger

  alias ChainGuard.Alerts.Alert
  alias ChainGuard.Audit

  @max_queue 10_000
  @max_backoff_ms 30_000
  @topics ["alerts:global", "risk:scores", "audit:events"]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Wait until everything queued so far is written (tests, shutdown)."
  def flush(timeout \\ 10_000), do: GenServer.call(__MODULE__, :flush, timeout)

  @doc false
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Record an arbitrary event (e.g. an org watchlist match)."
  def record(kind, subject, payload, opts \\ []),
    do:
      Phoenix.PubSub.broadcast(
        ChainGuard.PubSub,
        "audit:events",
        {:audit, kind, subject, payload, opts}
      )

  def enabled?, do: Application.get_env(:chain_guard, :audit, true)

  @impl true
  def init(_opts) do
    Enum.each(@topics, &Phoenix.PubSub.subscribe(ChainGuard.PubSub, &1))

    {:ok,
     %{
       queue: :queue.new(),
       size: 0,
       written: 0,
       overflow: 0,
       failures: 0,
       last_error: nil,
       timer: nil
     }}
  end

  @impl true
  def handle_info({:alert, event, %Alert{} = a}, s),
    do: {:noreply, enqueue(s, {"alert.#{event}", "alert:" <> a.id, alert_payload(event, a), []})}

  def handle_info({:score, protocol, score}, s),
    do: {:noreply, enqueue(s, {"score", "protocol:" <> protocol, score, []})}

  def handle_info({:audit, kind, subject, payload, opts}, s),
    do: {:noreply, enqueue(s, {kind, subject, payload, opts})}

  def handle_info(:drain, s), do: {:noreply, drain(%{s | timer: nil})}

  @impl true
  def handle_call(:flush, _from, s), do: {:reply, :ok, drain(s)}

  # Test isolation only: drop entries queued for a database that is gone.
  def handle_call(:reset, _from, s) do
    if s.timer, do: Process.cancel_timer(s.timer)
    {:reply, :ok, %{s | queue: :queue.new(), size: 0, failures: 0, last_error: nil, timer: nil}}
  end

  def handle_call(:status, _from, s) do
    state =
      cond do
        not enabled?() -> :disabled
        s.failures > 0 -> :degraded
        true -> :ok
      end

    {:reply,
     %{
       state: state,
       written: s.written,
       queued: s.size,
       overflow: s.overflow,
       last_error: s.last_error
     }, s}
  end

  # Checked per event, so tests (and operators) can switch auditing at runtime.
  defp enqueue(s, entry), do: if(enabled?(), do: push(s, entry), else: s)

  defp push(%{size: n} = s, _entry) when n >= @max_queue do
    Logger.error("audit queue full: entry not recorded (overflow counted)")
    %{s | overflow: s.overflow + 1}
  end

  defp push(s, entry) do
    s = %{s | queue: :queue.in(entry, s.queue), size: s.size + 1}
    if s.timer, do: s, else: drain(s)
  end

  defp drain(s) do
    case :queue.peek(s.queue) do
      :empty ->
        # Fully caught up: a retry timer left from an earlier outage must not
        # hold back the next entries.
        if s.timer, do: Process.cancel_timer(s.timer)
        %{s | timer: nil}

      {:value, {kind, subject, payload, opts}} ->
        case safe_append(kind, subject, payload, opts) do
          :ok ->
            {_, q} = :queue.out(s.queue)

            drain(%{
              s
              | queue: q,
                size: s.size - 1,
                written: s.written + 1,
                failures: 0,
                last_error: nil
            })

          {:error, reason} ->
            failures = s.failures + 1
            if failures == 1, do: Logger.error("audit writer degraded: #{reason}")
            delay = min(@max_backoff_ms, 200 * Integer.pow(2, min(failures, 8)))

            %{
              s
              | failures: failures,
                last_error: reason,
                timer: Process.send_after(self(), :drain, delay)
            }
        end
    end
  end

  defp safe_append(kind, subject, payload, opts) do
    case Audit.append(kind, subject, payload, opts) do
      {:ok, _} -> :ok
      {:error, e} -> {:error, inspect(e)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  @doc """
  What the audit chain records for an alert event: the decision, its rule,
  its inputs (exact on-chain evidence references) and the sources consulted.
  """
  def alert_payload(event, %Alert{} = a) do
    %{
      event: event,
      alert_id: a.id,
      rule: %{id: a.rule_id, version: a.rule_version, lane: a.lane},
      title: a.title,
      severity: a.severity,
      requested_severity: a.requested_severity,
      status: a.status,
      weakness: a.weakness,
      chain_id: a.chain_id,
      block: %{number: a.block_number, hash: a.block_hash},
      tx_hashes: a.tx_hashes,
      inputs:
        Enum.map(a.evidence, fn e ->
          %{
            record_id: e.record_id,
            block_number: e.block_number,
            block_hash: e.block_hash,
            tx_hash: e.tx_hash,
            log_index: e.log_index,
            contract: e.contract,
            kind: e.kind,
            value_usd: e.value_usd
          }
        end),
      sources: a.sources,
      min_attestations: a.min_attestations,
      occurrences: a.occurrences,
      notes: a.notes,
      first_seen_ms: a.first_seen_ms,
      updated_ms: a.updated_ms
    }
  end
end
