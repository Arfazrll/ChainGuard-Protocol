import { describe, expect, it } from 'vitest';
import { INCIDENT_ALERTS, RUN, RUN_EVENTS, USDC_SERIES } from './data/recorded.ts';
import { short, usdCompact } from './format.ts';
import { RECORDED_FIGURES, alertEvent, categoryOf, flowEvent } from './live.svelte.ts';

describe('format', () => {
	it('compacts dollars and hashes', () => {
		expect(usdCompact(8_904_507)).toBe('$8.9M');
		expect(usdCompact(38_904_507)).toBe('$39M');
		expect(usdCompact(412_000)).toBe('$412K');
		expect(short('0xc310a0affe2169d1f6feec1c63dbc7f7c62a887fa48795d327d4d2da2d6b111d')).toBe('0xc310…111d');
	});
});

describe('terminal events', () => {
	it('categorises by labels, bridges first', () => {
		expect(categoryOf([{ category: 'dex' }, { category: 'bridge' }])).toBe('bridges');
		expect(categoryOf([{ category: 'stablecoin' }])).toBe('stablecoins');
		expect(categoryOf([{ category: 'lending' }])).toBe('defi');
		expect(categoryOf([{ category: 'exchange' }])).toBe('other');
		// A DeFi party outranks the token contract's stablecoin label.
		expect(categoryOf([{ category: 'stablecoin', role: 'contract' }, { category: 'lending', role: 'from' }])).toBe('defi');
	});

	it('maps an engine alert, keeping lane, severity and evidence count', () => {
		const e = alertEvent({
			id: 'a1',
			title: 'USDC/USD at $0.9765: 2.35% off its $1.0000 peg (band 2.00%)',
			severity: 'high',
			lane: 'invariant',
			rule_id: 'usdc-peg',
			weakness: { class: 'stablecoin-depeg' },
			block_number: 16802135,
			tx_hashes: ['0xabc'],
			min_attestations: 2,
			evidence: []
		});
		expect(e).toMatchObject({ kind: 'alert', category: 'stablecoins', severity: 'high', lane: 'invariant', tx: '0xabc' });
		expect(e.detail).toBe('usdc-peg · stablecoin-depeg · 2 nodes attested');
	});

	it('maps a notable flow from a live block', () => {
		const e = flowEvent(
			{
				tx_hash: '0xt',
				block_number: 1,
				log_index: 3,
				kind: 'erc20_transfer',
				value_usd: 2_650_000,
				labels: [
					{ role: 'contract', name: 'Tether USD', category: 'stablecoin' },
					{ role: 'from', name: 'Binance 14', category: 'exchange' }
				]
			},
			100
		);
		expect(e).toMatchObject({ id: '0xt:3', category: 'stablecoins', title: '$2.6M Tether USD · Binance 14 → unlabeled' });
	});
});

describe('recorded data is real and self-consistent', () => {
	it('every recorded figure comes from the captured run', () => {
		expect(RECORDED_FIGURES.txs).toBe(RUN.txs);
		expect(RECORDED_FIGURES.usd).toBe(RUN.priced_usd);
		expect(RUN.min_attestations).toBeGreaterThanOrEqual(2);
		expect(RUN_EVENTS.length).toBe(RUN.notable.length);
		expect(RUN_EVENTS.every((e) => e.block >= RUN.first_block && e.block <= RUN.last_block)).toBe(true);
	});

	it('the USDC series is contiguous and matches the two-provider fixture at the breach', () => {
		USDC_SERIES.forEach((p, i) => i && expect(p.round).toBe(USDC_SERIES[i - 1].round + 1));
		expect(USDC_SERIES.find((p) => p.round === 870)).toEqual({ round: 870, block: 16802107, usd: 0.98214399 });
		expect(USDC_SERIES.find((p) => p.round === 871)).toEqual({ round: 871, block: 16802135, usd: 0.97651903 });
	});

	it('incident alerts are labelled as replays', () => {
		expect(INCIDENT_ALERTS.every((a) => a.replay && a.kind === 'alert')).toBe(true);
	});
});
