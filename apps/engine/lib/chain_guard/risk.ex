defmodule ChainGuard.Risk do
  @moduledoc """
  Protocol health scores: 0 (critical risk) to 100 (no open risk signals).

  The model is deliberately simple and fully explainable. Every score
  carries its components, the exact alerts and invariant states it used,
  and a model version, and every change is written to the audit chain.

      score = 100 - min(70, alert deductions) - min(60, invariant deductions)

    * **Alerts** attributed to the protocol (not retracted) deduct by
      severity: critical 45, high 25, medium 10, low 3. The deduction halves
      every 6 hours since the alert was last updated. ML-lane alerts count
      half, because they are statistical signals.
    * **Invariants** of the protocol that are currently broken deduct 30
      each.

  Bands: 80+ low, 60–79 elevated, 40–59 high, below 40 critical.
  Confidence says how much ChainGuard can see: `high` when every invariant
  of the protocol is reporting, `medium` when some are still warming up,
  `low` when none are.

  **Attribution.** An alert counts against a protocol only if the protocol
  is where the damage is:
    * an invariant alert counts against its own protocol;
    * for transfer evidence, against protocols with a *net outflow* across
      the evidence (a flash-loan lender that is repaid is not penalized);
    * for privileged changes and pauses, against the protocol whose contract
      emitted the event.
  """

  alias ChainGuard.Alerts.Alert

  @model "risk-v1"
  @weights %{critical: 45, high: 25, medium: 10, low: 3, info: 0}
  @lane_factor %{"ml" => 0.5}
  @half_life_ms 6 * 3_600_000
  @alert_cap 70
  @breach 30
  @breach_cap 60
  @contract_kinds ~w(proxy_upgraded proxy_admin_changed ownership_transferred role_granted paused unpaused)

  def model, do: @model

  @doc """
  Score every protocol that has an invariant or an attributed alert.
  `invariants` is a list of `%{id, protocol}`; `statuses` the monitors'
  current statuses.
  """
  @spec score_all([Alert.t()], [map()], [map()], integer()) :: %{String.t() => map()}
  def score_all(alerts, invariants, statuses, now_ms) do
    inv_protocol = Map.new(invariants, &{&1.id, &1.protocol})
    open = Enum.reject(alerts, &(&1.status == :retracted or &1.system))

    attributed =
      for a <- open, p <- attribute(a, inv_protocol), reduce: %{} do
        acc -> Map.update(acc, p, [a], &[a | &1])
      end

    by_protocol = Enum.group_by(statuses, & &1.protocol)
    protocols = Enum.uniq(Map.keys(by_protocol) ++ Map.keys(attributed))

    Map.new(protocols, fn p ->
      {p, score(p, Map.get(attributed, p, []), Map.get(by_protocol, p, []), now_ms)}
    end)
  end

  @spec score(String.t(), [Alert.t()], [map()], integer()) :: map()
  def score(protocol, alerts, statuses, now_ms) do
    alert_parts =
      alerts
      |> Enum.map(fn a ->
        age = max(0, now_ms - (a.updated_ms || a.first_seen_ms || now_ms))
        decay = :math.pow(0.5, age / @half_life_ms)
        points = Map.get(@weights, a.severity, 0) * Map.get(@lane_factor, a.lane, 1.0) * decay

        %{
          alert_id: a.id,
          rule_id: a.rule_id,
          lane: a.lane,
          severity: a.severity,
          age_s: div(age, 1000),
          points: Float.round(points, 2)
        }
      end)
      |> Enum.sort_by(&(-&1.points))

    alert_ded = min(@alert_cap, alert_parts |> Enum.map(& &1.points) |> Enum.sum())

    breached = Enum.filter(statuses, &(&1.state == :breached))
    inv_ded = min(@breach_cap, length(breached) * @breach)
    score = max(0, round(100 - alert_ded - inv_ded))

    %{
      protocol: protocol,
      score: score,
      band: band(score),
      confidence: confidence(statuses),
      model: @model,
      components: [
        %{
          name: "alerts",
          deduction: Float.round(alert_ded * 1.0, 2),
          cap: @alert_cap,
          items: alert_parts
        },
        %{
          name: "invariants",
          deduction: inv_ded,
          cap: @breach_cap,
          items:
            Enum.map(
              statuses,
              &%{invariant_id: &1.id, state: &1.state, value: &1.value, limit: &1.limit}
            )
        }
      ],
      inputs: %{
        alert_ids: Enum.map(alerts, & &1.id),
        invariant_ids: Enum.map(statuses, & &1.id)
      }
    }
  end

  def band(s) when s >= 80, do: "low"
  def band(s) when s >= 60, do: "elevated"
  def band(s) when s >= 40, do: "high"
  def band(_), do: "critical"

  defp confidence([]), do: "low"

  defp confidence(statuses) do
    warming = Enum.count(statuses, &(&1.state == :warming_up))

    cond do
      warming == 0 -> "high"
      warming < length(statuses) -> "medium"
      true -> "low"
    end
  end

  @doc "Protocols an alert counts against (see moduledoc)."
  def attribute(%Alert{lane: "invariant", rule_id: id}, inv_protocol) do
    List.wrap(Map.get(inv_protocol, id))
  end

  def attribute(%Alert{evidence: evidence}, _inv_protocol) do
    net =
      Enum.reduce(evidence, %{}, fn e, acc ->
        v = e[:value_usd] || 0

        if e[:kind] == "erc20_transfer" and is_number(v) and v > 0 do
          acc
          |> add(party(e, "from"), v)
          |> add(party(e, "to"), -v)
        else
          acc
        end
      end)

    outflow = for {p, n} <- net, n > 0, do: p

    contract =
      for e <- evidence, e[:kind] in @contract_kinds, p = party(e, "contract"), p != nil, do: p

    Enum.uniq(outflow ++ contract)
  end

  defp add(acc, nil, _), do: acc
  defp add(acc, p, v), do: Map.update(acc, p, v, &(&1 + v))

  defp party(e, role) do
    Enum.find_value(e[:labels] || [], fn l ->
      if l["role"] == role and l["category"] not in ["token", "stablecoin", "oracle"],
        do: l["protocol"]
    end)
  end
end

defmodule ChainGuard.Risk.Server do
  @moduledoc """
  Keeps the latest score per protocol. Recomputes after every block, on
  every alert event and once a minute (alert deductions decay with time).
  A score that changes (or appears for the first time) is broadcast on
  `risk:scores`, which the audit writer records and the live channel pushes.
  """

  use GenServer

  alias ChainGuard.{Invariants, Risk}
  alias ChainGuard.Alerts.Manager

  @tick_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def recompute, do: GenServer.cast(__MODULE__, :recompute)
  def scores, do: GenServer.call(__MODULE__, :scores)
  def get(protocol), do: GenServer.call(__MODULE__, {:get, protocol})

  @doc false
  def sync, do: GenServer.call(__MODULE__, :sync)

  @doc false
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(ChainGuard.PubSub, "alerts:global")
    Process.send_after(self(), :tick, @tick_ms)
    {:ok, %{scores: %{}}}
  end

  @impl true
  def handle_cast(:recompute, s), do: {:noreply, run(s)}

  @impl true
  def handle_info({:alert, _event, _alert}, s), do: {:noreply, run(s)}

  def handle_info(:tick, s) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, run(s)}
  end

  @impl true
  def handle_call(:scores, _from, s), do: {:reply, s.scores, s}
  def handle_call({:get, p}, _from, s), do: {:reply, Map.get(s.scores, p), s}
  def handle_call(:sync, _from, s), do: {:reply, :ok, run(s)}
  def handle_call(:reset, _from, _s), do: {:reply, :ok, %{scores: %{}}}

  defp run(s) do
    invariants = Enum.map(Invariants.list(), &%{id: &1.id, protocol: &1.protocol})
    now = System.system_time(:millisecond)
    next = Risk.score_all(Manager.recent(2_000), invariants, Invariants.statuses(), now)

    # Note: not a `for` with `prev = ...`: in a comprehension that match is a
    # filter, and a protocol's first score (prev == nil) would be dropped.
    changed =
      Enum.filter(next, fn {p, sc} ->
        prev = Map.get(s.scores, p)

        prev == nil or prev.score != sc.score or prev.band != sc.band or
          prev.confidence != sc.confidence
      end)

    for {p, sc} <- changed do
      Phoenix.PubSub.broadcast(ChainGuard.PubSub, "risk:scores", {:score, p, sc})
    end

    if changed != [] do
      ChainGuardWeb.Endpoint.broadcast("live:1", "scores", %{scores: Map.values(next)})
    end

    # Keep the previous record (and its timestamp) when only decay moved
    # sub-point values: the audit chain records changes, not ticks.
    changed_set = MapSet.new(changed, &elem(&1, 0))

    scores =
      Map.new(next, fn {p, sc} ->
        if MapSet.member?(changed_set, p),
          do: {p, Map.put(sc, :as_of_ms, now)},
          else: {p, Map.merge(sc, Map.take(Map.get(s.scores, p, %{}), [:as_of_ms]))}
      end)

    %{s | scores: scores}
  end
end
