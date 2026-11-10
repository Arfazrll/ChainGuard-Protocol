defmodule ChainGuard.Release do
  @moduledoc """
  Operations for a release (Docker image), where Mix is not available:

      bin/chain_guard eval "ChainGuard.Release.migrate()"
      bin/chain_guard eval 'ChainGuard.Release.create_org("Acme Risk")'
  """

  @app :chain_guard

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Create an organization and print its first admin key (shown once)."
  def create_org(name) do
    Application.load(@app)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(ChainGuard.Repo, fn _repo ->
        case ChainGuard.Tenants.create_org(name) do
          {:ok, org, _key, plaintext} ->
            IO.puts("org #{org.slug} (#{org.id})\nadmin API key (shown once): #{plaintext}")

          {:error, e} ->
            IO.puts(:stderr, "could not create org: #{inspect(e)}")
        end
      end)

    :ok
  end
end
