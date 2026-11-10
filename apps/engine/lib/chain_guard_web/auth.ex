defmodule ChainGuardWeb.Auth do
  @moduledoc """
  API-key authentication and role checks.

      plug ChainGuardWeb.Auth                      # require a valid key
      plug ChainGuardWeb.Auth, role: "analyst"     # and at least this role

  Keys arrive as `Authorization: Bearer cg_<prefix>_<secret>`. A request
  without a valid key gets 401; a valid key with too small a role gets 403.
  On success `conn.assigns.tenant` is `%{org, role, key_id}`: every org-scoped
  query takes the org from there, never from the request.
  """

  import Plug.Conn
  alias ChainGuard.Tenants

  def init(opts), do: Keyword.get(opts, :role, "viewer")

  def call(conn, role) do
    with {:ok, token} <- bearer(conn),
         {:ok, tenant} <- Tenants.authenticate(token) do
      if Tenants.allows?(tenant.role, role) do
        assign(conn, :tenant, tenant)
      else
        deny(conn, 403, "this API key's role (#{tenant.role}) cannot do this; needs #{role}")
      end
    else
      _ -> deny(conn, 401, "missing or invalid API key")
    end
  end

  def bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> :error
    end
  end

  defp deny(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end

defmodule ChainGuardWeb.RateLimit do
  @moduledoc """
  Fixed-window rate limit per API key (or per client IP without one).
  Defaults: 600 requests/minute with a key, 120 without. Over the limit the
  API answers 429 with `retry-after`.
  """

  import Plug.Conn

  @table __MODULE__

  def init(opts), do: opts

  def call(conn, _opts) do
    {id, limit} =
      case ChainGuardWeb.Auth.bearer(conn) do
        {:ok, "cg_" <> rest} ->
          {"key:" <> (rest |> String.split("_") |> hd()), limit(:keyed, 600)}

        _ ->
          {"ip:" <> ip(conn), limit(:anonymous, 120)}
      end

    now = System.system_time(:second)
    window = div(now, 60)
    count = :ets.update_counter(@table, {id, window}, 1, {{id, window}, 0})

    conn =
      conn
      |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
      |> put_resp_header("x-ratelimit-remaining", Integer.to_string(max(0, limit - count)))

    if count > limit do
      conn
      |> put_resp_header("retry-after", Integer.to_string(60 - rem(now, 60)))
      |> put_resp_content_type("application/json")
      |> send_resp(429, Jason.encode!(%{error: "rate limit exceeded"}))
      |> halt()
    else
      conn
    end
  end

  defp limit(kind, default),
    do: get_in(Application.get_env(:chain_guard, :rate_limit, []), [kind]) || default

  defp ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  @doc false
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  @doc false
  def start_link do
    Task.start_link(fn ->
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
      sweep()
    end)
  end

  # Drop finished windows once a minute.
  defp sweep do
    Process.sleep(60_000)
    current = div(System.system_time(:second), 60)
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", current}], [true]}])
    sweep()
  end
end
