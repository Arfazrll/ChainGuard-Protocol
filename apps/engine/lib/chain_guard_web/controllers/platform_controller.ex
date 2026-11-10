defmodule ChainGuardWeb.AuditController do
  use ChainGuardWeb, :controller

  alias ChainGuard.Audit

  @doc "Public entries (alerts and scores on public chain data), newest first."
  def index(conn, params) do
    entries =
      Audit.list(
        limit: int(params["limit"], 50),
        subject: params["subject"],
        kind: params["kind"],
        org_id: org_id(conn)
      )

    json(conn, %{entries: Enum.map(entries, &Audit.describe/1)})
  end

  def head(conn, _params), do: json(conn, Audit.head())

  @doc "Re-derive every hash and check every link of the chain."
  def verify(conn, _params) do
    case Audit.verify() do
      {:ok, r} ->
        json(conn, %{valid: true, entries: r.entries, head: r.head})

      {:error, e} ->
        conn
        |> put_status(409)
        |> json(%{valid: false, broken_at: e.seq, reason: e.reason, checked: e.checked})
    end
  end

  defp org_id(%{assigns: %{tenant: %{org: org}}}), do: org.id
  defp org_id(_), do: nil

  defp int(nil, d), do: d

  defp int(v, d) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> d
    end
  end
end

defmodule ChainGuardWeb.RiskController do
  use ChainGuardWeb, :controller

  alias ChainGuard.{Audit, Risk}

  def index(conn, _params) do
    scores = Risk.Server.scores() |> Map.values() |> Enum.sort_by(&{&1.score, &1.protocol})
    json(conn, %{model: Risk.model(), scores: scores})
  end

  @doc "One protocol's current score plus its audited history."
  def show(conn, %{"protocol" => p}) do
    case Risk.Server.get(p) do
      nil ->
        conn |> put_status(404) |> json(%{error: "no score for #{p}"})

      score ->
        history =
          Audit.list(subject: "protocol:" <> p, kind: "score", limit: 50)
          |> Enum.map(&Map.take(Audit.describe(&1), [:seq, :recorded_at, :hash, :body]))

        json(conn, %{score: score, history: history})
    end
  end
end

defmodule ChainGuardWeb.OrgController do
  @moduledoc "Tenant-scoped API. The org always comes from the API key."
  use ChainGuardWeb, :controller

  alias ChainGuard.Alerts.Manager
  alias ChainGuard.Tenants
  alias ChainGuard.Tenants.Matcher

  def me(conn, _params) do
    %{org: org, role: role} = conn.assigns.tenant
    json(conn, %{org: %{id: org.id, name: org.name, slug: org.slug}, role: role})
  end

  def watchlist(conn, _params) do
    entries = Tenants.list_watchlist(org(conn))

    json(conn, %{
      entries: Enum.map(entries, &Map.take(&1, [:id, :address, :label, :note, :inserted_at]))
    })
  end

  def add_watch(conn, params) do
    case Tenants.add_watch(org(conn), Map.take(params, ~w(address label note))) do
      {:ok, w} ->
        conn |> put_status(201) |> json(Map.take(w, [:id, :address, :label, :note, :inserted_at]))

      {:error, cs} ->
        invalid(conn, cs)
    end
  end

  def remove_watch(conn, %{"id" => id}) do
    case Tenants.remove_watch(org(conn), id) do
      {:ok, _} -> send_resp(conn, 204, "")
      _ -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  @doc "Recent public alerts whose evidence touches this org's watchlist."
  def alerts(conn, _params) do
    index =
      Tenants.list_watchlist(org(conn))
      |> Map.new(&{&1.address, [org(conn)]})

    alerts = Enum.filter(Manager.recent(500), &(Matcher.match(&1, index) != []))
    json(conn, %{alerts: alerts})
  end

  def routes(conn, _params),
    do: json(conn, %{routes: Enum.map(Tenants.list_routes(org(conn)), &Tenants.describe_route/1)})

  def add_route(conn, params) do
    case Tenants.add_route(org(conn), Map.take(params, ~w(kind min_severity config enabled))) do
      {:ok, r} -> conn |> put_status(201) |> json(Tenants.describe_route(r))
      {:error, cs} -> invalid(conn, cs)
    end
  end

  def remove_route(conn, %{"id" => id}) do
    case Tenants.remove_route(org(conn), id) do
      {:ok, _} -> send_resp(conn, 204, "")
      _ -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def keys(conn, _params) do
    keys =
      Enum.map(
        Tenants.list_keys(org(conn)),
        &Map.take(&1, [:id, :prefix, :role, :label, :last_used_at, :revoked_at, :inserted_at])
      )

    json(conn, %{keys: keys})
  end

  def create_key(conn, params) do
    role = params["role"] || "viewer"

    if role in Tenants.roles() do
      {:ok, k, plaintext} = Tenants.create_key(conn.assigns.tenant.org, role, params["label"])

      conn
      |> put_status(201)
      |> json(%{
        id: k.id,
        role: k.role,
        label: k.label,
        key: plaintext,
        note: "shown once; store it now"
      })
    else
      conn
      |> put_status(422)
      |> json(%{error: "role must be one of #{Enum.join(Tenants.roles(), ", ")}"})
    end
  end

  def revoke_key(conn, %{"id" => id}) do
    case Tenants.revoke_key(org(conn), id) do
      {:ok, _} -> send_resp(conn, 204, "")
      _ -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  defp org(conn), do: conn.assigns.tenant.org.id

  defp invalid(conn, %Ecto.Changeset{} = cs) do
    errors =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)

    conn |> put_status(422) |> json(%{errors: errors})
  end
end
