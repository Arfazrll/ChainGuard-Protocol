import { Severity } from './models';

const usdFmt = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });
const intFmt = new Intl.NumberFormat('en-US');

export function usd(v: number | null | undefined): string {
  return v == null ? '-' : usdFmt.format(v);
}

/** Compact USD for tight spaces: $8.9M, $412K. */
export function usdCompact(v: number | null | undefined): string {
  if (v == null) return '-';
  const abs = Math.abs(v);
  if (abs >= 1e9) return `$${(v / 1e9).toFixed(1)}B`;
  if (abs >= 1e6) return `$${(v / 1e6).toFixed(1)}M`;
  if (abs >= 1e3) return `$${Math.round(v / 1e3)}K`;
  return usdFmt.format(v);
}

export function int(v: number | null | undefined): string {
  return v == null ? '-' : intFmt.format(v);
}

/** 0x2718…25d3 */
export function short(hex: string | null | undefined, head = 6, tail = 4): string {
  if (!hex) return '-';
  return hex.length > head + tail + 1 ? `${hex.slice(0, head)}…${hex.slice(-tail)}` : hex;
}

export function ms(v: number | null | undefined): string {
  if (v == null) return '-';
  if (Math.abs(v) >= 10_000) return `${(v / 1000).toFixed(0)} s`;
  if (Math.abs(v) >= 1000) return `${(v / 1000).toFixed(1)} s`;
  return `${Math.round(v)} ms`;
}

/** "12s ago" relative to `now` (both ms). */
export function ago(thenMs: number, nowMs: number): string {
  const s = Math.max(0, Math.round((nowMs - thenMs) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  return `${Math.floor(s / 3600)}h ago`;
}

export function kindLabel(kind: string): string {
  return kind.replace(/_/g, ' ');
}

/**
 * Severity is never color alone (dataviz rule): every chip carries a text
 * label and a distinct shape. Amber (medium) and orange (high) measure
 * ΔE 13.6, below the 15 floor, so the shape and label are load-bearing.
 */
export const SEVERITY_META: Record<Severity, { label: string; glyph: string }> = {
  critical: { label: 'Critical', glyph: '◆' },
  high: { label: 'High', glyph: '▲' },
  medium: { label: 'Medium', glyph: '●' },
  low: { label: 'Low', glyph: '○' },
  info: { label: 'Info', glyph: '·' },
};

export function explorerTx(chainId: number, tx: string): string | null {
  return chainId === 1 ? `https://etherscan.io/tx/${tx}` : null;
}

export function explorerAddress(chainId: number, address: string): string | null {
  return chainId === 1 ? `https://etherscan.io/address/${address}` : null;
}
