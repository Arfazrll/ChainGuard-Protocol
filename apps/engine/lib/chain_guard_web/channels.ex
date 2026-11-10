defmodule ChainGuardWeb.UserSocket do
  @moduledoc """
  Live transport for the dashboard.

  Milestone 2 serves public on-chain data and public rules only, so the
  socket is unauthenticated. Tenant-scoped topics (`alerts:org:<id>`) with
  per-org watchlists and routing come with auth in milestone 4. They will
  require a signed token here (invariant 6).
  """
  use Phoenix.Socket

  channel "alerts:global", ChainGuardWeb.AlertsChannel
  channel "live:*", ChainGuardWeb.LiveChannel

  @impl true
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
           ml: ChainGuard.Anomaly.status()
         }, assign(socket, :chain_id, id)}

      _ ->
        {:error, %{reason: "unknown chain"}}
    end
  end
end
