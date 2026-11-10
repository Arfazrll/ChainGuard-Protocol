import { describe, expect, it } from 'vitest';
import { niceMax } from './components/records-chart';
import { SEVERITY_META, ago, short, usdCompact } from './core/format';
import { Alert, BlockSummary } from './core/models';
import { filterAlerts, openBySeverity, pushBlock, setBlockStatus, upsertAlert } from './core/state';

const alert = (id: string, over: Partial<Alert> = {}): Alert =>
  ({
    id,
    rule_id: 'flash-loan-drain',
    rule_version: 1,
    title: 't',
    severity: 'critical',
    requested_severity: 'critical',
    weakness: { class: 'flash-loan-attack', refs: [] },
    chain_id: 1,
    block_number: 1,
    block_hash: '0x1',
    tx_hashes: [],
    evidence: [],
    sources: ['a', 'b'],
    min_attestations: 2,
    status: 'provisional',
    occurrences: 1,
    notes: [],
    first_seen_ms: 0,
    updated_ms: 0,
    detect_lag_ms: null,
    system: false,
    ...over,
  }) as Alert;

const block = (n: number, hash = `0x${n}`): BlockSummary =>
  ({
    number: n,
    hash,
    timestamp: 0,
    records: n,
    txs: 1,
    alerts: [],
    attested_by: ['a', 'b'],
    ingest_lag_ms: null,
    detect_lag_ms: null,
    pipeline_ms: null,
    eval_ms: 1,
    status: 'provisional',
  }) as BlockSummary;

describe('alert state', () => {
  it('upserts by id, newest first, so a retraction replaces the original', () => {
    let xs = upsertAlert([], alert('a'));
    xs = upsertAlert(xs, alert('b'));
    xs = upsertAlert(xs, alert('a', { status: 'retracted' }));
    expect(xs.map((x) => [x.id, x.status])).toEqual([
      ['a', 'retracted'],
      ['b', 'provisional'],
    ]);
  });

  it('counts only open alerts per severity', () => {
    const xs = [alert('a'), alert('b', { severity: 'low' }), alert('c', { status: 'retracted' })];
    expect(openBySeverity(xs)).toMatchObject({ critical: 1, low: 1 });
  });

  it('filters by severity and retraction', () => {
    const xs = [alert('a'), alert('b', { severity: 'low' }), alert('c', { status: 'retracted' })];
    const f = { severities: new Set(['critical'] as const), showRetracted: false };
    expect(filterAlerts(xs, f).map((a) => a.id)).toEqual(['a']);
  });
});

describe('block state', () => {
  it('keeps blocks newest first and marks orphans', () => {
    let bs = pushBlock([], block(1));
    bs = pushBlock(bs, block(3));
    bs = pushBlock(bs, block(2));
    expect(bs.map((b) => b.number)).toEqual([3, 2, 1]);
    expect(setBlockStatus(bs, '0x2', 'orphaned')[1].status).toBe('orphaned');
  });
});

describe('format', () => {
  it('formats money, hashes and time', () => {
    expect(usdCompact(8_904_507)).toBe('$8.9M');
    expect(short('0x27182842e098f60e3d576794a5bffb0777e025d3')).toBe('0x2718…25d3');
    expect(ago(0, 61_000)).toBe('1m ago');
  });

  it('gives every severity a distinct glyph and a label (never color alone)', () => {
    const glyphs = Object.values(SEVERITY_META).map((m) => m.glyph);
    expect(new Set(glyphs).size).toBe(glyphs.length);
    expect(Object.values(SEVERITY_META).every((m) => m.label.length > 0)).toBe(true);
  });
});

describe('chart scale', () => {
  it('picks 1/2/5 steps with headroom', () => {
    expect(niceMax(827)).toEqual({ top: 1000, step: 500 });
    expect(niceMax(310)).toEqual({ top: 400, step: 100 });
    expect(niceMax(1809)).toEqual({ top: 2000, step: 500 });
    expect(niceMax(0)).toEqual({ top: 1, step: 1 });
  });
});
