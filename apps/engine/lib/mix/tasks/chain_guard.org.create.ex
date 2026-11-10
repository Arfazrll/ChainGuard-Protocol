defmodule Mix.Tasks.ChainGuard.Org.Create do
  @shortdoc "Create an organization and print its first admin API key"
  @moduledoc """
      mix chain_guard.org.create "Acme Risk"
      mix chain_guard.org.create "Acme Risk" --watch 0x2718...25d3:Euler --watch 0x...

  The key is printed once and stored only as a hash. Use it as
  `Authorization: Bearer <key>` on `/api/org/*`, or as the `token` socket
  parameter for `alerts:org:<org_id>`. `--watch ADDRESS[:LABEL]` adds
  watchlist entries at creation.
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(args) do
    # The key is printed once; keep SQL debug logs out of that output.
    Logger.configure(level: :warning)
    {opts, rest, _} = OptionParser.parse(args, strict: [watch: :keep])

    case rest do
      [name | _] -> create(name, Keyword.get_values(opts, :watch))
      [] -> Mix.raise(~s(usage: mix chain_guard.org.create "Org name" [--watch ADDRESS[:LABEL]]))
    end
  end

  defp create(name, watches) do
    {:ok, _, _} =
      Ecto.Migrator.with_repo(ChainGuard.Repo, fn _ ->
        case ChainGuard.Tenants.create_org(name) do
          {:ok, org, _key, plaintext} ->
            Mix.shell().info("org #{org.slug} (#{org.id})")
            Mix.shell().info("admin API key (shown once): #{plaintext}")

            for w <- watches do
              {address, label} =
                case String.split(w, ":", parts: 2) do
                  [a, l] -> {a, l}
                  [a] -> {a, nil}
                end

              case ChainGuard.Tenants.add_watch(org.id, %{address: address, label: label}) do
                {:ok, entry} -> Mix.shell().info("watching #{entry.address}")
                {:error, cs} -> Mix.raise("bad --watch #{w}: #{inspect(cs.errors)}")
              end
            end

          {:error, %Ecto.Changeset{} = cs} ->
            Mix.raise("could not create org: #{inspect(cs.errors)}")

          {:error, e} ->
            Mix.raise("could not create org: #{inspect(e)}")
        end
      end)
  end
end
