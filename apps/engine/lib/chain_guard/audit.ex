defmodule ChainGuard.Audit do
  @moduledoc """
  The tamper-evident audit trail (invariant 4).

  Every alert lifecycle event and every risk-score change is appended to
  `audit_log` as one entry: what happened, its inputs, the sources consulted
  and a timestamp. Each entry's hash covers its canonical JSON body *and the
  previous entry's hash*, so the log forms a chain:

      hash(n) = sha256(body(n)),  body(n) includes prev_hash = hash(n - 1)

  Guarantees, and their limits:

    * The table is append-only at the database level: UPDATE, DELETE and
      TRUNCATE raise (see the migration).
    * Anyone who bypasses that (a superuser disabling the trigger) and edits
      an entry breaks the chain at that entry: `verify/0` reports the first
      broken sequence number.
    * Rewriting the whole suffix consistently is still possible for a
      superuser, so the current head hash is published (`head/0`,
      `GET /api/audit/head`). An externally recorded head proves the chain
      up to it. This is tamper-*evident*, not tamper-proof.
  """

  import Ecto.Query
  alias ChainGuard.Audit.{Canonical, Entry}
  alias ChainGuard.Repo

  @genesis String.duplicate("0", 64)
  # Serializes appends across engine nodes.
  @lock_key 4_242_001

  def genesis, do: @genesis

  @doc """
  Append one entry. `org_id` is nil for public entries (alerts and scores on
  public chain data) and set for tenant-scoped ones.
  """
  @spec append(String.t(), String.t(), map(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  def append(kind, subject, payload, opts \\ []) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock_key])

      {seq, prev} =
        case Repo.one(
               from(e in Entry, order_by: [desc: e.seq], limit: 1, select: {e.seq, e.hash})
             ) do
          nil -> {1, @genesis}
          {s, h} -> {s + 1, h}
        end

      recorded_at = Keyword.get_lazy(opts, :at, &DateTime.utc_now/0)
      org_id = Keyword.get(opts, :org_id)

      body =
        Canonical.encode(%{
          "seq" => seq,
          "kind" => kind,
          "subject" => subject,
          "org_id" => org_id,
          "recorded_at" => DateTime.to_iso8601(recorded_at),
          "payload" => payload,
          "prev_hash" => prev
        })

      %Entry{
        seq: seq,
        kind: kind,
        subject: subject,
        org_id: org_id,
        recorded_at: recorded_at,
        body: body,
        prev_hash: prev,
        hash: hash(body)
      }
      |> Repo.insert!()
    end)
  end

  def hash(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  @doc "The latest entry's sequence number and hash: publish it to anchor the chain."
  def head do
    case Repo.one(from(e in Entry, order_by: [desc: e.seq], limit: 1)) do
      nil -> %{seq: 0, hash: @genesis, recorded_at: nil}
      e -> %{seq: e.seq, hash: e.hash, recorded_at: e.recorded_at}
    end
  end

  @doc """
  Re-derive every hash from the stored bodies and check every link.
  Streams the table in order, so it scales to large logs.
  """
  @spec verify(keyword()) ::
          {:ok, %{entries: non_neg_integer(), head: String.t()}}
          | {:error, %{seq: integer(), reason: String.t(), checked: non_neg_integer()}}
  def verify(opts \\ []) do
    batch = Keyword.get(opts, :batch, 1_000)
    walk(0, @genesis, 0, batch)
  end

  defp walk(after_seq, prev, checked, batch) do
    rows =
      Repo.all(from(e in Entry, where: e.seq > ^after_seq, order_by: e.seq, limit: ^batch))

    case check(rows, after_seq, prev, checked) do
      {:cont, _last, prev, checked} when length(rows) < batch ->
        {:ok, %{entries: checked, head: prev}}

      {:cont, last, prev, checked} ->
        walk(last, prev, checked, batch)

      {:halt, err} ->
        {:error, err}
    end
  end

  defp check([], last, prev, checked), do: {:cont, last, prev, checked}

  defp check([e | rest], last, prev, checked) do
    fail = fn reason -> {:halt, %{seq: e.seq, reason: reason, checked: checked}} end

    with :ok <- expect(e.seq == last + 1, "gap in sequence after #{last}"),
         :ok <- expect(e.prev_hash == prev, "prev_hash does not match the previous entry"),
         :ok <- expect(hash(e.body) == e.hash, "hash does not match the stored body"),
         {:ok, b} <- Jason.decode(e.body),
         :ok <-
           expect(b["seq"] == e.seq and b["prev_hash"] == prev, "body disagrees with its row"),
         :ok <-
           expect(
             b["kind"] == e.kind and b["subject"] == e.subject and b["org_id"] == e.org_id,
             "body disagrees with its row"
           ) do
      check(rest, e.seq, e.hash, checked + 1)
    else
      {:error, %Jason.DecodeError{}} -> fail.("body is not valid JSON")
      {:error, reason} -> fail.(reason)
    end
  end

  defp expect(true, _), do: :ok
  defp expect(false, reason), do: {:error, reason}

  @doc "Entries, newest first. Tenant-scoped entries only for their own org."
  def list(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> min(500) |> max(1)
    org_id = Keyword.get(opts, :org_id)

    Entry
    |> scope(org_id)
    |> filter(:subject, Keyword.get(opts, :subject))
    |> filter(:kind, Keyword.get(opts, :kind))
    |> order_by(desc: :seq)
    |> limit(^limit)
    |> Repo.all()
  end

  defp scope(q, nil), do: where(q, [e], is_nil(e.org_id))
  defp scope(q, org_id), do: where(q, [e], is_nil(e.org_id) or e.org_id == ^org_id)

  defp filter(q, _field, nil), do: q
  defp filter(q, field, value), do: where(q, [e], field(e, ^field) == ^value)

  @doc "JSON view of an entry: the stored body plus its hashes."
  def describe(%Entry{} = e) do
    %{
      seq: e.seq,
      kind: e.kind,
      subject: e.subject,
      recorded_at: e.recorded_at,
      prev_hash: e.prev_hash,
      hash: e.hash,
      body: e.body
    }
  end
end
