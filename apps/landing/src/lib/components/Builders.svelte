<script lang="ts">
	import { DOCS, REPO } from '#lib/config.ts';
	import { reveal } from '#lib/motion.ts';

	const items = [
		{
			t: 'Run a node',
			d: 'Point ingestd at your own RPC or archive node. Two independent sources minimum; ChainGuard refuses to run on one.',
			code: '[[nodes]]\nid = "my-erigon"\nurl_env = "CHAINGUARD_RPC_A"',
			href: DOCS.ingest,
			cta: 'Ingest config'
		},
		{
			t: 'Write a detection rule',
			d: 'Rules are data. Add a YAML file, a positive and a negative test, and ideally a captured real incident.',
			code: 'id: my-rule\nscope: record\nmatch: { kind: paused }',
			href: DOCS.rules,
			cta: 'Rule format'
		},
		{
			t: 'Self-host',
			d: 'One command brings up ingestion, the engine, the ML and report services and the dashboard. --replay shows real incidents without an RPC.',
			code: 'scripts/up.sh --replay\ndocker compose -f deploy/compose/\\\n  docker-compose.yml up',
			href: DOCS.run,
			cta: 'Run it locally'
		},
		{
			t: 'Contribute',
			d: 'Labels for public contracts, incident fixtures captured from two providers, invariants for the protocols you know.',
			code: 'data/labels/ethereum-mainnet.json\napps/engine/test/fixtures/incidents/',
			href: `${REPO}/blob/main/README.md`,
			cta: 'Start here'
		}
	];
</script>

<section id="builders" aria-labelledby="builders-title">
	<div class="wrap" use:reveal>
		<p class="eyebrow" data-reveal>For builders</p>
		<h2 id="builders-title" data-reveal>Open source, all the way down.</h2>
		<p class="lede" data-reveal>MIT licensed. Rust for the hot path, Elixir for real-time orchestration, Python for ML only.</p>
		<div class="grid">
			{#each items as it, i (it.t)}
				<a class="item" href={it.href} data-reveal data-reveal-index={i + 2}>
					<h3>{it.t}</h3>
					<p>{it.d}</p>
					<pre><code>{it.code}</code></pre>
					<span class="cta">{it.cta} <span class="arrow" aria-hidden="true">→</span></span>
				</a>
			{/each}
		</div>
	</div>
</section>

<style>
	.grid {
		display: grid;
		grid-template-columns: repeat(4, minmax(0, 1fr));
		gap: 14px;
		margin-top: 44px;
	}
	.item {
		display: flex;
		flex-direction: column;
		padding: 22px;
		border-radius: var(--radius);
		border: 1px solid var(--hairline);
		background: var(--surface-1);
		text-decoration: none;
		transition:
			border-color 0.25s,
			box-shadow 0.25s,
			transform 0.25s var(--ease);
	}
	.item:hover {
		border-color: color-mix(in oklab, var(--brand) 45%, transparent);
		box-shadow: 0 18px 50px -30px var(--brand-glow);
		transform: translateY(-2px);
	}
	h3 {
		font-size: 21px;
		letter-spacing: -0.02em;
	}
	p {
		margin: 10px 0 16px;
		color: var(--ink-2);
		font-size: 14px;
	}
	pre {
		margin: 0 0 16px;
		padding: 12px 14px;
		border-radius: var(--radius-sm);
		background: var(--bg-deep);
		border: 1px solid var(--hairline);
		font: 12px/1.6 var(--font-mono);
		color: var(--ink-2);
		overflow-x: auto;
	}
	.cta {
		margin-top: auto;
		color: var(--brand-ink);
		font-weight: 600;
		font-size: 14px;
	}
	.arrow {
		display: inline-block;
		transition: transform 0.25s var(--ease);
	}
	.item:hover .arrow {
		transform: translateX(3px);
	}
	@media (max-width: 1000px) {
		.grid {
			grid-template-columns: repeat(2, minmax(0, 1fr));
		}
	}
	@media (max-width: 560px) {
		.grid {
			grid-template-columns: minmax(0, 1fr);
		}
	}
</style>
