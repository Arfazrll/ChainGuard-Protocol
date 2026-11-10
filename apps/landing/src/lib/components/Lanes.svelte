<script lang="ts">
	import { DOCS } from '#lib/config.ts';
	import { USDC_SERIES } from '#lib/data/recorded.ts';
	import ml from '#lib/data/ml-scores.json';
	import { reveal } from '#lib/motion.ts';

	// --- invariant visual: Chainlink USDC/USD with its 2% band ----------------
	const W = 300;
	const H = 110;
	const P = { l: 34, r: 6, t: 8, b: 16 };
	const lo = 0.87;
	const hi = 1.01;
	const x = (i: number) => P.l + (i / (USDC_SERIES.length - 1)) * (W - P.l - P.r);
	const y = (v: number) => P.t + ((hi - v) / (hi - lo)) * (H - P.t - P.b);
	const line = USDC_SERIES.map((p, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(p.usd).toFixed(1)}`).join('');
	const breachAt = USDC_SERIES.findIndex((p) => p.round === 871);
	const breach = USDC_SERIES[breachAt];
	const low = USDC_SERIES.reduce((m, p) => (p.usd < m.usd ? p : m));

	// --- ML visual: IsolationForest scores of real transactions ----------------
	const MW = 300;
	const MH = 110;
	const maxN = Math.max(...ml.bins.map((b) => b.n));
	const x0 = ml.bins[0].x0;
	const x1 = ml.bins[ml.bins.length - 1].x1;
	const mx = (v: number) => 4 + ((v - x0) / (x1 - x0)) * (MW - 8);
	// sqrt scale: a few hundred ordinary txs and one outlier must both be visible.
	const my = (n: number) => (n ? Math.max(1.5, Math.sqrt(n / maxN) * (MH - 30)) : 0);
</script>

<section id="lanes" aria-labelledby="lanes-title">
	<div class="bloom bloom--violet l1" aria-hidden="true"></div>
	<div class="wrap" use:reveal>
		<p class="eyebrow" data-reveal>Detection</p>
		<h2 id="lanes-title" data-reveal>Three lanes, so one blind spot is not fatal.</h2>
		<p class="lede" data-reveal>
			Each lane runs in its own supervised processes on the BEAM: a crashing rule or monitor restarts alone and
			detection keeps going. All three replay real incidents in CI.
		</p>

		<div class="cards">
			<article class="card glass" data-reveal data-reveal-index="2">
				<span class="lane mono">lane 1</span>
				<h3>Rules for known attacks</h3>
				<p>Community-writable YAML, validated at load. Flash-loan drains, privileged changes, pauses, approval farming, mixers.</p>
				<pre class="code" aria-label="Excerpt of the flash-loan-drain rule"><code><span class="k">scope:</span> tx
<span class="k">require:</span>
  - <span class="k">name:</span> loan
    <span class="k">match:</span> {'{'} kind: flash_loan {'}'}
  - <span class="k">name:</span> drain
    <span class="k">net_outflow:</span>
      <span class="k">party_category:</span> [lending, dex]
      <span class="k">gte_usd:</span> <span class="v">1000000</span></code></pre>
				<a href={DOCS.rules}>Write a rule <span aria-hidden="true">→</span></a>
			</article>

			<article class="card glass" data-reveal data-reveal-index="3">
				<span class="lane mono">lane 2</span>
				<h3>Invariants per protocol</h3>
				<p>Properties that must always hold: a stablecoin's peg, an oracle's freshness and jump size, a protocol's net outflow.</p>
				<figure class="viz">
					<svg viewBox="0 0 {W} {H}" role="img" aria-label="Chainlink USDC/USD, March 2023: from $1.00 to a low of ${low.usd.toFixed(4)}; the invariant fired at round 871, ${breach.usd.toFixed(4)}.">
						<rect class="band" x={P.l} y={y(1.01)} width={W - P.l - P.r} height={y(0.98) - y(1.01)} />
						<line class="grid" x1={P.l} x2={W - P.r} y1={y(0.98)} y2={y(0.98)} />
						<text class="tick" x={P.l - 4} y={y(1) + 3} text-anchor="end">$1.00</text>
						<text class="tick" x={P.l - 4} y={y(0.98) + 3} text-anchor="end">0.98</text>
						<text class="tick" x={P.l - 4} y={y(0.9) + 3} text-anchor="end">0.90</text>
						<path class="series" d={line} />
						<line class="mark" x1={x(breachAt)} x2={x(breachAt)} y1={P.t} y2={H - P.b} />
						<circle class="hit" cx={x(breachAt)} cy={y(breach.usd)} r="4" />
						<text class="ann" x={x(breachAt) + 6} y={P.t + 8}>◆ high, block {breach.block.toLocaleString('en-US')}</text>
					</svg>
					<figcaption>Chainlink USDC/USD rounds 856–984, 11 Mar 2023. Shaded: the 2% band.</figcaption>
				</figure>
				<a href={DOCS.invariants}>Add an invariant <span aria-hidden="true">→</span></a>
			</article>

			<article class="card glass" data-reveal data-reveal-index="4">
				<span class="lane mono">lane 3</span>
				<h3>ML for the unknown</h3>
				<p>
					A Python service learns each protocol's normal flows and the shape of normal fund-flow graphs. It
					unlearns reorged blocks and is capped at medium severity: a signal, never a page.
				</p>
				<figure class="viz">
					<svg viewBox="0 0 {MW} {MH}" role="img" aria-label="Anomaly scores of {ml.txs_scored.toLocaleString('en-US')} real transactions; the Euler exploit scores {ml.highlight.score.toFixed(2)}, beyond the threshold {ml.threshold.toFixed(2)}.">
						{#each ml.bins as b (b.x0)}
							{#if b.n}
								<rect class="bar" x={mx(b.x0) + 1} y={MH - 18 - my(b.n)} width={Math.max(1, mx(b.x1) - mx(b.x0) - 2)} height={my(b.n)} rx="1.5" />
							{/if}
						{/each}
						<line class="axis" x1="4" x2={MW - 4} y1={MH - 18} y2={MH - 18} />
						<line class="thr" x1={mx(ml.threshold)} x2={mx(ml.threshold)} y1="6" y2={MH - 18} />
						<text class="tick" x={mx(ml.threshold) - 4} y="14" text-anchor="end">threshold</text>
						<circle class="hit" cx={mx(ml.highlight.score)} cy={MH - 24} r="4" />
						<text class="ann" x={mx(ml.highlight.score)} y={MH - 32} text-anchor="end">{ml.highlight.label}</text>
						<text class="tick" x="4" y={MH - 4}>normal</text>
						<text class="tick" x={MW - 4} y={MH - 4} text-anchor="end">anomalous</text>
					</svg>
					<figcaption>
						{ml.txs_scored.toLocaleString('en-US')} real txs from {ml.blocks} blocks before the Euler exploit, then the exploit
						block. Flagged: {ml.flagged_baseline} baseline tx{ml.flagged_baseline === 1 ? '' : 's'} and the exploit.
					</figcaption>
				</figure>
				<a href={DOCS.ml}>Read the model <span aria-hidden="true">→</span></a>
			</article>
		</div>
	</div>
</section>

<style>
	#lanes {
		overflow: hidden;
	}
	.l1 {
		width: 700px;
		height: 500px;
		left: -200px;
		bottom: -100px;
		opacity: 0.35;
	}
	.cards {
		display: grid;
		grid-template-columns: repeat(3, minmax(0, 1fr));
		gap: 14px;
		margin-top: 48px;
	}
	.card {
		display: flex;
		flex-direction: column;
		padding: 24px;
		transition:
			border-color 0.25s,
			box-shadow 0.25s,
			transform 0.25s var(--ease);
	}
	.card:hover {
		border-color: color-mix(in oklab, var(--brand) 45%, transparent);
		box-shadow: 0 20px 60px -30px var(--brand-glow);
		transform: translateY(-2px);
	}
	.lane {
		color: var(--brand-ink);
		font-size: 12px;
	}
	h3 {
		font-size: 24px;
		letter-spacing: -0.025em;
		margin: 10px 0 8px;
	}
	.card > p {
		margin: 0 0 18px;
		color: var(--ink-2);
		font-size: 14.5px;
	}
	.card > a {
		margin-top: auto;
		padding-top: 16px;
		color: var(--brand-ink);
		text-decoration: none;
		font-weight: 600;
		font-size: 14px;
	}
	.code {
		margin: 0;
		padding: 14px 16px;
		border-radius: var(--radius-sm);
		background: var(--bg-deep);
		border: 1px solid var(--hairline);
		font: 12.5px/1.6 var(--font-mono);
		color: var(--ink-2);
		overflow-x: auto;
	}
	.k {
		color: var(--brand-ink);
	}
	.v {
		color: var(--live);
	}
	.viz {
		margin: 0;
	}
	svg {
		display: block;
		width: 100%;
		height: auto;
		overflow: visible;
	}
	.band {
		fill: var(--live-wash);
	}
	.grid {
		stroke: var(--grid);
		stroke-dasharray: 3 3;
	}
	.axis {
		stroke: var(--axis);
	}
	.series {
		fill: none;
		stroke: var(--brand);
		stroke-width: 2;
		stroke-linejoin: round;
	}
	.bar {
		fill: var(--brand);
	}
	.mark,
	.thr {
		stroke: var(--ink-3);
		stroke-dasharray: 2 3;
	}
	.hit {
		fill: var(--sev-critical);
		stroke: var(--surface-1);
		stroke-width: 2;
	}
	.tick {
		fill: var(--ink-3);
		font: 9.5px var(--font-ui);
	}
	.ann {
		fill: var(--ink-1);
		font: 600 10px var(--font-ui);
	}
	figcaption {
		margin-top: 8px;
		color: var(--ink-3);
		font-size: 12px;
	}
	@media (max-width: 960px) {
		.cards {
			grid-template-columns: minmax(0, 1fr);
		}
	}
</style>
