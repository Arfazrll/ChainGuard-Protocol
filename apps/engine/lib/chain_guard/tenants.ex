defmodule ChainGuard.Tenants do
  @moduledoc """
  Organizations, API keys, roles, watchlists and alert routes (invariant 6).

  On-chain data and the alerts derived from it are public. What each
  organization watches, how it labels it and where its alerts go are
  confidential: every query here is scoped by `org_id`, and nothing in this
  module returns another organization's data.

  **API keys** look like `cg_<prefix>_<secret>`. Only the prefix and a
  SHA-256 of the secret are stored; the full key is shown once, at creation.

  **Roles** (each includes the ones before it):

  | Role      | Can                                                            |
  |-----------|----------------------------------------------------------------|
  | `viewer`  | read its org, watchlist and the alerts that match it           |
  | `analyst` | + add and remove watchlist entries                             |
  | `admin`   | + manage alert routes and API keys                             |
  """

  import Ecto.Query
  alias ChainGuard.Repo
  alias ChainGuard.Tenants.{ApiKey, Org, Route, WatchlistEntry}

  @roles ~w(viewer analyst admin)
  @severities ~w(info low medium high critical)

  def roles, do: @roles

  @doc "Does `role` include the permissions of `needed`?"
  def allows?(role, needed),
    do: Enum.find_index(@roles, &(&1 == role)) >= Enum.find_index(@roles, &(&1 == needed))

  # --- orgs and keys ------------------------------------------------------------

  @doc "Create an org and its first admin key. Returns the plaintext key once."
  def create_org(name, opts \\ []) do
    slug = Keyword.get(opts, :slug, slugify(name))

    Repo.transaction(fn ->
      org =
        case %Org{} |> Org.changeset(%{name: name, slug: slug}) |> Repo.insert() do
          {:ok, org} -> org
          {:error, cs} -> Repo.rollback(cs)
        end

      case create_key(org, "admin", Keyword.get(opts, :key_label, "bootstrap")) do
        {:ok, key, plaintext} -> {org, key, plaintext}
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
    |> case do
      {:ok, {org, key, plaintext}} -> {:ok, org, key, plaintext}
      {:error, e} -> {:error, e}
    end
  end

  def get_org(id), do: Repo.get(Org, id)

  def create_key(%Org{id: org_id}, role, label \\ nil) when role in @roles do
    prefix = random(6)
    secret = random(24)

    %ApiKey{org_id: org_id, prefix: prefix, secret_hash: hash(secret), role: role, label: label}
    |> Repo.insert()
    |> case do
      {:ok, key} -> {:ok, key, "cg_#{prefix}_#{secret}"}
      error -> error
    end
  end

  def list_keys(org_id),
    do: Repo.all(from(k in ApiKey, where: k.org_id == ^org_id, order_by: k.inserted_at))

  def revoke_key(org_id, key_id) do
    case Repo.get_by(ApiKey, id: key_id, org_id: org_id) do
      nil ->
        {:error, :not_found}

      key ->
        key |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update()
    end
  end

  @doc """
  Resolve a bearer token to `{org, role, key_id}`. Unknown, malformed and
  revoked keys all return `:error` (no oracle for which part was wrong).
  """
  def authenticate("cg_" <> rest) do
    with [prefix, secret] <- String.split(rest, "_", parts: 2),
         %ApiKey{revoked_at: nil} = key <- Repo.get_by(ApiKey, prefix: prefix),
         true <- Plug.Crypto.secure_compare(hash(secret), key.secret_hash),
         %Org{} = org <- Repo.get(Org, key.org_id) do
      touch(key)
      {:ok, %{org: org, role: key.role, key_id: key.id}}
    else
      _ ->
        # Same cost whether or not the prefix exists.
        _ = hash(rest)
        :error
    end
  end

  def authenticate(_), do: :error

  defp touch(key) do
    Repo.update_all(from(k in ApiKey, where: k.id == ^key.id),
      set: [last_used_at: DateTime.utc_now()]
    )
  end

  # --- watchlist ----------------------------------------------------------------

  def list_watchlist(org_id),
    do: Repo.all(from(w in WatchlistEntry, where: w.org_id == ^org_id, order_by: w.inserted_at))

  def add_watch(org_id, attrs) do
    %WatchlistEntry{org_id: org_id}
    |> WatchlistEntry.changeset(attrs)
    |> Repo.insert()
    |> tap(fn _ -> ChainGuard.Tenants.Matcher.reload() end)
  end

  def remove_watch(org_id, id) do
    case Repo.get_by(WatchlistEntry, id: id, org_id: org_id) do
      nil -> {:error, :not_found}
      w -> Repo.delete(w) |> tap(fn _ -> ChainGuard.Tenants.Matcher.reload() end)
    end
  end

  @doc "Every watched address, for the matcher: %{address => [org_id]}."
  def watch_index do
    from(w in WatchlistEntry, select: {w.address, w.org_id})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # --- routes -------------------------------------------------------------------

  def list_routes(org_id),
    do: Repo.all(from(r in Route, where: r.org_id == ^org_id, order_by: r.inserted_at))

  def enabled_routes(org_id),
    do: Repo.all(from(r in Route, where: r.org_id == ^org_id and r.enabled))

  def add_route(org_id, attrs) do
    %Route{org_id: org_id} |> Route.changeset(attrs) |> Repo.insert()
  end

  def remove_route(org_id, id) do
    case Repo.get_by(Route, id: id, org_id: org_id) do
      nil -> {:error, :not_found}
      r -> Repo.delete(r)
    end
  end

  @doc "A route as the API shows it: destination secrets are never returned."
  def describe_route(%Route{} = r) do
    %{
      id: r.id,
      kind: r.kind,
      min_severity: r.min_severity,
      enabled: r.enabled,
      destination: redact(r.kind, r.config),
      inserted_at: r.inserted_at
    }
  end

  defp redact("webhook", %{"url" => url}),
    do: %{url: URI.parse(url) |> Map.put(:query, nil) |> to_string()}

  defp redact("telegram", %{"chat_id" => chat}), do: %{chat_id: chat}
  defp redact("pagerduty", _), do: %{routing_key: "(hidden)"}
  defp redact(_, _), do: %{}

  def severities, do: @severities

  # --- helpers ------------------------------------------------------------------

  def hash(secret), do: :crypto.hash(:sha256, secret)

  defp random(bytes),
    do:
      :crypto.strong_rand_bytes(bytes)
      |> Base.url_encode64(padding: false)
      |> String.replace(["_", "-"], "x")

  defp slugify(name),
    do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
end
