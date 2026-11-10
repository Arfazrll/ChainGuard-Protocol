/**
 * The landing page's connection to a ChainGuard engine.
 *
 * If an engine answers (`?engine=` or VITE_ENGINE_URL, default
 * localhost:4000), the stat band and terminal are live over Phoenix
 * Channels. Otherwise they play back a recorded real run and say so. The
 * page never shows a number without saying where it came from.
 */
import { engineUrl } from './config.ts';
import { INCIDENT_ALERTS, RUN, RUN_EVENTS, type Category, type Severity, type TermEvent } from './data/recorded.ts';
import { usdCompact } from './format.ts';

export type Mode = 'checking' | 'live' | 'recorded';

export interface Figures {
	txs: number;
	usd: number;
	alerts: number;
	chains: number;
	blocks: number;
	source: string;
}

interface EngineStats {
	uptime_s: number;
	counters: { blocks: number; records: number; alerts: number; txs?: number; usd_observed?: number };
	chains: Record<string, unknown>;
	/** Alert manager totals: all three lanes, after dedup and rate limits. */
	alerts?: { raised: number };
}

interface FlowEdge {
	from: string;
	to: string;
	usd: number;
	tokens: string[];
	txs: string[];
	from_label: { name: string; category: string } | null;
	to_label: { name: string; category: string } | null;
}

/** A recent fund-flow edge (sent on join) as a terminal line. */
export function edgeEvent(e: FlowEdge, block: number): TermEvent {
	const name = (l: FlowEdge['from_label'], a: string) => l?.name ?? `${a.slice(0, 6)}…${a.slice(-4)}`;
	const labels = [e.from_label, e.to_label].filter((l): l is NonNullable<typeof l> => !!l).map((l) => ({ ...l, role: 'party' }));
	const stable = e.tokens.some((t) => ['USDC', 'USDT', 'DAI'].includes(t));
	const cat = categoryOf(labels);
	return {
		id: `${block}:${e.from}>${e.to}`,
		kind: 'flow',
		category: cat === 'other' && stable ? 'stablecoins' : cat,
		block,
		ts: 0,
		title: `${usdCompact(e.usd)} ${e.tokens.join('/')} · ${name(e.from_label, e.from)} → ${name(e.to_label, e.to)}`,
		detail: `aggregated transfers · ${e.txs.length} tx${e.txs.length === 1 ? '' : 's'}`,
		tx: e.txs[0]
	};
}

interface Evidence {
	tx_hash: string;
	block_number: number;
	log_index: number;
	kind: string;
	value_usd: number | null;
	labels: { role: string; name: string; category: string }[];
}

interface EngineAlert {
	id: string;
	title: string;
	severity: Severity;
	lane?: TermEvent['lane'];
	rule_id: string;
	weakness: { class: string };
	block_number: number | null;
	tx_hashes: string[];
	min_attestations: number;
	evidence: Evidence[];
}

const MAX_EVENTS = 40;
const PLAYBACK_MS = 1700;

/** Parties (from, to, …) decide first; the token contract's own label only if no party is labeled. */
export function categoryOf(labels: { category: string; role?: string }[]): Category {
	const parties = labels.filter((l) => l.role !== 'contract').map((l) => l.category);
	const all = labels.map((l) => l.category);
	if (all.includes('bridge')) return 'bridges';
	if (parties.some((c) => c === 'lending' || c === 'dex' || c === 'protocol')) return 'defi';
	if (all.includes('stablecoin')) return 'stablecoins';
	return 'other';
}

export function alertEvent(a: EngineAlert, now = Date.now()): TermEvent {
	const labels = a.evidence.flatMap((e) => e.labels);
	const cat =
		a.rule_id.endsWith('-peg') || a.weakness.class === 'stablecoin-depeg' ? 'stablecoins' : categoryOf(labels);
	return {
		id: a.id,
		kind: 'alert',
		category: cat,
		block: a.block_number ?? 0,
		ts: Math.round(now / 1000),
		severity: a.severity,
		lane: a.lane,
		title: a.title,
		detail: `${a.rule_id} · ${a.weakness.class} · ${a.min_attestations} node${a.min_attestations === 1 ? '' : 's'} attested`,
		tx: a.tx_hashes[0]
	};
}

export function flowEvent(e: Evidence, ts: number): TermEvent {
	const name = (role: string) => e.labels.find((l) => l.role === role)?.name ?? 'unlabeled';
	const token = e.labels.find((l) => l.role === 'contract')?.name;
	return {
		id: `${e.tx_hash}:${e.log_index}`,
		kind: 'flow',
		category: categoryOf(e.labels),
		block: e.block_number,
		ts,
		title:
			e.kind === 'flash_loan'
				? `Flash loan · ${name('receiver')}`
				: `${usdCompact(e.value_usd ?? 0)}${token ? ` ${token}` : ''} · ${name('from')} → ${name('to')}`,
		detail: e.kind.replace(/_/g, ' '),
		tx: e.tx_hash
	};
}

export const RECORDED_FIGURES: Figures = {
	txs: RUN.txs,
	usd: RUN.priced_usd,
	alerts: INCIDENT_ALERTS.length,
	chains: 1,
	blocks: RUN.blocks,
	source: `Recorded run: blocks #${RUN.first_block.toLocaleString('en-US')}–#${RUN.last_block.toLocaleString('en-US')}, ${RUN.providers.length} providers`
};

class Live {
	mode = $state<Mode>('checking');
	engine = $state('');
	figures = $state<Figures>(RECORDED_FIGURES);
	events = $state<TermEvent[]>([]);
	private stop: (() => void)[] = [];

	async start() {
		this.engine = engineUrl();
		const reachable = await fetch(`${this.engine}/api/health`, { signal: AbortSignal.timeout(1500) })
			.then((r) => r.ok)
			.catch(() => false);
		if (reachable) await this.goLive();
		else this.playRecorded();
	}

	destroy() {
		this.stop.forEach((f) => f());
		this.stop = [];
	}

	private push(e: TermEvent) {
		this.events = [e, ...this.events.filter((x) => x.id !== e.id)].slice(0, MAX_EVENTS);
	}

	private playRecorded() {
		this.mode = 'recorded';
		this.figures = RECORDED_FIGURES;
		// The incident replays first, then the recorded run on a loop.
		const queue = [...RUN_EVENTS, ...INCIDENT_ALERTS];
		this.events = [...INCIDENT_ALERTS].reverse().concat(RUN_EVENTS.slice(-6).reverse());
		let i = 0;
		const t = setInterval(() => {
			this.push(queue[i % queue.length]);
			i++;
		}, PLAYBACK_MS);
		this.stop.push(() => clearInterval(t));
	}

	private async goLive() {
		this.mode = 'live';
		const { Socket } = await import('phoenix');
		const socket = new Socket(this.engine.replace(/^http/, 'ws') + '/socket', {
			reconnectAfterMs: (n: number) => [1000, 2000, 5000][n - 1] ?? 10_000
		});
		socket.connect();
		const alerts = socket.channel('alerts:global');
		const live = socket.channel('live:1');

		alerts.on('alert:raised', (a: EngineAlert) => this.push(alertEvent(a)));
		live.on('block', (b: { number: number; timestamp: number; notable?: Evidence[] }) => {
			for (const e of (b.notable ?? []).slice(0, 3).reverse()) this.push(flowEvent(e, b.timestamp));
		});
		alerts.join().receive('ok', (r: { alerts: EngineAlert[] }) => {
			for (const a of (r.alerts ?? []).slice(0, 12).reverse()) this.push(alertEvent(a));
		});
		live.join().receive('ok', (r: { flows?: { number: number; edges: FlowEdge[] }[] }) => {
			// Seed the terminal with the latest large flows instead of waiting for the next block.
			const seed = (r.flows ?? [])
				.slice(0, 4)
				.reverse()
				.flatMap((b) => b.edges.filter((e) => e.usd >= 100_000).slice(0, 2).map((e) => edgeEvent(e, b.number)));
			for (const e of seed) this.push(e);
		});

		const poll = async () => {
			const s: EngineStats | null = await fetch(`${this.engine}/api/stats`)
				.then((r) => r.json())
				.catch(() => null);
			if (!s) return;
			const hours = Math.max(1, Math.round(s.uptime_s / 3600));
			this.figures = {
				txs: s.counters.txs ?? 0,
				usd: s.counters.usd_observed ?? 0,
				alerts: s.alerts?.raised ?? s.counters.alerts,
				chains: Math.max(1, Object.keys(s.chains).length),
				blocks: s.counters.blocks,
				source:
					s.uptime_s < 3600
						? `Live: this engine, ${s.counters.blocks} blocks since start`
						: `Live: this engine, last ~${hours} h`
			};
		};
		await poll();
		const t = setInterval(poll, 5000);
		this.stop.push(() => clearInterval(t), () => socket.disconnect());
	}
}

export const live = new Live();
