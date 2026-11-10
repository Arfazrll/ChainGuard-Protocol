<script lang="ts">
	import { DOCS, REPO, dashboardUrl } from '#lib/config.ts';
	import { RUN } from '#lib/data/recorded.ts';
	import { live } from '#lib/live.svelte.ts';
	import Mark from './Mark.svelte';

	const footnotes = [
		'Euler Finance: mainnet block 16,817,996, transaction 0xc310…111d, captured with ingestd from publicnode and drpc and replayed through the engine. The net outflow of $8,904,507 matches published post-mortems (about 8.87 million DAI).',
		'USDC depeg: Chainlink USDC/USD rounds 856 to 984, 11 March 2023. Round 871 at block 16,802,135 ($0.97652) is the first answer outside the 2% band; the preceding round 870 ($0.98214) is inside it.',
		'Model evaluation: 200 consecutive mainnet blocks before the exploit (16,817,796 to 16,817,995), about 15,500 transactions, scored online with the shipped thresholds.',
		`Recorded run: Ethereum mainnet blocks ${RUN.first_block.toLocaleString('en-US')} to ${RUN.last_block.toLocaleString('en-US')}, ${RUN.blocks} blocks, every one attested by both providers, 10 November 2026. Priced value is gross: a flash loan counts out and back.`,
		'Latency: one Windows development machine, not a benchmark. Block-time-to-alert could not be measured because the machine’s clock was 117 seconds behind; SvlteChain detected the skew and withheld the figure.',
		'Start-up: scripts/up.sh --replay on the same machine with warm build caches, until every service passed its health check.'
	];

	const cols = [
		{ h: 'Product', links: [['How it works', '#how'], ['Detection lanes', '#lanes'], ['Euler case study', '#case-study'], ['Platform', '#platform'], ['Dashboard', dashboardUrl()]] },
		{ h: 'Solutions', links: [['Exchanges', '#teams'], ['Funds and treasuries', '#teams'], ['Insurers', '#teams'], ['Protocol security teams', '#teams']] },
		{ h: 'Developers', links: [['Quickstart', '#developers'], ['API reference', `${REPO}/blob/main/docs/api.md`], ['Writing rules', DOCS.rules], ['Invariants', DOCS.invariants], ['Architecture decisions', DOCS.adrs]] },
		{ h: 'Project', links: [['GitHub', REPO], ['Issues', DOCS.issues], ['Label dataset', DOCS.labels], ['Incident fixtures', DOCS.incidents], ['Security model', '#security']] }
	];
</script>

<footer>
	<div class="wrap">
		<ol class="notes" aria-label="Footnotes">
			{#each footnotes as f, i (i)}
				<li id="fn-{i + 1}">{f}</li>
			{/each}
		</ol>

		<div class="sitemap">
			<div class="about">
				<a class="brand" href="/"><Mark size={22} /> SvlteChain</a>
				<p>Open-source, read-only risk monitoring for blockchains. It observes and reports; it never holds keys or moves funds.</p>
			</div>
			{#each cols as c (c.h)}
				<nav aria-label={c.h}>
					<h2>{c.h}</h2>
					<ul>
						{#each c.links as [label, href] (label)}<li><a {href}>{label}</a></li>{/each}
					</ul>
				</nav>
			{/each}
		</div>

		<div class="legal">
			<span>Open source under the MIT License.</span>
			<span class="status" class:on={live.mode === 'live'}>
				<span class="dot" aria-hidden="true"></span>
				{live.mode === 'live' ? `Engine reachable at ${live.engine.replace(/^https?:\/\//, '')}` : 'No engine reachable; figures are from a recorded run'}
			</span>
			<span>Detection is advisory and does not replace your own judgement.</span>
		</div>
	</div>
</footer>

<style>
	footer {
		background: var(--paper);
		border-top: 1px solid var(--rule);
		padding: 56px 0 36px;
		font-size: 13px;
		color: var(--graphite);
	}
	.notes {
		margin: 0 0 40px;
		padding: 0 0 32px 18px;
		border-bottom: 1px solid var(--rule);
		display: grid;
		gap: 8px;
		line-height: 1.55;
		max-width: 980px;
	}
	.notes li {
		padding-left: 4px;
	}
	.notes li:target {
		color: var(--ink);
		background: #fff8db;
		border-radius: 4px;
	}
	.sitemap {
		display: grid;
		grid-template-columns: 1.5fr repeat(4, 1fr);
		gap: 32px;
	}
	.brand {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		color: var(--ink);
		font-size: 16px;
		font-weight: 600;
	}
	.brand:hover {
		text-decoration: none;
	}
	.about p {
		margin: 12px 0 0;
		max-width: 34ch;
		font-size: 13.5px;
		line-height: 1.55;
	}
	h2 {
		margin: 4px 0 12px;
		font-size: 13px;
		font-weight: 600;
		letter-spacing: 0;
		color: var(--ink);
	}
	ul {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		gap: 8px;
	}
	nav a {
		color: var(--graphite);
	}
	nav a:hover {
		color: var(--ink);
	}
	.legal {
		display: flex;
		flex-wrap: wrap;
		gap: 10px 28px;
		margin-top: 44px;
		padding-top: 20px;
		border-top: 1px solid var(--rule);
	}
	.status {
		display: inline-flex;
		align-items: center;
		gap: 7px;
	}
	.dot {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: #b8bdc4;
	}
	.status.on .dot {
		background: var(--ok);
	}
	@media (max-width: 900px) {
		.sitemap {
			grid-template-columns: repeat(2, minmax(0, 1fr));
		}
		.about {
			grid-column: 1 / -1;
		}
	}
</style>
