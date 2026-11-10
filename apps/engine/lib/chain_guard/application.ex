defmodule ChainGuard.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ChainGuardWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:chain_guard, :dns_cluster_query) || :ignore},
        ChainGuard.Repo,
        {Phoenix.PubSub, name: ChainGuard.PubSub},
        ChainGuardWeb.RateLimit,
        {Registry, keys: :unique, name: ChainGuard.Rules.Registry},
        {Registry, keys: :unique, name: ChainGuard.Invariants.Registry},
        {Registry, keys: :unique, name: ChainGuard.Chain.Registry},
        {Task.Supervisor, name: ChainGuard.TaskSupervisor},
        ChainGuard.Stats,
        ChainGuard.Ingest.DeadLetter,
        ChainGuard.Alerts.Manager,
        # Invariant 4: every alert event and score change, hash-chained in PostgreSQL.
        ChainGuard.Audit.Writer,
        # One supervised process per rule: a crashing rule restarts alone.
        ChainGuard.Rules.Supervisor,
        # One supervised process per invariant (per protocol, per property).
        ChainGuard.Invariants.Supervisor,
        # ML lane client: off the hot path, degrades to "unavailable".
        ChainGuard.Anomaly,
        ChainGuard.Risk.Server,
        # Invariant 6: public alerts reach only the orgs whose watchlists they touch.
        ChainGuard.Tenants.Matcher,
        {DynamicSupervisor, name: ChainGuard.Chain.Supervisor, strategy: :one_for_one},
        ChainGuardWeb.Endpoint
      ] ++ pipeline()

    Supervisor.start_link(children, strategy: :one_for_one, name: ChainGuard.Supervisor)
  end

  # The bus consumer starts last, once rules, alerting and the web layer are up.
  defp pipeline do
    case Application.get_env(:chain_guard, :source) do
      nil -> []
      source -> [{ChainGuard.Ingest.Pipeline, source: source}]
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ChainGuardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
