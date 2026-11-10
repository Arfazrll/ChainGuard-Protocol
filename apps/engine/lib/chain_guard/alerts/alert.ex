defmodule ChainGuard.Alerts.Alert do
  @moduledoc """
  An alert: severity, weakness class, the exact on-chain evidence behind it,
  and its lifecycle.

  Status follows the blocks its evidence came from (invariant 3):

    * `:provisional`: some evidence is in a block that could still be reorged
    * `:final`: every evidence block is finalized
    * `:retracted`: a reorg orphaned an evidence block; the alert no longer
      stands and connectors are told so
  """

  @derive {Jason.Encoder,
           only: ~w(id rule_id rule_version title severity requested_severity weakness chain_id
                    block_number block_hash tx_hashes evidence sources min_attestations status
                    occurrences notes dedup_key first_seen_ms updated_ms detect_lag_ms system)a}
  defstruct [
    :id,
    :rule_id,
    :rule_version,
    :title,
    :severity,
    :requested_severity,
    :weakness,
    :chain_id,
    :block_number,
    :block_hash,
    :dedup_key,
    :first_seen_ms,
    :updated_ms,
    :detect_lag_ms,
    tx_hashes: [],
    evidence: [],
    evidence_blocks: MapSet.new(),
    sources: [],
    min_attestations: 0,
    status: :provisional,
    occurrences: 1,
    notes: [],
    system: false
  ]

  @type t :: %__MODULE__{}
end
