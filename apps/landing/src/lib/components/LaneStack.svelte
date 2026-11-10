<script lang="ts">
	import { onMount } from 'svelte';
	import { DOCS } from '#lib/config.ts';
	import { USDC_SERIES } from '#lib/data/recorded.ts';
	import ml from '#lib/data/ml-scores.json';
	import { reducedMotion, reveal } from '#lib/motion.ts';

	// Peg chart geometry (Chainlink USDC/USD, rounds 856 to 984).
	const W = 520;
	const H = 220;
	const P = { l: 44, r: 12, t: 14, b: 26 };
	const lo = 0.87;
	const hi = 1.01;
	const x = (i: number) => P.l + (i / (USDC_SERIES.length - 1)) * (W - P.l - P.r);
	const y = (v: number) => P.t + ((hi - v) / (hi - lo)) * (H - P.t - P.b);
	const line = USDC_SERIES.map((p, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(p.usd).toFixed(1)}`).join('');
	const breachAt = USDC_SERIES.findIndex((p) => p.round === 871);
	const breach = USDC_SERIES[breachAt];

	// ML histogram geometry.
	const MW = 520;
	const MH = 220;
	const maxN = Math.max(...ml.bins.map((b) => b.n));
	const x0 = ml.bins[0].x0;
	const x1 = ml.bins[ml.bins.length - 1].x1;
	const mx = (v: number) => 12 + ((v - x0) / (x1 - x0)) * (MW - 24);
	const my = (n: number) => (n ? Math.max(2, Math.sqrt(n / maxN) * (MH - 60)) : 0);

	const rules = [
		{ id: 'flash-loan-drain', sev: 'critical', what: 'A protocol ends a flash-loan transaction with a large net outflow' },
		{ id: 'privileged-change', sev: 'high', what: 'Proxy upgrade, admin change, ownership transfer or role grant' },
		{ id: 'emergency-pause', sev: 'high', what: 'A known protocol pauses itself' },
		{ id: 'approval-farming', sev: 'medium', what: 'Many wallets approve the same new, unknown spender' },
		{ id: 'mixer-interaction', sev: 'low', what: 'Funds move into or out of a labeled mixer' }
	];

	let cards: HTMLElement[] = [];
	let depth = $state([0, 0, 0]);

	onMount(() => {
		if (reducedMotion()) return;
		let raf = 0;
		const measure = () => {
			raf = 0;
			const vh = window.innerHeight;
			// A card sinks back as the next one slides over it.
			depth = cards.map((_, i) => {
				const next = cards[i + 1];
				if (!next) return 0;
				const r = next.getBoundingClientRect();
				const top = cards[i].getBoundingClientRect().top;
				return Math.min(1, Math.max(0, (vh - r.top) / Math.max(1, vh - top)));
			});
		};
		const onScroll = () => {
			if (!raf) raf = requestAnimationFrame(measure);
		};
		measure();
		window.addEventListener('scroll', onScroll, { passive: true });
		window.addEventListener('resize', onScroll);
		return () => {
			cancelAnimationFrame(raf);
			window.removeEventListener('scroll', onScroll);
			window.removeEventListener('resize', onScroll);
		};
	});

	const sevLabel = (s: string) => s[0].toUpperCase() + s.slice(1);
</script>

<section id="lanes" class="section" aria-labelledby="lanes-title">
	<div class="wrap">
		<div class="section-head" use:reveal>
			<h2 id="lanes-title" class="h2" data-reveal>Three ways to catch an attack. <span class="soft">Because no single method sees everything.</span></h2>
			<p class="lead" data-reveal>
				Known attacks leave known shapes. Protocol failures break properties that should always hold. And the next
				exploit may look like nothing seen before. ChainGuard runs a detection lane for each, on every block.
			</p>
		</div>

		<div class="stack">
			<article class="card" bind:this={cards[0]} style="--i:0; --d:{depth[0]}">
				<div class="text">
					<p class="kicker">Lane 1</p>
					<h3 class="h3">Rules for attacks we already understand</h3>
					<p>
						A rule describes the shape of an attack as plain data. The flash-loan drain rule, for example, looks for a
						transaction that takes a flash loan and leaves a labeled protocol with at least $1 million less than it
						started with.
					</p>
					<p>
						Rules are YAML files, validated when the engine starts, so anyone can read, review and contribute one. A
						typo is rejected with the file name, never silently ignored.
					</p>
					<a href={DOCS.rules}>Read the rule format</a>
				</div>
				<div class="art">
					<table class="rules">
						<thead><tr><th>Rule</th><th>Severity</th></tr></thead>
						<tbody>
							{#each rules as r (r.id)}
								<tr>
									<td><span class="mono">{r.id}</span><span class="what">{r.what}</span></td>
									<td><span class="sev sev--{r.sev}">{sevLabel(r.sev)}</span></td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			</article>

			<article class="card" bind:this={cards[1]} style="--i:1; --d:{depth[1]}">
				<div class="text">
					<p class="kicker">Lane 2</p>
					<h3 class="h3">Invariants for each protocol’s health</h3>
					<p>
						Some failures are not attacks: a stablecoin slipping off its peg, an oracle that stops updating, a lending
						market losing funds faster than it ever has. An invariant states what must stay true, and ChainGuard checks
						it on every block.
					</p>
					<p>
						On 11 March 2023, Chainlink’s USDC price left its 2% band at block {breach.block.toLocaleString('en-US')}. ChainGuard raises one high
						alert at that moment, stays quiet while the price stays in that band, and escalates only if it falls past 5%.
					</p>
					<a href={DOCS.invariants}>See the bundled invariants</a>
				</div>
				<figure class="art chart">
					<svg viewBox="0 0 {W} {H}" role="img" aria-label="Chainlink USDC/USD in March 2023, falling from $1.00 to $0.88. The invariant fired at round 871, $0.9765.">
						<rect class="band" x={P.l} y={y(1.01)} width={W - P.l - P.r} height={y(0.98) - y(1.01)} />
						{#each [1, 0.96, 0.92, 0.88] as v (v)}
							<line class="grid" x1={P.l} x2={W - P.r} y1={y(v)} y2={y(v)} />
							<text class="tick" x={P.l - 8} y={y(v) + 4} text-anchor="end">${v.toFixed(2)}</text>
						{/each}
						<path class="series" d={line} />
						<line class="mark" x1={x(breachAt)} x2={x(breachAt)} y1={P.t} y2={H - P.b} />
						<circle class="hit" cx={x(breachAt)} cy={y(breach.usd)} r="5" />
						<text class="ann" x={x(breachAt) + 10} y={y(breach.usd) - 12}>High alert, $0.9765</text>
						<text class="tick" x={P.l} y={H - 6}>Round 856</text>
						<text class="tick" x={W - P.r} y={H - 6} text-anchor="end">Round 984</text>
					</svg>
					<figcaption>Chainlink USDC/USD, 11 March 2023. Shaded: within 2% of $1.<a class="fn" href="#fn-2" aria-label="Footnote 2">2</a></figcaption>
				</figure>
			</article>

			<article class="card" bind:this={cards[2]} style="--i:2; --d:{depth[2]}">
				<div class="text">
					<p class="kicker">Lane 3</p>
					<h3 class="h3">A model for what nobody has seen yet</h3>
					<p>
						A separate service learns what normal looks like: how much each protocol usually moves, and the shape of
						ordinary transactions. It flags a transaction only when it is both rare and far outside normal on a dollar
						measure, and it lists the reasons.
					</p>
					<p>
						Its alerts are capped at medium severity, by design and enforced in the engine. A statistical signal asks a
						person to look; it never pages anyone on its own.
					</p>
					<a href={DOCS.ml}>How the model works</a>
				</div>
				<figure class="art chart">
					<svg viewBox="0 0 {MW} {MH}" role="img" aria-label="Anomaly scores of {ml.txs_scored} real transactions. The Euler exploit scores beyond the threshold.">
						{#each ml.bins as b (b.x0)}
							{#if b.n}<rect class="bar" x={mx(b.x0) + 1} y={MH - 30 - my(b.n)} width={Math.max(2, mx(b.x1) - mx(b.x0) - 3)} height={my(b.n)} rx="2" />{/if}
						{/each}
						<line class="axis" x1="12" x2={MW - 12} y1={MH - 30} y2={MH - 30} />
						<line class="mark" x1={mx(ml.threshold)} x2={mx(ml.threshold)} y1="16" y2={MH - 30} />
						<text class="tick" x={mx(ml.threshold) - 6} y="26" text-anchor="end">Alert threshold</text>
						<circle class="hit" cx={mx(ml.highlight.score)} cy={MH - 40} r="5" />
						<text class="ann" x={mx(ml.highlight.score) - 10} y={MH - 52} text-anchor="end">Euler exploit</text>
						<text class="tick" x="12" y={MH - 10}>Ordinary</text>
						<text class="tick" x={MW - 12} y={MH - 10} text-anchor="end">Anomalous</text>
					</svg>
					<figcaption>
						{ml.txs_scored.toLocaleString('en-US')} real transactions scored after the model’s warm-up, from the 200 blocks before the Euler exploit. Two ordinary ones crossed the threshold.<a class="fn" href="#fn-3" aria-label="Footnote 3">3</a>
					</figcaption>
				</figure>
			</article>
		</div>
	</div>
</section>

<style>
	.stack {
		display: grid;
		gap: 40px;
	}
	.card {
		position: sticky;
		top: calc(var(--nav-h) + 24px + var(--i) * 18px);
		display: grid;
		grid-template-columns: minmax(0, 0.95fr) minmax(0, 1.05fr);
		gap: clamp(28px, 4vw, 64px);
		align-items: center;
		min-height: min(560px, 78vh);
		padding: clamp(28px, 4vw, 56px);
		border-radius: 28px;
		background: var(--white);
		border: 1px solid var(--rule);
		box-shadow: 0 1px 2px rgba(13, 17, 23, 0.04);
		transform-origin: 50% 0%;
		transform: perspective(1600px) translateY(calc(var(--d) * -10px)) scale(calc(1 - var(--d) * 0.05)) rotateX(calc(var(--d) * 4deg));
		filter: brightness(calc(1 - var(--d) * 0.06));
	}
	.kicker {
		margin: 0 0 10px;
		font-size: 14px;
		font-weight: 500;
		color: var(--cobalt);
	}
	.text h3 {
		margin-bottom: 18px;
	}
	.text p {
		margin: 0 0 14px;
		color: var(--ink-2);
		max-width: 52ch;
	}
	.text a {
		display: inline-block;
		margin-top: 6px;
		font-weight: 500;
	}
	.art {
		margin: 0;
	}
	.rules {
		width: 100%;
		border-collapse: collapse;
		font-size: 14.5px;
	}
	.rules th {
		text-align: left;
		font-size: 13px;
		font-weight: 500;
		color: var(--muted);
		padding: 0 0 10px;
		border-bottom: 1px solid var(--rule);
	}
	.rules td {
		padding: 13px 0;
		border-bottom: 1px solid var(--rule-soft);
		vertical-align: top;
	}
	.rules td:last-child {
		text-align: right;
		padding-left: 12px;
	}
	.rules .mono {
		display: block;
		color: var(--ink);
		font-size: 13.5px;
	}
	.what {
		display: block;
		margin-top: 2px;
		color: var(--graphite);
		font-size: 14px;
	}
	.chart svg {
		width: 100%;
		height: auto;
		overflow: visible;
	}
	.band {
		fill: var(--ok-wash);
	}
	.grid {
		stroke: var(--rule-soft);
	}
	.axis {
		stroke: var(--rule);
	}
	.series {
		fill: none;
		stroke: var(--cobalt);
		stroke-width: 2;
		stroke-linejoin: round;
	}
	.bar {
		fill: #9aa9e6;
	}
	.mark {
		stroke: var(--muted);
		stroke-dasharray: 3 4;
	}
	.hit {
		fill: var(--signal);
		stroke: var(--white);
		stroke-width: 2;
	}
	.tick {
		fill: var(--muted);
		font: 12px var(--font);
	}
	.ann {
		fill: var(--ink);
		font: 600 12.5px var(--font);
	}
	figcaption {
		margin-top: 12px;
		font-size: 13.5px;
		color: var(--muted);
	}
	@media (max-width: 600px) {
		.tick {
			font-size: 18px;
		}
		.ann {
			font-size: 19px;
		}
	}
	@media (max-width: 900px) {
		.card {
			position: static;
			grid-template-columns: minmax(0, 1fr);
			transform: none;
			filter: none;
			min-height: 0;
		}
	}
</style>
