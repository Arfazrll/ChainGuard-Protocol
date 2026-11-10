defmodule ChainGuard.AuditTest do
  use ChainGuard.DataCase, async: false

  alias ChainGuard.{Audit, Chain, Invariants, Stats}
  alias ChainGuard.Alerts.Manager
  alias ChainGuard.Audit.{Canonical, Entry, Writer}
  import ChainGuard.Fixtures

  describe "hash chain" do
    test "invariant 4: entries form a hash chain that verify/0 re-derives" do
      assert {:ok, %{entries: 0, head: genesis}} = Audit.verify()
      assert genesis == Audit.genesis()

      {:ok, a} = Audit.append("score", "protocol:euler", %{score: 100, band: "low"})

      {:ok, b} =
        Audit.append("alert.raised", "alert:x", %{severity: :critical, sources: ["a", "b"]})

      {:ok, c} =
        Audit.append("org.match", "alert:x", %{matched: ["0xabc"]}, org_id: Ecto.UUID.generate())

      assert [a.seq, b.seq, c.seq] == [1, 2, 3]
      assert a.prev_hash == Audit.genesis() and b.prev_hash == a.hash and c.prev_hash == b.hash
      assert Audit.hash(b.body) == b.hash
      assert {:ok, %{entries: 3, head: head}} = Audit.verify(batch: 2)
      assert head == c.hash and Audit.head().hash == c.hash

      # The hashed body is canonical JSON and carries its own position.
      assert %{"seq" => 2, "prev_hash" => prev, "payload" => %{"severity" => "critical"}} =
               Jason.decode!(b.body)

      assert prev == a.hash
    end

    test "canonical JSON is byte-for-byte deterministic" do
      x = %{b: 1, a: %{d: [3, %{z: 1, y: 2}], c: :atom}, t: ~U[2026-11-10 10:00:00.123456Z]}

      y = %{
        "t" => ~U[2026-11-10 10:00:00.123456Z],
        "a" => %{"c" => "atom", "d" => [3, %{"y" => 2, "z" => 1}]},
        "b" => 1
      }

      assert Canonical.encode(x) == Canonical.encode(y)

      assert Canonical.encode(x) ==
               ~s({"a":{"c":"atom","d":[3,{"y":2,"z":1}]},"b":1,"t":"2026-11-10T10:00:00.123456Z"})
    end

    test "invariant 4: the database refuses UPDATE, DELETE and TRUNCATE on the audit log" do
      {:ok, _} = Audit.append("score", "protocol:euler", %{score: 100})

      for sql <- [
            "UPDATE audit_log SET subject = 'x'",
            "DELETE FROM audit_log",
            "TRUNCATE audit_log"
          ] do
        assert_raise Postgrex.Error, ~r/audit_log is append-only/, fn ->
          Repo.transaction(fn -> Repo.query!(sql) end)
        end
      end

      assert {:ok, %{entries: 1}} = Audit.verify()
    end

    test "invariant 4: an edit that bypasses the database guard is detected at that entry" do
      for i <- 1..4, do: {:ok, _} = Audit.append("score", "protocol:p#{i}", %{score: 90 + i})

      # A superuser (or the table owner) can switch the guard off. The chain
      # still exposes what they changed.
      Repo.query!("ALTER TABLE audit_log DISABLE TRIGGER audit_log_no_update_delete")

      # 1. Change a payload without fixing the hash.
      Repo.query!(
        "UPDATE audit_log SET body = replace(body, '\"score\":92', '\"score\":12') WHERE seq = 2"
      )

      assert {:error, %{seq: 2, reason: "hash does not match the stored body", checked: 1}} =
               Audit.verify()

      # 2. Fix the hash too: the next entry's link breaks instead.
      tampered = Repo.one!(from(e in Entry, where: e.seq == 2, select: e.body))
      Repo.query!("UPDATE audit_log SET hash = $1 WHERE seq = 2", [Audit.hash(tampered)])

      assert {:error, %{seq: 3, reason: "prev_hash does not match the previous entry"}} =
               Audit.verify()

      # 3. Delete an entry: a gap in the sequence.
      Repo.query!("DELETE FROM audit_log WHERE seq = 4")
      Repo.query!("ALTER TABLE audit_log ENABLE TRIGGER audit_log_no_update_delete")
      {:ok, _} = Audit.append("score", "protocol:p5", %{score: 1})
      assert {:error, %{seq: 3}} = Audit.verify()
    end
  end

  describe "writer" do
    setup :enable_audit

    setup do
      Chain.reset()
      Manager.reset()
      Stats.reset()
      Invariants.reset()
      :ok
    end

    test "invariant 4: every alert event is written with its inputs and sources" do
      b = block(10)
      Enum.each(adopt(1, b, euler_like_drain(b)), &(:ok = Chain.handle(&1)))
      Chain.handle(orphan(7, b))
      # Score changes are recorded too; let them land before reading.
      :ok = ChainGuard.Risk.Server.sync()
      :ok = Writer.flush()

      entries = Audit.list(limit: 100) |> Enum.reverse()
      kinds = entries |> Enum.map(& &1.kind) |> Enum.frequencies()
      assert kinds["alert.raised"] == 2, "rule lane and invariant lane"
      assert kinds["alert.retracted"] == 2, "a reorg retraction is part of the record"

      raised = Enum.find(entries, &(&1.kind == "alert.raised"))
      body = Jason.decode!(raised.body)
      assert body["subject"] == raised.subject and raised.subject =~ "alert:"
      payload = body["payload"]
      assert payload["sources"] == ["node-a", "node-b"]
      assert payload["min_attestations"] == 2
      assert [%{"tx_hash" => _, "block_hash" => bh, "log_index" => _} | _] = payload["inputs"]
      assert bh == b["hash"]
      assert payload["rule"]["version"] == 1

      assert {:ok, %{entries: n}} = Audit.verify()
      assert n == length(entries)
      assert %{state: :ok, queued: 0} = Writer.status()
    end
  end
end
