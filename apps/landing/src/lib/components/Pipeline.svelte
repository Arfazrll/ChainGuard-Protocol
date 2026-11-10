<script lang="ts">
	import { onMount } from 'svelte';
	import { reducedMotion, reveal } from '#lib/motion.ts';

	let animate = $state(false);
	onMount(() => (animate = !reducedMotion()));

	// Layout of the diagram (viewBox 1100 × 380).
	const src = [86, 190, 294];
	const lanes = [
		{ y: 96, title: 'Rules', sub: 'YAML, community-written' },
		{ y: 190, title: 'Invariants', sub: 'peg · oracle · outflow' },
		{ y: 284, title: 'ML anomaly', sub: 'Python service, ≤ medium' }
	];
	const outs = [
		{ y: 96, title: 'Alerts', sub: 'webhook · PagerDuty · Telegram' },
		{ y: 190, title: 'Live dashboard', sub: 'Phoenix Channels' },
		{ y: 284, title: 'Risk-score API', sub: 'milestone 4', soon: true }
	];
	const c = (x1: number, y1: number, x2: number, y2: number) => {
		const m = (x1 + x2) / 2;
		return `M${x1},${y1} C${m},${y1} ${m},${y2} ${x2},${y2}`;
	};
	const raw = src.map((y) => c(170, y, 262, 190));
	const verified = [c(418, 190, 488, 190), ...lanes.map((l) => c(612, 190, 676, l.y))];
	const toOut = [c(830, 96, 892, 96), c(830, 96, 892, 190), c(830, 190, 892, 96), c(830, 284, 892, 96), c(830, 190, 892, 190), c(830, 190, 892, 284)];

	const steps = [
		{
			n: '01',
			t: 'Verify',
			d: 'Every head, header and full log set must be returned identically by a strict majority of independent RPC nodes (at least two). A lagging or lying node is outvoted, not trusted.'
		},
		{
			n: '02',
			t: 'Survive reorgs',
			d: 'Records are provisional until final. When a reorg orphans a block, its records are retracted and canonical ones re-emitted; alerts built on it are retracted too.'
		},
		{
			n: '03',
			t: 'Detect in three lanes',
			d: 'Known attack shapes as rules, per-protocol invariants that must always hold, and an ML lane for what nobody wrote a rule for. Each lane runs in supervised processes.'
		},
		{
			n: '04',
			t: 'Alert with evidence',
			d: 'Severity, weakness class, tx hash, log index, block hash and the nodes that attested it. Deduplicated and rate-limited, because a monitor that cries wolf is worse than none.'
		}
	];
</script>

<section id="how" aria-labelledby="how-title">
	<div class="wrap" use:reveal>
		<p class="eyebrow" data-reveal>How it works</p>
		<h2 id="how-title" data-reveal>From raw node data to an alert you can defend.</h2>

		<figure class="diagram" data-reveal>
			<svg viewBox="0 0 1100 380" role="img" aria-labelledby="pipe-desc">
				<desc id="pipe-desc">
					Three or more RPC nodes feed the Rust ingestor, which reaches quorum, handles reorgs and decodes events.
					Verified records go to Redpanda, then to the Elixir engine's three lanes: rules, invariants and ML. Lanes
					raise alerts and feed the live dashboard; the risk-score API comes in milestone 4.
				</desc>
				{#each raw as d (d)}<path class="wire" {d} />{/each}
				{#each verified as d (d)}<path class="wire wire--ok" {d} />{/each}
				{#each toOut as d (d)}<path class="wire" {d} />{/each}

				{#each src as y, i (y)}
					<g class="node">
						<rect x="20" y={y - 26} width="150" height="52" rx="12" />
						<text x="40" y={y - 3} class="t">RPC node {['A', 'B', 'n'][i]}</text>
						<text x="40" y={y + 15} class="s">{['publicnode', 'drpc', 'your own'][i]}</text>
					</g>
				{/each}

				<g class="node node--key">
					<rect x="262" y="112" width="156" height="156" rx="14" />
					<text x="282" y="146" class="t">ingestd</text>
					<text x="282" y="165" class="s">Rust</text>
					<text x="282" y="200" class="m">quorum ≥ 2</text>
					<text x="282" y="222" class="m">reorg tracker</text>
					<text x="282" y="244" class="m">decode + enrich</text>
				</g>

				<g class="node">
					<rect x="488" y="150" width="124" height="80" rx="12" />
					<text x="506" y="185" class="t">Redpanda</text>
					<text x="506" y="205" class="s">replayable topics</text>
				</g>

				<rect class="engine" x="660" y="40" width="184" height="300" rx="18" />
				<text x="676" y="30" class="s cap">Elixir engine (BEAM, supervised)</text>
				{#each lanes as l (l.title)}
					<g class="node">
						<rect x="676" y={l.y - 30} width="154" height="60" rx="12" />
						<text x="694" y={l.y - 5} class="t">{l.title}</text>
						<text x="694" y={l.y + 15} class="s">{l.sub}</text>
					</g>
				{/each}

				{#each outs as o (o.title)}
					<g class="node" class:soon={o.soon}>
						<rect x="892" y={o.y - 30} width="188" height="60" rx="12" />
						<text x="910" y={o.y - 5} class="t">{o.title}</text>
						<text x="910" y={o.y + 15} class="s">{o.sub}</text>
					</g>
				{/each}

				{#if animate}
					{#each raw as d, i (d)}
						<circle r="3" class="pkt">
							<animateMotion dur="2.4s" begin="{i * 0.6}s" repeatCount="indefinite" path={d} />
						</circle>
					{/each}
					{#each verified as d, i (d)}
						<circle r="3" class="pkt pkt--ok">
							<animateMotion dur="1.8s" begin="{0.9 + i * 0.45}s" repeatCount="indefinite" path={d} />
						</circle>
					{/each}
					{#each toOut.slice(0, 4) as d, i (d)}
						<circle r="3" class="pkt pkt--ok">
							<animateMotion dur="2.2s" begin="{1.6 + i * 0.7}s" repeatCount="indefinite" path={d} />
						</circle>
					{/each}
				{/if}
			</svg>
			<figcaption>
				<span><i class="k" aria-hidden="true"></i>raw node data</span>
				<span><i class="k k--ok" aria-hidden="true"></i>verified by ≥ 2 independent nodes</span>
				<span><i class="k k--soon" aria-hidden="true"></i>planned</span>
			</figcaption>
		</figure>

		<ol class="mobile" data-reveal aria-label="Pipeline">
			<li><strong>2+ RPC nodes</strong> publicnode, drpc, your own</li>
			<li><strong>ingestd (Rust)</strong> quorum ≥ 2 · reorg tracker · decode + enrich</li>
			<li><strong>Redpanda</strong> durable, replayable topics</li>
			<li><strong>Engine (Elixir)</strong> rules · invariants · ML anomaly</li>
			<li><strong>Outputs</strong> alerts · live dashboard · risk API (milestone 4)</li>
		</ol>

		<div class="steps">
			{#each steps as s, i (s.n)}
				<article data-reveal data-reveal-index={i + 2}>
					<span class="num mono">{s.n}</span>
					<h3>{s.t}</h3>
					<p>{s.d}</p>
				</article>
			{/each}
		</div>
	</div>
</section>

<style>
	.diagram {
		margin: 48px 0 0;
		padding: 24px;
		border-radius: var(--radius);
		border: 1px solid var(--hairline);
		background: radial-gradient(80% 120% at 50% 0%, var(--surface-1), var(--bg-deep));
	}
	svg {
		display: block;
		width: 100%;
		height: auto;
	}
	.wire {
		fill: none;
		stroke: var(--axis);
		stroke-width: 1.2;
	}
	.wire--ok {
		stroke: color-mix(in oklab, var(--live) 45%, var(--axis));
	}
	.node rect {
		fill: var(--surface-2);
		stroke: var(--hairline-strong);
	}
	.node--key rect {
		stroke: color-mix(in oklab, var(--brand) 60%, transparent);
		fill: color-mix(in oklab, var(--brand) 8%, var(--surface-2));
	}
	.node.soon rect {
		stroke-dasharray: 4 4;
		fill: transparent;
	}
	.engine {
		fill: color-mix(in oklab, var(--brand) 5%, transparent);
		stroke: var(--hairline);
	}
	.t {
		fill: var(--ink-1);
		font: 600 15px var(--font-ui);
	}
	.s {
		fill: var(--ink-3);
		font: 12px var(--font-ui);
	}
	.cap {
		font: 500 12px var(--font-mono);
	}
	.m {
		fill: var(--ink-2);
		font: 12.5px var(--font-mono);
	}
	.pkt {
		fill: var(--brand);
	}
	.pkt--ok {
		fill: var(--live);
	}
	figcaption {
		display: flex;
		flex-wrap: wrap;
		gap: 6px 20px;
		margin-top: 16px;
		color: var(--ink-3);
		font-size: 12.5px;
	}
	.k {
		display: inline-block;
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--brand);
		margin-right: 7px;
	}
	.k--ok {
		background: var(--live);
	}
	.k--soon {
		background: none;
		border: 1px dashed var(--ink-3);
	}
	.mobile {
		display: none;
		list-style: none;
		margin: 32px 0 0;
		padding: 0 0 0 18px;
		border-left: 1px solid color-mix(in oklab, var(--live) 40%, var(--hairline));
	}
	.mobile li {
		position: relative;
		padding: 0 0 18px;
		color: var(--ink-3);
		font-size: 14px;
	}
	.mobile li::before {
		content: '';
		position: absolute;
		left: -23px;
		top: 7px;
		width: 9px;
		height: 9px;
		border-radius: 50%;
		background: var(--live);
	}
	.mobile strong {
		display: block;
		color: var(--ink-1);
	}
	.steps {
		display: grid;
		grid-template-columns: repeat(4, minmax(0, 1fr));
		gap: 28px;
		margin-top: 56px;
	}
	.num {
		color: var(--brand-ink);
		font-size: 12.5px;
	}
	h3 {
		font-size: 22px;
		margin: 10px 0 8px;
		letter-spacing: -0.02em;
	}
	.steps p {
		margin: 0;
		color: var(--ink-2);
		font-size: 14.5px;
	}
	@media (max-width: 960px) {
		.steps {
			grid-template-columns: repeat(2, minmax(0, 1fr));
		}
	}
	@media (max-width: 760px) {
		.diagram {
			display: none;
		}
		.mobile {
			display: block;
		}
	}
	@media (max-width: 520px) {
		.steps {
			grid-template-columns: minmax(0, 1fr);
		}
	}
</style>
