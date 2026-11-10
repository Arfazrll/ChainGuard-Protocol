defmodule ChainGuard.Tenants.Org do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "orgs" do
    field(:name, :string)
    field(:slug, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name, :slug])
    |> validate_length(:name, max: 120)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]{1,62}$/)
    |> unique_constraint(:slug)
  end
end
