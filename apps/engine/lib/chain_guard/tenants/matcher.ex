defmodule ChainGuard.Tenants.Matcher do
  @moduledoc """
  Delivers public alerts to the organizations that watch them.

  For every alert lifecycle event, the addresses in its evidence (parties,
  contracts, labeled addresses) are matched against every org's watchlist.
  A matching org gets:

    * the event on its private channel `alerts:org:<org_id>`;
    * delivery to its own routes (webhook, PagerDuty, Telegram), through the
      same retrying fan-out as global connectors;
    * an org-scoped audit entry (`org.match`), invisible to other orgs.

  Watchlists live in PostgreSQL and are cached in this process, reloaded
  whenever one changes. Nothing about one org's watchlist or routes ever
  reaches another org (invariant 6).
  """

  use GenServer
  require Logger

  alias ChainGuard.Alerts.{Alert, Fanout}
  alias ChainGuard.Audit.Writer
  alias ChainGuard.Tenants

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def reload, do: GenServer.cast(__MODULE__, :reload)

  @doc false
  def sync, do: GenServer.call(__MODULE__, :sync)

  # Test isolation: forget a cache built from a rolled-back database.
  @doc false
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(ChainGuard.PubSub, "alerts:global")
    {:ok, %{index: %{}}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, s), do: {:noreply, load(s)}

  @impl true
  def handle_cast(:reload, s), do: {:noreply, load(s)}

  @impl true
  def handle_call(:sync, _from, s), do: {:reply, :ok, load(s)}
  def handle_call(:clear, _from, s), do: {:reply, :ok, %{s | index: %{}}}

  @impl true
  def handle_info({:alert, event, %Alert{} = a}, s) do
    for org_id <- match(a, s.index) do
      Phoenix.PubSub.broadcast(ChainGuard.PubSub, "alerts:org:" <> org_id, {:org_alert, event, a})

      if event == :raised do
        Writer.record(
          "org.match",
          "alert:" <> a.id,
          %{alert_id: a.id, matched: matched_addresses(a, s.index, org_id)},
          org_id: org_id
        )
      end

      deliver_to_routes(org_id, event, a)
    end

    {:noreply, s}
  end

  defp load(s) do
    %{s | index: Tenants.watch_index()}
  rescue
    e ->
      Logger.error("watchlist index unavailable: #{Exception.message(e)}")
      s
  end

  @doc "Every address an alert's evidence touches, lowercased."
  def addresses(%Alert{evidence: evidence}) do
    evidence
    |> Enum.flat_map(fn e ->
      event_addrs =
        (e[:event] || %{})
        |> Map.take(~w(from to owner spender receiver initiator account new_owner previous_owner))
        |> Map.values()

      [e[:contract] | event_addrs] ++ Enum.map(e[:labels] || [], & &1["address"])
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  def match(alert, index) do
    alert |> addresses() |> Enum.flat_map(&Map.get(index, &1, [])) |> Enum.uniq()
  end

  defp matched_addresses(alert, index, org_id),
    do: for(a <- addresses(alert), org_id in Map.get(index, a, []), do: a)

  defp deliver_to_routes(org_id, event, alert) do
    connectors =
      for r <- Tenants.enabled_routes(org_id),
          c = connector(r),
          c != nil,
          do: c

    Fanout.dispatch(event, alert, connectors)
  rescue
    e -> Logger.error("org routes unavailable for #{org_id}: #{Exception.message(e)}")
  end

  defp connector(%{kind: "webhook", config: c, min_severity: min}),
    do: {ChainGuard.Alerts.Webhook, url: c["url"], secret: c["secret"], min_severity: sev(min)}

  defp connector(%{kind: "pagerduty", config: c, min_severity: min}),
    do: {ChainGuard.Alerts.PagerDuty, routing_key: c["routing_key"], min_severity: sev(min)}

  defp connector(%{kind: "telegram", config: c, min_severity: min}),
    do:
      {ChainGuard.Alerts.Telegram,
       bot_token: c["bot_token"], chat_id: c["chat_id"], min_severity: sev(min)}

  defp connector(_), do: nil

  defp sev(s), do: String.to_existing_atom(s)
end
