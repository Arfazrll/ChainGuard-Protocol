// Pure state transitions for the live views. No Angular, no I/O: unit-tested.
import { Alert, BlockStatus, BlockSummary, Severity } from './models';

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
