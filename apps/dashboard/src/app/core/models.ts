// Shapes pushed by the ChainGuard engine (apps/engine) over Phoenix Channels
// and returned by its JSON API. Keep in sync with ChainGuard.Alerts.Alert and
// ChainGuard.Chain.Server.

export type Severity = 'info' | 'low' | 'medium' | 'high' | 'critical';
export type AlertStatus = 'provisional' | 'final' | 'retracted';

export interface Label {
  role: string;
  address: string;
  name: string;
  category: string;
}

export interface Evidence {
  record_id: string;
  chain_id: number;
  block_number: number;
  block_hash: string;
  tx_hash: string;
  log_index: number;
  contract: string;
  kind: string;
  event: Record<string, unknown>;
  value_usd: number | null;
  labels: Label[];
  attested_by: string[];
}

export interface Alert {
  id: string;
  rule_id: string;
  rule_version: number;
  title: string;
  severity: Severity;
  requested_severity: Severity;
  weakness: { class: string; refs: string[] };
  chain_id: number;
  block_number: number | null;
  block_hash: string | null;
  tx_hashes: string[];
  evidence: Evidence[];
  sources: string[];
  min_attestations: number;
  status: AlertStatus;
  occurrences: number;
  notes: string[];
  first_seen_ms: number;
  updated_ms: number;
  detect_lag_ms: number | null;
  system: boolean;
  /** Detection lane: rule (YAML), invariant (per protocol), ml (anomaly service), system. */
  lane: Lane;
}

export type Lane = 'rule' | 'invariant' | 'ml' | 'system';

export interface NodeLabel {
  name: string;
  category: string;
  protocol: string | null;
}

/** One aggregated `from -> to` priced-transfer edge of a block. */
export interface FlowEdge {
  from: string;
  to: string;
  usd: number;
  transfers: number;
  tokens: string[];
  txs: string[];
  from_label: NodeLabel | null;
  to_label: NodeLabel | null;
}

export type InvariantState = 'ok' | 'breached' | 'warming_up';

export interface InvariantStatus {
  id: string;
  name: string;
  kind: 'peg' | 'oracle' | 'outflow';
  protocol: string;
  chain_id: number;
  state: InvariantState;
  value: number | null;
  unit: 'usd';
  limit: number;
  deviation?: number | null;
  age_s?: number | null;
  within_blocks?: number;
  feed?: string;
}

export interface MlStatus {
  state: 'ok' | 'degraded' | 'disabled' | 'starting';
  severity_ceiling: Severity;
  blocks_scored: number;
  alerts_raised: number;
  consecutive_failures: number;
  last_error: string | null;
  model: Record<string, unknown> | null;
}

export type BlockStatus = 'provisional' | 'final' | 'orphaned';

export interface BlockSummary {
  number: number;
  hash: string;
  timestamp: number;
  records: number;
  txs: number;
  alerts: string[];
  attested_by: string[];
  ingest_lag_ms: number | null;
  detect_lag_ms: number | null;
  pipeline_ms: number | null;
  eval_ms: number;
  /** Historical block (incident replay / catch-up): excluded from latency. */
  replayed?: boolean;
  status: BlockStatus;
  notable?: Evidence[];
  flows?: FlowEdge[];
}

export interface Percentiles {
  p50: number | null;
  p95: number | null;
  max: number | null;
  samples: number;
}

export interface Stats {
  uptime_s: number;
  counters: {
    blocks: number;
    replayed_blocks: number;
    records: number;
    reorgs: number;
    duplicates: number;
    failed_messages: number;
    alerts: number;
    txs?: number;
    usd_observed?: number;
    ml_blocks?: number;
    ml_skipped?: number;
    ml_errors?: number;
  };
  chains: Record<string, { head: number; hash: string; timestamp: number }>;
  latency_ms: {
    ingest: Percentiles;
    detect: Percentiles;
    pipeline: Percentiles;
    rule_eval: Percentiles;
  };
  clock_skew_suspected: boolean;
  alerts: {
    active: number;
    raised: number;
    merged: number;
    suppressed: number;
    retracted: number;
    finalized: number;
    capped: number;
  };
}

export interface ReorgEvent {
  depth: number;
  common_ancestor: { number: number; hash: string };
  old_tip: { number: number; hash: string };
  new_tip: { number: number; hash: string };
  at_ms: number;
}

export type ConnectionState = 'connecting' | 'live' | 'reconnecting' | 'offline';
