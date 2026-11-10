defmodule ChainGuard.Repo.Migrations.CreateAuditLog do
  use Ecto.Migration

  # Invariant 4: every alert and score is written append-only with its
  # inputs, sources, a timestamp and a hash chain. The table refuses UPDATE,
  # DELETE and TRUNCATE at the database level; ChainGuard.Audit.verify/0
  # detects any change made by someone who bypasses that (e.g. a superuser).
  def up do
    create table(:audit_log, primary_key: false) do
      add :seq, :bigint, primary_key: true
      add :kind, :text, null: false
      add :subject, :text, null: false
      # nil for public entries; set for tenant-scoped entries (invariant 6)
      add :org_id, :uuid
      add :recorded_at, :utc_datetime_usec, null: false
      # The exact canonical JSON that was hashed (seq, kind, subject, org_id,
      # recorded_at, payload, prev_hash). Stored as text, not jsonb, so the
      # hashed bytes are preserved verbatim.
      add :body, :text, null: false
      add :prev_hash, :text, null: false
      add :hash, :text, null: false
    end

    create unique_index(:audit_log, [:hash])
    create index(:audit_log, [:subject])
    create index(:audit_log, [:kind])
    create index(:audit_log, [:org_id])

    execute """
    CREATE FUNCTION audit_log_append_only() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'audit_log is append-only (% refused)', TG_OP
        USING ERRCODE = 'insufficient_privilege';
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER audit_log_no_update_delete
      BEFORE UPDATE OR DELETE ON audit_log
      FOR EACH ROW EXECUTE FUNCTION audit_log_append_only()
    """

    execute """
    CREATE TRIGGER audit_log_no_truncate
      BEFORE TRUNCATE ON audit_log
      FOR EACH STATEMENT EXECUTE FUNCTION audit_log_append_only()
    """
  end

  def down do
    # Dropping the audit log is a deliberate, destructive act: only via a
    # fresh database (mix ecto.reset), never as a routine rollback.
    raise "refusing to roll back the audit log; drop the database instead"
  end
end
