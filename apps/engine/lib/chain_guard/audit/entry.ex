defmodule ChainGuard.Audit.Entry do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:seq, :integer, autogenerate: false}
  schema "audit_log" do
    field(:kind, :string)
    field(:subject, :string)
    field(:org_id, Ecto.UUID)
    field(:recorded_at, :utc_datetime_usec)
    field(:body, :string)
    field(:prev_hash, :string)
    field(:hash, :string)
  end

  @type t :: %__MODULE__{}
end
