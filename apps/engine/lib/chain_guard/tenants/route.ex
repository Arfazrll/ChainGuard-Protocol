defmodule ChainGuard.Tenants.Route do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "routes" do
    field(:org_id, :binary_id)
    field(:kind, :string)
    field(:min_severity, :string, default: "high")
    field(:config, :map, redact: true)
    field(:enabled, :boolean, default: true)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(r, attrs) do
    r
    |> cast(attrs, [:kind, :min_severity, :config, :enabled])
    |> validate_required([:kind, :config])
    |> validate_inclusion(:kind, ~w(webhook pagerduty telegram))
    |> validate_inclusion(:min_severity, ChainGuard.Tenants.severities())
    |> validate_config()
  end

  defp validate_config(cs) do
    config = get_field(cs, :config) || %{}

    needed =
      case get_field(cs, :kind) do
        "webhook" -> ~w(url secret)
        "pagerduty" -> ~w(routing_key)
        "telegram" -> ~w(bot_token chat_id)
        _ -> []
      end

    missing = Enum.reject(needed, &is_binary(config[&1]))

    cs =
      if missing == [],
        do: cs,
        else: add_error(cs, :config, "missing #{Enum.join(missing, ", ")}")

    case {get_field(cs, :kind), config["url"]} do
      {"webhook", url} when is_binary(url) ->
        if String.starts_with?(url, ["https://", "http://localhost", "http://127.0.0.1"]),
          do: cs,
          else: add_error(cs, :config, "webhook url must be https (http only for localhost)")

      _ ->
        cs
    end
  end
end
