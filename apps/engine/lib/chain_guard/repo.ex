defmodule ChainGuard.Repo do
  @moduledoc """
  PostgreSQL: the tamper-evident audit chain, tenants, API keys,
  watchlists and alert routes. Public chain data never lives here.
  """
  use Ecto.Repo, otp_app: :chain_guard, adapter: Ecto.Adapters.Postgres
end
