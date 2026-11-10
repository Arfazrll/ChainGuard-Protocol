defmodule ChainGuard.DataCase do
  @moduledoc """
  Tests that touch PostgreSQL. Each test runs inside a transaction that is
  rolled back afterwards (Ecto SQL sandbox).

  The engine's long-lived processes (audit writer, tenant matcher) are not
  owned by the test, so database tests run `async: false` in shared mode,
  which lets those processes use the test's transaction.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias ChainGuard.Repo
      import Ecto.Query
      import ChainGuard.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ChainGuard.Repo, shared: not tags[:async])
    # The tenant matcher caches watchlists; rebuild it from this test's
    # (empty) database, and forget it afterwards.
    :ok = ChainGuard.Tenants.Matcher.sync()

    on_exit(fn ->
      ChainGuard.Tenants.Matcher.clear()
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    :ok
  end

  @doc "Turn the audit writer on for this test."
  def enable_audit(_context \\ %{}) do
    ChainGuard.Audit.Writer.reset()
    Application.put_env(:chain_guard, :audit, true)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:chain_guard, :audit, false)
      # Nothing queued for this test's (rolled-back) database leaks into the next.
      ChainGuard.Audit.Writer.reset()
    end)

    :ok
  end
end
