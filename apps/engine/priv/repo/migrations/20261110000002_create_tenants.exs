defmodule ChainGuard.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  # Invariant 6: on-chain data is public, but each organization's
  # watchlist, labels and alert routing are confidential and isolated.
  def change do
    create table(:orgs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :slug, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:orgs, [:slug])

    create table(:api_keys, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, references(:orgs, type: :uuid, on_delete: :delete_all), null: false
      # Public identifier embedded in the key (cg_<prefix>_<secret>).
      add :prefix, :text, null: false
      # SHA-256 of the secret part; the secret itself is never stored.
      add :secret_hash, :binary, null: false
      add :role, :text, null: false
      add :label, :text
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:api_keys, [:prefix])
    create index(:api_keys, [:org_id])
    create constraint(:api_keys, :role_valid, check: "role IN ('viewer', 'analyst', 'admin')")

    create table(:watchlist_entries, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, references(:orgs, type: :uuid, on_delete: :delete_all), null: false
      add :address, :text, null: false
      add :label, :text
      add :note, :text
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:watchlist_entries, [:org_id, :address])

    create constraint(:watchlist_entries, :address_lowercase_hex,
             check: "address ~ '^0x[0-9a-f]{40}$'"
           )

    create table(:routes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :org_id, references(:orgs, type: :uuid, on_delete: :delete_all), null: false
      add :kind, :text, null: false
      add :min_severity, :text, null: false, default: "high"
      # Destination settings (URL, secret, routing key, chat id): confidential.
      add :config, :map, null: false
      add :enabled, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end

    create index(:routes, [:org_id])
    create constraint(:routes, :kind_valid, check: "kind IN ('webhook', 'pagerduty', 'telegram')")

    create constraint(:routes, :min_severity_valid,
             check: "min_severity IN ('info', 'low', 'medium', 'high', 'critical')"
           )
  end
end
