// Pure state transitions for the live views. No Angular, no I/O: unit-tested.
import { Alert, BlockStatus, BlockSummary, FlowEdge, NodeLabel, Severity } from './models';

export const MAX_ALERTS = 200;
export const MAX_BLOCKS = 40;

export const SEVERITY_ORDER: Severity[] = ['critical', 'high', 'medium', 'low', 'info'];

/** Insert or replace an alert by id, newest first. */
export function upsertAlert(alerts: readonly Alert[], next: Alert): Alert[] {
  const rest = alerts.filter((a) => a.id !== next.id);
  return [next, ...rest].slice(0, MAX_ALERTS);
}

/** A new block arrives; drop any stale entry with the same hash. */
export function pushBlock(blocks: readonly BlockSummary[], next: BlockSummary): BlockSummary[] {
  const rest = blocks.filter((b) => b.hash !== next.hash);
  return [next, ...rest].sort((a, b) => b.number - a.number).slice(0, MAX_BLOCKS);
}

export function setBlockStatus(blocks: readonly BlockSummary[], hash: string, status: BlockStatus): BlockSummary[] {
  return blocks.map((b) => (b.hash === hash ? { ...b, status } : b));
}

/** Counts of open (non-retracted) alerts per severity. */
export function openBySeverity(alerts: readonly Alert[]): Record<Severity, number> {
  const out: Record<Severity, number> = { critical: 0, high: 0, medium: 0, low: 0, info: 0 };
  for (const a of alerts) if (a.status !== 'retracted') out[a.severity]++;
  return out;
}

export interface AlertFilter {
  severities: ReadonlySet<Severity>;
  showRetracted: boolean;
}

export function filterAlerts(alerts: readonly Alert[], f: AlertFilter): Alert[] {
  return alerts.filter((a) => f.severities.has(a.severity) && (f.showRetracted || a.status !== 'retracted'));
}

// --- fund-flow graph ---------------------------------------------------------

export const FLOW_BLOCKS = 12;
export const MAX_GRAPH_EDGES = 60;

export interface FlowBlock {
  hash: string;
  number: number;
  edges: FlowEdge[];
}

/** Keep the last FLOW_BLOCKS blocks of edges, newest first. */
export function pushFlowBlock(win: readonly FlowBlock[], b: FlowBlock): FlowBlock[] {
  return [b, ...win.filter((x) => x.hash !== b.hash)].sort((x, y) => y.number - x.number).slice(0, FLOW_BLOCKS);
}

/** A reorg orphaned this block: its flows never happened on the canonical chain. */
export function dropFlowBlock(win: readonly FlowBlock[], hash: string): FlowBlock[] {
  return win.filter((x) => x.hash !== hash);
}

export interface GraphNode {
  id: string;
  name: string;
  category: string;
  labeled: boolean;
  inUsd: number;
  outUsd: number;
  alerted: boolean;
}

export interface GraphEdge {
  id: string;
  source: string;
  target: string;
  usd: number;
  transfers: number;
  tokens: string[];
  txs: string[];
  latest: number;
  alerted: boolean;
}

export const shortAddr = (a: string) => (a.length > 14 ? `${a.slice(0, 6)}…${a.slice(-4)}` : a);

/**
 * Aggregate the window into one graph: the largest MAX_GRAPH_EDGES edges by
 * USD, plus every edge touching an address or tx in an open alert, so the
 * paths that matter are never cut.
 */
export function buildGraph(
  win: readonly FlowBlock[],
  alerts: readonly Alert[],
): { nodes: GraphNode[]; edges: GraphEdge[] } {
  const open = alerts.filter((a) => a.status !== 'retracted');
  const hotTx = new Set(open.flatMap((a) => a.tx_hashes.map((t) => t?.toLowerCase())));
  const hotAddr = new Set(
    open.flatMap((a) => a.evidence.flatMap((e) => [e.event['from'], e.event['to']].filter((x): x is string => typeof x === 'string'))).map((x) => x.toLowerCase()),
  );

  const byPair = new Map<string, GraphEdge>();
  const labels = new Map<string, NodeLabel>();
  for (const b of win) {
    for (const e of b.edges) {
      if (e.from_label) labels.set(e.from, e.from_label);
      if (e.to_label) labels.set(e.to, e.to_label);
      const id = `${e.from}>${e.to}`;
      const g = byPair.get(id) ?? { id, source: e.from, target: e.to, usd: 0, transfers: 0, tokens: [], txs: [], latest: 0, alerted: false };
      g.usd += e.usd;
      g.transfers += e.transfers;
      g.tokens = [...new Set([...g.tokens, ...e.tokens])];
      g.txs = [...new Set([...g.txs, ...e.txs])].slice(0, 8);
      g.latest = Math.max(g.latest, b.number);
      g.alerted ||= e.txs.some((t) => hotTx.has(t.toLowerCase()));
      byPair.set(id, g);
    }
  }

  const sorted = [...byPair.values()].sort((a, b) => b.usd - a.usd);
  const keep = sorted.slice(0, MAX_GRAPH_EDGES);
  const kept = new Set(keep.map((e) => e.id));
  for (const e of sorted.slice(MAX_GRAPH_EDGES)) {
    if (e.alerted || hotAddr.has(e.source) || hotAddr.has(e.target)) {
      keep.push(e);
      kept.add(e.id);
    }
  }

  const nodes = new Map<string, GraphNode>();
  const node = (id: string) => {
    let n = nodes.get(id);
    if (!n) {
      const l = labels.get(id);
      n = { id, name: l?.name ?? shortAddr(id), category: l?.category ?? 'unlabeled', labeled: !!l, inUsd: 0, outUsd: 0, alerted: hotAddr.has(id) };
      nodes.set(id, n);
    }
    return n;
  };
  for (const e of keep) {
    node(e.source).outUsd += e.usd;
    node(e.target).inUsd += e.usd;
    if (e.alerted) {
      node(e.source).alerted = true;
      node(e.target).alerted = true;
    }
  }
  return { nodes: [...nodes.values()], edges: keep };
}
