defmodule ChainGuardWeb.ApiController do
  use ChainGuardWeb, :controller

  alias ChainGuard.{Chain, Rules, Stats}
  alias ChainGuard.Alerts.Manager

  def health(conn, _params) do
    json(conn, %{
      status: "ok",
      read_only: true,
      chains: Chain.chains(),
      rules_loaded: length(Rules.list()),
      rule_errors: Rules.load_errors(),
      source: source_kind()
    })
  end

  def stats(conn, _params), do: json(conn, Stats.snapshot())

  def rules(conn, _params) do
    json(conn, %{
      rules: Enum.map(Rules.list(), &ChainGuard.Rules.Rule.describe/1),
      errors: Rules.load_errors()
    })
  end

  def alerts(conn, params) do
    limit =
      params
      |> Map.get("limit", "50")
      |> Integer.parse()
      |> then(fn
        {n, _} -> n
        :error -> 50
      end)

    json(conn, %{alerts: Manager.recent(min(max(limit, 1), 500))})
  end

  def alert(conn, %{"id" => id}) do
    case Manager.get(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "not found"})
      a -> json(conn, a)
    end
  end

  defp source_kind do
    case Application.get_env(:chain_guard, :source) do
      {kind, _} -> kind
      nil -> :none
    end
  end
end
