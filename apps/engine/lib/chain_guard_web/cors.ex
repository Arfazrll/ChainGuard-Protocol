defmodule ChainGuardWeb.Cors do
  @moduledoc "Minimal CORS for the read-only API and the socket origin check."
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "origin") do
      [origin] ->
        if allowed?(origin) do
          conn =
            conn
            |> put_resp_header("access-control-allow-origin", origin)
            |> put_resp_header("vary", "origin")

          if conn.method == "OPTIONS" do
            conn
            |> put_resp_header("access-control-allow-methods", "GET, OPTIONS")
            |> put_resp_header("access-control-allow-headers", "content-type")
            |> send_resp(204, "")
            |> halt()
          else
            conn
          end
        else
          conn
        end

      _ ->
        conn
    end
  end

  def allowed?(origin), do: origin in Application.get_env(:chain_guard, :cors_origins, [])

  @doc "Used as the socket `check_origin` callback."
  def origin_allowed?(%URI{} = uri) do
    port = if uri.port in [80, 443, nil], do: "", else: ":#{uri.port}"

    allowed?("#{uri.scheme}://#{uri.host}#{port}") or
      Application.get_env(:chain_guard, :allow_any_socket_origin, false)
  end
end
