#!/usr/bin/env node
// Turns a real ingestd capture (JSONL) into the landing page's recorded data:
//   node scripts/record.mjs <capture.jsonl> [more.jsonl ...]
// Writes src/lib/data/recorded-run.json. Every figure the page shows when no
// engine is reachable comes from this file, so it is always a real run, with
// its block range and providers stated next to it.
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

const STABLES = new Set(['USDC', 'USDT', 'DAI']);
const files = process.argv.slice(2);
if (!files.length) {
	console.error('usage: node scripts/record.mjs <capture.jsonl> [...]');
	process.exit(2);
}

const blocks = new Map();
const txs = new Set();
const providers = new Set();
let records = 0;
let priced = 0;
let minAttest = Infinity;
const notable = [];

for (const f of files) {
	const rl = readline.createInterface({ input: fs.createReadStream(f), crlfDelay: Infinity });
	for await (const line of rl) {
		if (!line) continue;
		const m = JSON.parse(line);
		if (m.type === 'block_adopted') {
			blocks.set(m.block.number, m.block.timestamp);
			(m.attested_by ?? []).forEach((p) => providers.add(p));
			continue;
		}
		if (m.type !== 'upsert') continue;
		const r = m.record;
		records++;
		txs.add(r.tx_hash);
		minAttest = Math.min(minAttest, (r.attested_by ?? []).length);
		const e = r.enrichment ?? {};
		const v = e.value_usd;
		if (r.event.kind !== 'erc20_transfer' || typeof v !== 'number') continue;
		priced += v;
		if (v < 100_000) continue;
		const labels = (e.labels ?? []).filter((l) => l.role !== 'contract');
		const name = (role) => labels.find((l) => l.role === role)?.name ?? null;
		const cats = labels.map((l) => l.category);
		const symbol = e.token?.symbol ?? null;
		const category = cats.includes('bridge')
			? 'bridges'
			: STABLES.has(symbol)
				? 'stablecoins'
				: cats.some((c) => ['lending', 'dex', 'protocol'].includes(c))
					? 'defi'
					: 'other';
		notable.push({
			block: r.block.number,
			ts: r.block.timestamp,
			tx: r.tx_hash,
			log: r.log_index,
			symbol,
			usd: Math.round(v),
			from: name('from'),
			to: name('to'),
			price_source: e.price?.source ?? null,
			category,
			attested_by: (r.attested_by ?? []).length
		});
	}
}

const nums = [...blocks.keys()].sort((a, b) => a - b);
notable.sort((a, b) => a.block - b.block || a.log - b.log);
const out = {
	source: files.map((f) => path.basename(f)),
	chain: 'Ethereum mainnet',
	first_block: nums[0],
	last_block: nums.at(-1),
	first_ts: blocks.get(nums[0]),
	last_ts: blocks.get(nums.at(-1)),
	blocks: nums.length,
	txs: txs.size,
	records,
	priced_usd: Math.round(priced),
	min_attestations: minAttest === Infinity ? 0 : minAttest,
	providers: [...providers].sort(),
	notable: notable.slice(-80)
};
const dest = new URL('../src/lib/data/recorded-run.json', import.meta.url);
fs.writeFileSync(dest, JSON.stringify(out, null, '\t') + '\n');
console.log(`${out.blocks} blocks #${out.first_block}–#${out.last_block}, ${out.txs} txs, ${out.records} records, $${out.priced_usd.toLocaleString('en-US')} priced, ${out.notable.length} notable`);
