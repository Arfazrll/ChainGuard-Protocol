/**
 * Real, recorded data for when no engine is reachable. Nothing here is
 * invented: incident alerts are the exact titles the engine raises when the
 * fixtures in apps/engine/test/fixtures/incidents are replayed through it
 * (see the replay tests), and the run figures come from an ingestd capture
 * via scripts/record.mjs.
 */
import run from './recorded-run.json';
import usdcSeries from './usdc-usd-2023-03.json';

export type Severity = 'critical' | 'high' | 'medium' | 'low' | 'info';
export type Tab = 'all' | 'defi' | 'bridges' | 'stablecoins';
export type Category = Exclude<Tab, 'all'> | 'other';

export interface TermEvent {
	id: string;
	kind: 'alert' | 'flow';
	category: Category;
	block: number;
	ts: number;
	severity?: Severity;
	lane?: 'rule' | 'invariant' | 'ml' | 'system';
	title: string;
	detail: string;
	tx?: string;
	replay?: string;
}

export const RUN = run;

const EULER_TX = '0xc310a0affe2169d1f6feec1c63dbc7f7c62a887fa48795d327d4d2da2d6b111d';
const EULER_BLOCK = 16_817_996;
const EULER_TS = 1_678_697_459;

/** Alerts the engine raises on the bundled incident replays. */
export const INCIDENT_ALERTS: TermEvent[] = [
	{
		id: 'euler-rule',
		kind: 'alert',
		category: 'defi',
		block: EULER_BLOCK,
		ts: EULER_TS,
		severity: 'critical',
		lane: 'rule',
		title: 'Euler Finance (main proxy) net outflow $8,904,507 in flash-loan tx 0xc310…111d',
		detail: 'flash-loan-drain · flash-loan-attack · 2 nodes attested',
		tx: EULER_TX,
		replay: 'Euler Finance, 13 Mar 2023'
	},
	{
		id: 'euler-invariant',
		kind: 'alert',
		category: 'defi',
		block: EULER_BLOCK,
		ts: EULER_TS,
		severity: 'critical',
		lane: 'invariant',
		title: 'Euler Finance (main proxy) net outflow $8,904,507 within 50 blocks; limit $5,000,000',
		detail: 'euler-outflow · abnormal-tvl-drawdown · same tx, independent lane',
		tx: EULER_TX,
		replay: 'Euler Finance, 13 Mar 2023'
	},
	{
		id: 'usdc-peg',
		kind: 'alert',
		category: 'stablecoins',
		block: 16_802_135,
		ts: 1_678_504_823,
		severity: 'high',
		lane: 'invariant',
		title: 'USDC/USD at $0.9765: 2.35% off its $1.0000 peg (band 2.00%)',
		detail: 'usdc-peg · stablecoin-depeg · Chainlink round 871 · 2 nodes attested',
		tx: '0xb0c3c027e50937dbfed295d4b369b1ff1ad821c117d83090d89419c51e9fcd3a',
		replay: 'USDC depeg, 11 Mar 2023'
	}
];

/** The Euler exploit transaction's priced flows, from the fixture (log index order). */
export const EULER_FLOW = {
	tx: EULER_TX,
	block: EULER_BLOCK,
	nodes: [
		{ id: 'aave', name: 'Aave V2 aDAI', kind: 'lending' },
		{ id: 'exploit', name: 'Exploit contract 0xebc2…bf99', kind: 'unlabeled' },
		{ id: 'violator', name: 'Violator 0x583c…6c72', kind: 'unlabeled' },
		{ id: 'euler', name: 'Euler Finance', kind: 'lending' },
		{ id: 'liquidator', name: 'Liquidator 0xa0b3…f12b', kind: 'unlabeled' }
	],
	edges: [
		{ from: 'aave', to: 'exploit', usd: 30_000_000, note: 'flash loan' },
		{ from: 'exploit', to: 'violator', usd: 30_000_000 },
		{ from: 'violator', to: 'euler', usd: 30_000_000, note: 'deposit 20M + 10M' },
		{ from: 'euler', to: 'liquidator', usd: 38_904_507, note: 'withdrawn after self-liquidation' },
		{ from: 'liquidator', to: 'exploit', usd: 38_904_507 },
		{ from: 'exploit', to: 'aave', usd: 30_027_000, note: 'repay + fee' }
	]
};

/** Chainlink USDC/USD answers, rounds 856–984 (aggregator 0x7891…a26c), March 2023. */
export const USDC_SERIES: { round: number; block: number; usd: number }[] = usdcSeries;

function flowTitle(n: (typeof run.notable)[number]): string {
	const amount = `$${n.usd.toLocaleString('en-US')} ${n.symbol ?? ''}`.trim();
	const from = n.from ?? 'unlabeled';
	const to = n.to ?? 'unlabeled';
	return `${amount} · ${from} → ${to}`;
}

/** The recorded run as terminal events, oldest first. */
export const RUN_EVENTS: TermEvent[] = run.notable.map((n) => ({
	id: `${n.tx}:${n.log}`,
	kind: 'flow',
	category: n.category as Category,
	block: n.block,
	ts: n.ts,
	title: flowTitle(n),
	detail: `${n.attested_by} nodes · ${n.price_source?.startsWith('oracle') ? 'Chainlink price' : n.price_source === 'peg_assumption' ? '$1 peg price' : 'priced'}`,
	tx: n.tx
}));
