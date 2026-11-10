defmodule ChainGuard.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ChainGuardWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:chain_guard, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ChainGuard.PubSub},
        {Registry, keys: :unique, name: ChainGuard.Rules.Registry},
        {Registry, keys: :unique, name: ChainGuard.Chain.Registry},
        {Task.Supervisor, name: ChainGuard.TaskSupervisor},
        ChainGuard.Stats,
        ChainGuard.Ingest.DeadLetter,
        ChainGuard.Alerts.Manager,
        # One supervised process per rule: a crashing rule restarts alone.
        ChainGuard.Rules.Supervisor,
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
