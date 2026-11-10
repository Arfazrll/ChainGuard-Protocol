defmodule ChainGuard.Tenants.ApiKey do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_keys" do
    field(:org_id, :binary_id)
    field(:prefix, :string)
    field(:secret_hash, :binary, redact: true)
    field(:role, :string)
    field(:label, :string)
    field(:last_used_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
