-- ChainGuard ingestion schema: Redpanda topic → ClickHouse.
--
-- ingestd publishes one JSON StreamMessage per Kafka record (see
-- crates/ingest-core/src/record.rs). Every message has a per-chain, strictly
-- increasing `seq`. Records are materialized with "highest seq wins":
--   upsert  → is_deleted = 0
--   retract → is_deleted = 1 (a reorg orphaned the record's block)
-- ReplacingMergeTree(seq, is_deleted) gives exactly that, and it is
-- idempotent under at-least-once redelivery.
--
-- STATUS: written for ClickHouse 24.8 LTS; not yet exercised end to end
-- (the dev machine this was written on had no Docker). The same semantics
-- are covered by the ReplacingTable model in the reorg test-suite.

CREATE DATABASE IF NOT EXISTS chainguard;

-- Raw consumer: one row per Kafka message, parsed by the views below.
CREATE TABLE IF NOT EXISTS chainguard.ingest_queue
(
    raw String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'redpanda:9092',
    kafka_topic_list = 'chainguard.ingest.v1.ethereum-mainnet',
    kafka_group_name = 'clickhouse-ingest',
    kafka_format = 'JSONAsString',
    kafka_num_consumers = 1;

-- Decoded, enriched on-chain events. Query through records_live.
CREATE TABLE IF NOT EXISTS chainguard.records
(
    id            String,
    chain_id      UInt64,
    seq           UInt64,
    is_deleted    UInt8,
    block_number  UInt64,
    block_hash    String,
    block_time    DateTime('UTC'),
    tx_hash       String,
    tx_index      UInt32,
    log_index     UInt32,
    contract      String,
    kind          LowCardinality(String),
    event         String,                       -- decoded event JSON (amounts as decimal strings)
    protocol      LowCardinality(Nullable(String)),
    token_symbol  LowCardinality(Nullable(String)),
    value_usd     Nullable(Float64),
    price_source  LowCardinality(Nullable(String)),
    labels        String,                       -- JSON array of role labels
    attested_by   Array(LowCardinality(String)),
    topics        Array(String),
    data          String,
    observed_at   DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(seq, is_deleted)
PARTITION BY toYYYYMM(block_time)
-- block_number is determined by id (id includes the block hash), so keeping
-- it in the key is safe for deduplication and makes range scans cheap.
ORDER BY (chain_id, block_number, id);

CREATE MATERIALIZED VIEW IF NOT EXISTS chainguard.records_mv TO chainguard.records AS
SELECT
    JSONExtractString(raw, 'record', 'id')                                  AS id,
    JSONExtractUInt(raw, 'chain_id')                                        AS chain_id,
    JSONExtractUInt(raw, 'seq')                                             AS seq,
    toUInt8(JSONExtractBool(raw, 'deleted'))                                AS is_deleted,
    JSONExtractUInt(raw, 'record', 'block', 'number')                       AS block_number,
    JSONExtractString(raw, 'record', 'block', 'hash')                       AS block_hash,
    toDateTime(JSONExtractUInt(raw, 'record', 'block', 'timestamp'), 'UTC') AS block_time,
    JSONExtractString(raw, 'record', 'tx_hash')                             AS tx_hash,
    JSONExtractUInt(raw, 'record', 'tx_index')                              AS tx_index,
    JSONExtractUInt(raw, 'record', 'log_index')                             AS log_index,
    JSONExtractString(raw, 'record', 'contract')                            AS contract,
    JSONExtractString(raw, 'record', 'event', 'kind')                       AS kind,
    JSONExtractRaw(raw, 'record', 'event')                                  AS event,
    JSONExtract(raw, 'record', 'enrichment', 'protocol', 'Nullable(String)')           AS protocol,
    JSONExtract(raw, 'record', 'enrichment', 'token', 'symbol', 'Nullable(String)')    AS token_symbol,
    JSONExtract(raw, 'record', 'enrichment', 'value_usd', 'Nullable(Float64)')         AS value_usd,
    JSONExtract(raw, 'record', 'enrichment', 'price', 'source', 'Nullable(String)')    AS price_source,
    JSONExtractRaw(raw, 'record', 'enrichment', 'labels')                   AS labels,
    JSONExtract(raw, 'record', 'attested_by', 'Array(String)')              AS attested_by,
    JSONExtract(raw, 'record', 'topics', 'Array(String)')                   AS topics,
    JSONExtractString(raw, 'record', 'data')                                AS data,
    fromUnixTimestamp64Milli(toInt64(JSONExtractUInt(raw, 'record', 'observed_at_ms')), 'UTC') AS observed_at
FROM chainguard.ingest_queue
WHERE JSONExtractString(raw, 'type') IN ('upsert', 'retract');

-- Block lifecycle: provisional → (orphaned | finalized). Highest seq wins.
CREATE TABLE IF NOT EXISTS chainguard.blocks
(
    chain_id     UInt64,
    number       UInt64,
    hash         String,
    parent_hash  String,
    block_time   DateTime('UTC'),
    status       Enum8('provisional' = 1, 'orphaned' = 2, 'finalized' = 3),
    seq          UInt64
)
ENGINE = ReplacingMergeTree(seq)
ORDER BY (chain_id, number, hash);

CREATE MATERIALIZED VIEW IF NOT EXISTS chainguard.blocks_mv TO chainguard.blocks AS
SELECT
    JSONExtractUInt(raw, 'chain_id')                                   AS chain_id,
    JSONExtractUInt(raw, 'block', 'number')                            AS number,
    JSONExtractString(raw, 'block', 'hash')                            AS hash,
    JSONExtractString(raw, 'block', 'parent_hash')                     AS parent_hash,
    toDateTime(JSONExtractUInt(raw, 'block', 'timestamp'), 'UTC')      AS block_time,
    multiIf(JSONExtractString(raw, 'type') = 'block_adopted', 'provisional',
            JSONExtractString(raw, 'type') = 'block_orphaned', 'orphaned',
            'finalized')                                               AS status,
    JSONExtractUInt(raw, 'seq')                                        AS seq
FROM chainguard.ingest_queue
WHERE JSONExtractString(raw, 'type') IN ('block_adopted', 'block_orphaned', 'block_finalized');

-- Reorgs and integrity halts, append-only: the ingestion audit log.
CREATE TABLE IF NOT EXISTS chainguard.ingest_events
(
    chain_id  UInt64,
    seq       UInt64,
    type      LowCardinality(String),
    raw       String,
    at        DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = MergeTree
ORDER BY (chain_id, seq);

CREATE MATERIALIZED VIEW IF NOT EXISTS chainguard.ingest_events_mv TO chainguard.ingest_events AS
SELECT
    JSONExtractUInt(raw, 'chain_id') AS chain_id,
    JSONExtractUInt(raw, 'seq')      AS seq,
    JSONExtractString(raw, 'type')   AS type,
    raw
FROM chainguard.ingest_queue
WHERE JSONExtractString(raw, 'type') IN ('reorg', 'integrity_halt');

-- What downstream should query: current canonical records only.
CREATE VIEW IF NOT EXISTS chainguard.records_live AS
SELECT * FROM chainguard.records FINAL WHERE is_deleted = 0;
