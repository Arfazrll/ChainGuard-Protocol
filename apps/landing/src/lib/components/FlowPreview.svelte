<script lang="ts">
	import { onMount } from 'svelte';
	import { dashboardUrl } from '#lib/config.ts';
	import { EULER_FLOW } from '#lib/data/recorded.ts';
	import { etherscanTx, short, usdCompact } from '#lib/format.ts';
	import { reducedMotion, reveal } from '#lib/motion.ts';

	const pos: Record<string, { x: number; y: number }> = {
		aave: { x: 96, y: 230 },
		exploit: { x: 330, y: 230 },
		violator: { x: 540, y: 92 },
		euler: { x: 690, y: 230 },
		liquidator: { x: 540, y: 368 }
	};
	// Curvature per edge so the out and back legs between Aave and the exploit don't overlap.
	// Same sign on both legs: the normal flips with direction, so they curve apart.
	const bend = [-46, 0, 0, 0, 0, -46];

	const edges = EULER_FLOW.edges.map((e, i) => {
		const a = pos[e.from];
		const b = pos[e.to];
		const mx = (a.x + b.x) / 2;
		const my = (a.y + b.y) / 2;
		const len = Math.hypot(b.x - a.x, b.y - a.y);
		const nx = -(b.y - a.y) / len;
		const ny = (b.x - a.x) / len;
		const cx = mx + nx * bend[i];
		const cy = my + ny * bend[i];
		// Stop short of the target node so the arrow is visible.
		const t = 1 - 34 / len;
		const ex = (1 - t) * (1 - t) * a.x + 2 * (1 - t) * t * cx + t * t * b.x;
		const ey = (1 - t) * (1 - t) * a.y + 2 * (1 - t) * t * cy + t * t * b.y;
		return {
			...e,
			d: `M${a.x},${a.y} Q${cx},${cy} ${ex},${ey}`,
			lx: 0.25 * a.x + 0.5 * cx + 0.25 * b.x,
			ly: 0.25 * a.y + 0.5 * cy + 0.25 * b.y,
			drain: e.from === 'euler'
		};
	});

	let step = $state(-1);
	let figure: HTMLElement;
	onMount(() => {
		if (reducedMotion()) return;
		let timer: ReturnType<typeof setInterval> | undefined;
		const io = new IntersectionObserver(([e]) => {
			clearInterval(timer);
			if (e.isIntersecting) timer = setInterval(() => (step = (step + 1) % (edges.length + 2)), 900);
		});
		io.observe(figure);
		return () => {
			clearInterval(timer);
			io.disconnect();
		};
	});
</script>

<section class="preview" aria-labelledby="preview-title">
	<div class="bloom bloom--green g1" aria-hidden="true"></div>
	<div class="wrap grid" use:reveal>
		<div class="copy">
			<p class="eyebrow" data-reveal>Live dashboard</p>
			<h2 id="preview-title" data-reveal>Follow the money while it moves.</h2>
			<p class="lede" data-reveal>
				The dashboard draws every priced transfer as a fund-flow graph that updates block by block. Red marks
				the evidence of an open alert. Below: the real Euler exploit transaction, leg by leg.
			</p>
			<dl class="net" data-reveal>
				<div><dt>Euler Finance, net</dt><dd class="mono hot">−$8,904,507</dd></div>
				<div><dt>Aave V2 aDAI, net (its fee)</dt><dd class="mono">+$27,000</dd></div>
			</dl>
			<p class="why" data-reveal>
				A gross "large transfer after a flash loan" rule would fire on every big flash loan, because the
				lender's principal leaves and comes back. Netting per party is what separates the victim from the lender.
			</p>
			<a class="btn" href={dashboardUrl()} data-reveal>Open the dashboard <span class="arrow" aria-hidden="true">→</span></a>
		</div>

		<figure bind:this={figure} class="stage" data-reveal data-reveal-index="2">
			<svg viewBox="0 0 780 460" role="img" aria-labelledby="euler-desc">
				<desc id="euler-desc">
					Euler exploit transaction: Aave V2 aDAI lends 30 million DAI to the exploit contract, which passes it to a
					violator contract that deposits 30 million into Euler. Euler then releases 38.9 million to a liquidator
					contract, which sends it back to the exploit contract; 30.03 million repays Aave.
				</desc>
				<defs>
					<marker id="arr" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
						<path d="M0,0 L10,5 L0,10 z" class="arrow" />
					</marker>
					<marker id="arr-hot" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
						<path d="M0,0 L10,5 L0,10 z" class="arrow arrow--hot" />
					</marker>
				</defs>
				{#each edges as e, i (e.from + e.to + i)}
					<path
						class="edge"
						class:hot={e.drain}
						class:on={step === i}
						class:done={step > i}
						d={e.d}
						marker-end={e.drain ? 'url(#arr-hot)' : 'url(#arr)'}
						stroke-width={1 + Math.log10(e.usd) - 6}
					/>
					<g class="elabel" class:show={step >= i || step === -1}>
						<rect x={e.lx - 40} y={e.ly - 12} width="80" height="22" rx="6" />
						<text x={e.lx} y={e.ly + 4} text-anchor="middle">{usdCompact(e.usd)}</text>
					</g>
				{/each}
				{#each EULER_FLOW.nodes as n (n.id)}
					{@const p = pos[n.id]}
					<g class="node" class:hot={n.id === 'euler'}>
						{#if n.kind === 'lending'}
							<rect x={p.x - 26} y={p.y - 20} width="52" height="40" rx="9" />
						{:else}
							<circle cx={p.x} cy={p.y} r="20" />
						{/if}
						<text x={p.x} y={p.y + 40} text-anchor="middle">{n.name}</text>
					</g>
				{/each}
			</svg>
			<figcaption>
				Tx <a class="mono" href={etherscanTx(EULER_FLOW.tx)} target="_blank" rel="noopener">{short(EULER_FLOW.tx, 10, 6)}</a>
				· block #{EULER_FLOW.block.toLocaleString('en-US')} · replayed from a capture by two independent providers
			</figcaption>
		</figure>
	</div>
</section>

<style>
	.preview {
		overflow: hidden;
	}
	.g1 {
		width: 620px;
		height: 520px;
		left: 30%;
		top: 10%;
	}
	.grid {
		display: grid;
		grid-template-columns: minmax(0, 0.85fr) minmax(0, 1.15fr);
		gap: clamp(32px, 5vw, 64px);
		align-items: center;
	}
	.net {
		display: flex;
		flex-wrap: wrap;
		gap: 16px 32px;
		margin: 28px 0 0;
	}
	dt {
		color: var(--ink-3);
		font-size: 12.5px;
	}
	dd {
		margin: 4px 0 0;
		font: 600 24px/1 var(--font-display);
		letter-spacing: -0.02em;
	}
	dd.hot {
		color: var(--sev-critical);
	}
	.why {
		margin: 20px 0 28px;
		color: var(--ink-3);
		font-size: 14px;
		max-width: 52ch;
	}
	.stage {
		position: relative;
		margin: 0;
		padding: 18px;
		border-radius: var(--radius);
		border: 1px solid var(--hairline);
		background: radial-gradient(90% 90% at 50% 40%, var(--surface-1), var(--bg-deep));
	}
	svg {
		display: block;
		width: 100%;
		height: auto;
	}
	.edge {
		fill: none;
		stroke: var(--brand);
		opacity: 0.45;
		transition:
			opacity 0.4s,
			stroke 0.4s;
	}
	.edge.done {
		opacity: 0.7;
	}
	.edge.on {
		opacity: 1;
		filter: drop-shadow(0 0 6px var(--brand-glow));
	}
	.edge.hot {
		stroke: var(--sev-critical);
		opacity: 0.85;
	}
	.arrow {
		fill: var(--brand);
	}
	.arrow--hot {
		fill: var(--sev-critical);
	}
	.elabel rect {
		fill: var(--surface-1);
		stroke: var(--hairline-strong);
	}
	.elabel text {
		fill: var(--ink-1);
		font: 500 12px var(--font-mono);
	}
	.elabel {
		opacity: 0;
		transition: opacity 0.35s;
	}
	.elabel.show {
		opacity: 1;
	}
	.node rect,
	.node circle {
		fill: var(--surface-3);
		stroke: var(--brand);
		stroke-width: 1.5;
	}
	.node circle {
		stroke: var(--ink-3);
		stroke-width: 1;
	}
	.node.hot rect {
		stroke: var(--sev-critical);
		stroke-width: 3;
	}
	.node text {
		fill: var(--ink-2);
		font: 12.5px var(--font-ui);
	}
	.node.hot text {
		fill: var(--ink-1);
		font-weight: 600;
	}
	figcaption {
		margin-top: 8px;
		color: var(--ink-3);
		font-size: 12.5px;
	}
	figcaption a {
		color: var(--ink-2);
	}
	@media (max-width: 960px) {
		.grid {
			grid-template-columns: minmax(0, 1fr);
		}
	}
</style>
