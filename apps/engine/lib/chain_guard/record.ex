defmodule ChainGuard.Record do
  @moduledoc """
  Access to ingested records (the JSON produced by `chainguard-ingestd`).

  Records stay as plain string-keyed maps, exactly as they arrived on the bus.
  Rules address fields with dotted paths; this module is the single place
  that defines what those paths mean:

    * `kind`: the decoded event kind, e.g. `"erc20_transfer"`
    * `event.<field>`: decoded event fields (`event.amount`, `event.spender`, …)
    * `value_usd`, `protocol`, `token.<field>`, `price.<field>`: enrichment
    * `label.<role>`, `label.<role>.<field>`: public address label for a role
      (`contract`, `from`, `to`, `spender`, `owner`, `receiver`, …)
    * `attestations`: number of independent nodes that attested the record
    * `block.<field>`, `block_number`, `contract`, `tx_hash`, `tx_index`,
      `log_index`, `chain_id`
  """

  @type t :: map()

  @roots ~w(kind event value_usd protocol token price label attestations block block_number
            contract tx_hash tx_index log_index chain_id id)

  @doc "Path roots a rule may reference."
  def roots, do: @roots

  @spec get(t(), String.t() | [String.t()]) :: term()
  def get(record, path) when is_binary(path), do: get(record, String.split(path, "."))

  def get(r, ["kind"]), do: get_in(r, ["event", "kind"])
  def get(r, ["value_usd"]), do: get_in(r, ["enrichment", "value_usd"])
  def get(r, ["protocol"]), do: get_in(r, ["enrichment", "protocol"])
  def get(r, ["token" | rest]), do: dig(get_in(r, ["enrichment", "token"]), rest)
  def get(r, ["price" | rest]), do: dig(get_in(r, ["enrichment", "price"]), rest)
  def get(r, ["attestations"]), do: length(Map.get(r, "attested_by", []))
  def get(r, ["block_number"]), do: get_in(r, ["block", "number"])
  def get(r, ["label", role | rest]), do: dig(label(r, role), rest)
  def get(r, path), do: dig(r, path)

  defp dig(nil, _), do: nil
  defp dig(v, []), do: v
  defp dig(m, [k | rest]) when is_map(m), do: dig(Map.get(m, k), rest)
  defp dig(_, _), do: nil

  @doc "The public label for the address playing `role` in this record, if any."
  def label(record, role) do
    record
    |> get_in(["enrichment", "labels"])
    |> List.wrap()
    |> Enum.find(&(&1["role"] == role))
  end

  def labels(record), do: List.wrap(get_in(record, ["enrichment", "labels"]))

  def block_hash(r), do: get_in(r, ["block", "hash"])
  def block_number(r), do: get_in(r, ["block", "number"])
  def block_timestamp(r), do: get_in(r, ["block", "timestamp"])

  @doc "Compact evidence entry: exact on-chain references behind an alert."
  def evidence(r) do
    %{
      record_id: r["id"],
      chain_id: r["chain_id"],
      block_number: block_number(r),
      block_hash: block_hash(r),
      tx_hash: r["tx_hash"],
      log_index: r["log_index"],
      contract: r["contract"],
      kind: get(r, "kind"),
      event: r["event"],
      value_usd: get(r, "value_usd"),
      labels: Enum.map(labels(r), &Map.take(&1, ["role", "address", "name", "category"])),
      attested_by: Map.get(r, "attested_by", [])
    }
  end
end
