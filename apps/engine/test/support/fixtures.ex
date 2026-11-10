defmodule ChainGuard.Fixtures do
  @moduledoc "Builders for records and stream messages in exactly ingestd's JSON shape."

  def hash(seed),
    do: "0x" <> (:crypto.hash(:sha256, to_string(seed)) |> Base.encode16(case: :lower))

  def addr(seed),
    do:
      "0x" <>
        (:crypto.hash(:sha256, "addr" <> to_string(seed))
         |> Base.encode16(case: :lower)
         |> binary_part(0, 40))

  def block(number, fork \\ "") do
    %{
      "number" => number,
      "hash" => hash("block-#{number}-#{fork}"),
      "parent_hash" => hash("block-#{number - 1}-#{fork}"),
      "timestamp" => 1_700_000_000 + number * 12
    }
  end

  def label(role, address, name, category, protocol \\ nil),
    do: %{
      "role" => role,
      "address" => address,
      "name" => name,
      "category" => category,
      "protocol" => protocol
    }

  @doc "A record. `opts`: :tx, :contract, :labels, :value_usd, :token, :attested_by, :chain_id."
  def record(block, log_index, event, opts \\ []) do
    tx = Keyword.get(opts, :tx, hash("tx-#{block["hash"]}-#{log_index}"))
    labels = Keyword.get(opts, :labels, [])

    %{
      "id" => hash("rec-#{block["hash"]}-#{log_index}"),
      "chain_id" => Keyword.get(opts, :chain_id, 1),
      "block" => block,
      "tx_hash" => tx,
      "tx_index" => 0,
      "log_index" => log_index,
      "contract" => Keyword.get(opts, :contract, addr("token")),
      "event" => event,
      "enrichment" => %{
        "labels" => labels,
        "token" => Keyword.get(opts, :token),
        "price" => nil,
        "value_usd" => Keyword.get(opts, :value_usd),
        "protocol" => Enum.find_value(labels, & &1["protocol"])
      },
      "topics" => [],
      "data" => "0x",
      "attested_by" => Keyword.get(opts, :attested_by, ["node-a", "node-b"]),
      "observed_at_ms" => (block["timestamp"] + 1) * 1000
    }
  end

  def transfer(block, i, from, to, usd, opts \\ []) do
    labels = Keyword.get(opts, :labels, [])

    record(
      block,
      i,
      %{"kind" => "erc20_transfer", "from" => from, "to" => to, "amount" => "1"},
      Keyword.merge(opts,
        labels: labels,
        value_usd: usd,
        token: %{"symbol" => "DAI", "decimals" => 18}
      )
    )
  end

  @doc "`block_adopted` followed by one `upsert` per record, numbered from `seq`."
  def adopt(seq, block, records, chain_id \\ 1) do
    adopted = %{
      "type" => "block_adopted",
      "seq" => seq,
      "chain_id" => chain_id,
      "block" => block,
      "record_count" => length(records),
      "attested_by" => ["node-a", "node-b"]
    }

    upserts =
      records
      |> Enum.with_index(seq + 1)
      |> Enum.map(fn {r, s} ->
        %{
          "type" => "upsert",
          "seq" => s,
          "chain_id" => chain_id,
          "finality" => "provisional",
          "deleted" => false,
          "record" => r
        }
      end)

    [adopted | upserts]
  end

  def orphan(seq, block, replaced_by \\ nil, chain_id \\ 1),
    do: %{
      "type" => "block_orphaned",
      "seq" => seq,
      "chain_id" => chain_id,
      "block" => block,
      "replaced_by" => replaced_by
    }

  def finalize(seq, block, chain_id \\ 1),
    do: %{"type" => "block_finalized", "seq" => seq, "chain_id" => chain_id, "block" => block}

  # --- canned scenarios -----------------------------------------------------

  def euler_like_drain(block, opts \\ []) do
    tx = Keyword.get(opts, :tx, hash("drain-tx"))
    attacker = addr("attacker")
    euler = addr("euler")
    lender = addr("aave-adai")

    euler_label = fn role ->
      label(role, euler, "Euler Finance (main proxy)", "lending", "euler")
    end

    lender_label = fn role -> label(role, lender, "Aave V2 aDAI", "lending", "aave") end
    att = Keyword.get(opts, :attested_by, ["node-a", "node-b"])
    o = [tx: tx, attested_by: att]

    [
      record(
        block,
        0,
        %{
          "kind" => "flash_loan",
          "provider" => "aave_v2",
          "receiver" => attacker,
          "asset" => addr("dai"),
          "amount" => "30000000000000000000000000",
          "fee" => "27000"
        },
        o
      ),
      transfer(block, 1, lender, attacker, 30_000_000.0, o ++ [labels: [lender_label.("from")]]),
      transfer(block, 2, attacker, euler, 30_000_000.0, o ++ [labels: [euler_label.("to")]]),
      transfer(block, 3, euler, attacker, 38_904_507.0, o ++ [labels: [euler_label.("from")]]),
      transfer(block, 4, attacker, lender, 30_027_000.0, o ++ [labels: [lender_label.("to")]])
    ]
  end

  def plain_flash_loan_arbitrage(block) do
    tx = hash("arb-tx")
    trader = addr("arb")
    vault = addr("balancer-vault")
    vault_label = fn role -> label(role, vault, "Balancer V2 Vault", "dex", "balancer") end

    [
      record(
        block,
        0,
        %{
          "kind" => "flash_loan",
          "provider" => "balancer_v2",
          "receiver" => trader,
          "asset" => addr("dai"),
          "amount" => "1",
          "fee" => "0"
        },
        tx: tx
      ),
      transfer(block, 1, vault, trader, 50_000_000.0, tx: tx, labels: [vault_label.("from")]),
      transfer(block, 2, trader, vault, 50_000_000.0, tx: tx, labels: [vault_label.("to")])
    ]
  end
end
