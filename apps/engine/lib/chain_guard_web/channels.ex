defmodule ChainGuardWeb.UserSocket do
  @moduledoc """
  Live transport for the dashboard and the landing page.

  Public topics (`alerts:global`, `live:<chain>`) carry public chain data and
  need no credentials. Tenant topics (`alerts:org:<org_id>`) need an API key,
  passed as the `token` connect parameter, and only that org can join its
  own topic (invariant 6). A token that is present but invalid is refused
  outright rather than silently downgraded to public access.
  """
  use Phoenix.Socket

  channel "alerts:global", ChainGuardWeb.AlertsChannel
  channel "alerts:org:*", ChainGuardWeb.OrgAlertsChannel
  channel "live:*", ChainGuardWeb.LiveChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info)
      when is_binary(token) and token != "" do
    case ChainGuard.Tenants.authenticate(token) do
      {:ok, tenant} -> {:ok, assign(socket, :tenant, tenant)}
      :error -> :error
    end
  end

  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end

defmodule ChainGuardWeb.AlertsChannel do
  @moduledoc """
  `alerts:global`: replies to join with the latest alerts, then pushes
  `alert:raised`, `alert:updated`, `alert:retracted`, `alert:finalized`.
  """
  use Phoenix.Channel

  @impl true
  def join("alerts:global", _params, socket) do
    Phoenix.PubSub.subscribe(ChainGuard.PubSub, "alerts:global")
    {:ok, %{alerts: ChainGuard.Alerts.Manager.recent(100)}, socket}
  end

  @impl true
  def handle_info({:alert, event, alert}, socket) do
    push(socket, "alert:#{event}", alert)
    {:noreply, socket}
  end
end

defmodule ChainGuardWeb.OrgAlertsChannel do
  @moduledoc """
  `alerts:org:<org_id>`: public alerts that touch this org's watchlist.
  Joinable only with that org's API key.
  """
  use Phoenix.Channel

  alias ChainGuard.Alerts.Manager
  alias ChainGuard.Tenants
  alias ChainGuard.Tenants.Matcher

  @impl true
  def join(
        "alerts:org:" <> org_id,
        _params,
        %{assigns: %{tenant: %{org: %{id: org_id}}}} = socket
      ) do
    Phoenix.PubSub.subscribe(ChainGuard.PubSub, "alerts:org:" <> org_id)
    index = org_id |> Tenants.list_watchlist() |> Map.new(&{&1.address, [org_id]})

    alerts =
      Manager.recent(500) |> Enum.filter(&(Matcher.match(&1, index) != [])) |> Enum.take(100)

    {:ok, %{alerts: alerts}, socket}
  end

  def join("alerts:org:" <> _other, _params, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_info({:org_alert, event, alert}, socket) do
    push(socket, "alert:#{event}", alert)
    {:noreply, socket}
  end
end

defmodule ChainGuardWeb.LiveChannel do
  @moduledoc """
  `live:<chain_id>`: replies to join with stats and recent blocks, then
  pushes `block` (with fund-flow edges), `invariants`, `reorg`,
  `block:orphaned` and `integrity_halt` as they happen.
  """
  use Phoenix.Channel

  @impl true
  def join("live:" <> chain, _params, socket) do
    case Integer.parse(chain) do
      {id, ""} ->
        {:ok,
         %{
           stats: ChainGuard.Stats.snapshot(),
           blocks: ChainGuard.Chain.recent_blocks(id),
           flows: ChainGuard.Chain.recent_flows(id),
           invariants: ChainGuard.Invariants.statuses(),
           scores: ChainGuard.Risk.Server.scores() |> Map.values(),
           ml: ChainGuard.Anomaly.status()
         }, assign(socket, :chain_id, id)}

      _ ->
        {:error, %{reason: "unknown chain"}}
    end
  end
end
