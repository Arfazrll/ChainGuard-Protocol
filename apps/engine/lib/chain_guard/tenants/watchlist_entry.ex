defmodule ChainGuard.Tenants.WatchlistEntry do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "watchlist_entries" do
    field(:org_id, :binary_id)
    field(:address, :string)
    field(:label, :string)
    field(:note, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(w, attrs) do
    w
    |> cast(attrs, [:address, :label, :note])
    |> update_change(:address, &String.downcase/1)
    |> validate_required([:address])
    |> validate_format(:address, ~r/^0x[0-9a-f]{40}$/,
      message: "must be a 0x-prefixed 20-byte address"
    )
    |> validate_length(:label, max: 120)
    |> validate_length(:note, max: 1_000)
    |> unique_constraint([:org_id, :address], message: "is already on the watchlist")
  end
end
