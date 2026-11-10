<script lang="ts">
	import { dashboardUrl } from '#lib/config.ts';
	import { EULER_FLOW } from '#lib/data/recorded.ts';
	import { etherscanTx, short, usd, usdCompact } from '#lib/format.ts';
	import { reveal } from '#lib/motion.ts';

	const legs = [
		{ title: 'Borrow', text: 'Aave V2 lends 30,000,000 DAI to the attacker’s contract as a flash loan, to be repaid within the same transaction.' },
		{ title: 'Hand over', text: 'The funds move to a second contract, the “violator”, which will interact with Euler.' },
		{ title: 'Deposit', text: 'The violator sends 30,000,000 DAI into Euler in two transfers, a 20M deposit and a 10M repayment, borrows against it with Euler’s leverage feature, then donates part of its position to make itself insolvent on purpose.' },
		{ title: 'Drain', text: 'A liquidator contract owned by the attacker liquidates that position at a discount and withdraws 38,904,507 DAI from Euler.' },
		{ title: 'Collect', text: 'The withdrawn DAI flows back to the attacker’s first contract.' },
		{ title: 'Repay', text: 'Aave is repaid 30,027,000 DAI, its principal plus fee. The difference stays with the attacker.' }
	];

	let active = $state(3);

	const pos: Record<string, { x: number; y: number }> = {
		aave: { x: 90, y: 250 },
		exploit: { x: 330, y: 250 },
		violator: { x: 560, y: 90 },
		euler: { x: 740, y: 250 },
		liquidator: { x: 560, y: 410 }
	};
	const edges = EULER_FLOW.edges.map((e, i) => {
		const a = pos[e.from];
		const b = pos[e.to];
		const bend = i === 0 || i === 5 ? -54 : 0;
		const len = Math.hypot(b.x - a.x, b.y - a.y);
		const cx = (a.x + b.x) / 2 + (-(b.y - a.y) / len) * bend;
		const cy = (a.y + b.y) / 2 + ((b.x - a.x) / len) * bend;
		const t = 1 - 40 / len;
		const ex = (1 - t) ** 2 * a.x + 2 * (1 - t) * t * cx + t * t * b.x;
		const ey = (1 - t) ** 2 * a.y + 2 * (1 - t) * t * cy + t * t * b.y;
		return { ...e, d: `M${a.x},${a.y} Q${cx},${cy} ${ex},${ey}`, lx: 0.25 * a.x + 0.5 * cx + 0.25 * b.x, ly: 0.25 * a.y + 0.5 * cy + 0.25 * b.y };
	});
	const nodeLabel: Record<string, string> = {
		aave: 'Aave V2 aDAI',
		exploit: 'Attacker contract',
		violator: 'Violator',
		euler: 'Euler Finance',
		liquidator: 'Liquidator'
	};

	const raised = [
		{ sev: 'critical', label: 'Critical', lane: 'Rule lane', title: 'Euler Finance net outflow $8,904,507 in a flash-loan transaction', detail: 'flash-loan-drain, weakness class flash-loan-attack, evidence attested by 2 nodes' },
		{ sev: 'critical', label: 'Critical', lane: 'Invariant lane', title: 'Euler Finance net outflow $8,904,507 within 50 blocks; limit $5,000,000', detail: 'euler-outflow, weakness class abnormal-tvl-drawdown, same transaction' },
		{ sev: 'medium', label: 'Medium', lane: 'Model', title: 'Unusual fund-flow graph in tx 0xc310…111d: 20 transfers across 7 addresses, $197,836,015 moved', detail: 'Total moved is 32 times the 99.9th percentile of normal. Capped at medium by design.' }
	];
</script>

<section id="case-study" class="case section" aria-labelledby="case-title">
	<div class="wrap">
		<div class="section-head" use:reveal>
			<p class="kicker" data-reveal>Case study</p>
			<h2 id="case-title" class="h2" data-reveal>The Euler Finance exploit, replayed. <span class="soft">One transaction, six moves, $8.9 million.</span></h2>
			<p class="lead" data-reveal>
				On 13 March 2023 an attacker drained Euler Finance through a series of flash-loan transactions. This is one of
				them, block {EULER_FLOW.block.toLocaleString('en-US')}, captured from two independent providers and replayed through SvlteChain unchanged.<a class="fn" href="#fn-1" aria-label="Footnote 1">1</a>
			</p>
		</div>

		<div class="explorer" use:reveal>
			<ol class="legs" data-reveal>
				{#each legs as l, i (l.title)}
					<li>
						<button type="button" class:on={active === i} aria-pressed={active === i} onclick={() => (active = i)} onmouseenter={() => (active = i)} onfocus={() => (active = i)}>
							<span class="leg-n">{i + 1}</span>
							<span class="leg-body">
								<span class="leg-title">{l.title}<span class="leg-usd">{usdCompact(EULER_FLOW.edges[i].usd)}</span></span>
								<span class="leg-text">{l.text}</span>
							</span>
						</button>
					</li>
				{/each}
			</ol>

			<figure class="graph" data-reveal>
				<svg viewBox="0 0 830 500" role="img" aria-labelledby="euler-g">
					<desc id="euler-g">Fund flow of the Euler exploit transaction. Step {active + 1}: {legs[active].text}</desc>
					<defs>
						<marker id="ah" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" class="ah" /></marker>
						<marker id="ah-on" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" class="ah-on" /></marker>
						<marker id="ah-hot" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" class="ah-hot" /></marker>
					</defs>
					{#each edges as e, i (i)}
						<path
							class="edge"
							class:on={active === i}
							class:hot={active === i && e.from === 'euler'}
							class:past={i < active}
							d={e.d}
							marker-end={active === i ? (e.from === 'euler' ? 'url(#ah-hot)' : 'url(#ah-on)') : 'url(#ah)'}
						/>
					{/each}
					{#each edges as e, i (i)}
						{#if active === i}
							<g class="tag">
								<rect x={e.lx - 62} y={e.ly - 17} width="124" height="30" rx="8" />
								<text x={e.lx} y={e.ly + 3}>{usd(e.usd)}</text>
							</g>
						{/if}
					{/each}
					{#each Object.entries(pos) as [id, p] (id)}
						<g class="node" class:euler={id === 'euler'}>
							{#if id === 'aave' || id === 'euler'}
								<rect x={p.x - 34} y={p.y - 24} width="68" height="48" rx="12" />
							{:else}
								<circle cx={p.x} cy={p.y} r="24" />
							{/if}
							<text x={p.x} y={p.y + 50}>{nodeLabel[id]}</text>
						</g>
					{/each}
				</svg>
				<figcaption>
					Transaction <a class="mono" href={etherscanTx(EULER_FLOW.tx)} target="_blank" rel="noopener">{short(EULER_FLOW.tx, 10, 6)}</a>. Rectangles are labeled protocols; circles are the attacker’s contracts.
				</figcaption>
			</figure>
		</div>

		<div class="outcome" use:reveal>
			<div class="net" data-reveal>
				<h3 class="h3">Why SvlteChain counts net, not gross</h3>
				<p>
					A rule that fired on “a large transfer after a flash loan” would page you on every big flash loan, because the
					lender’s principal always leaves and comes back. SvlteChain nets every priced transfer per protocol across the
					transaction instead.
				</p>
				<dl>
					<div><dt>Euler Finance</dt><dd class="neg">−$8,904,507</dd></div>
					<div><dt>Aave V2 aDAI (the lender’s fee)</dt><dd>+$27,000</dd></div>
				</dl>
				<p class="small">Euler’s risk score drops to 0 (critical). Aave’s stays at 100.</p>
			</div>
			<div class="alerts" data-reveal>
				<h3 class="h3">What SvlteChain raised</h3>
				<ul>
					{#each raised as r (r.title)}
						<li>
							<div class="row1"><span class="sev sev--{r.sev}">{r.label}</span><span class="lane">{r.lane}</span></div>
							<p class="t">{r.title}</p>
							<p class="d">{r.detail}</p>
						</li>
					{/each}
				</ul>
				<a href={dashboardUrl()}>Open it in the dashboard</a>
			</div>
		</div>
	</div>
</section>

<style>
	.case {
		background: var(--white);
		border-block: 1px solid var(--rule);
	}
	.kicker {
		margin: 0;
		font-size: 15px;
		font-weight: 500;
		color: var(--cobalt);
	}
	.explorer {
		display: grid;
		grid-template-columns: minmax(0, 0.8fr) minmax(0, 1.2fr);
		gap: clamp(24px, 4vw, 56px);
		align-items: start;
	}
	.legs {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		gap: 4px;
	}
	.legs button {
		display: grid;
		grid-template-columns: 32px 1fr;
		gap: 12px;
		width: 100%;
		padding: 14px 16px;
		border: 1px solid transparent;
		border-radius: 14px;
		background: none;
		text-align: left;
		font: inherit;
		color: var(--graphite);
		cursor: pointer;
		transition:
			background 0.2s var(--ease),
			border-color 0.2s var(--ease);
	}
	.legs button:hover {
		background: var(--paper);
	}
	.legs button.on {
		background: var(--paper);
		border-color: var(--rule);
		color: var(--ink);
	}
	.leg-n {
		display: grid;
		place-items: center;
		width: 28px;
		height: 28px;
		border-radius: 50%;
		border: 1px solid var(--rule);
		font-size: 13px;
		font-weight: 500;
	}
	.on .leg-n {
		background: var(--ink);
		border-color: var(--ink);
		color: #fff;
	}
	.leg-title {
		display: flex;
		justify-content: space-between;
		gap: 12px;
		font-weight: 600;
		color: var(--ink);
	}
	.leg-usd {
		font-weight: 500;
		font-variant-numeric: tabular-nums;
		color: var(--graphite);
	}
	.leg-text {
		display: block;
		margin-top: 4px;
		font-size: 14.5px;
		line-height: 1.5;
		max-height: 0;
		overflow: hidden;
		opacity: 0;
		transition:
			max-height 0.35s var(--ease),
			opacity 0.35s var(--ease);
	}
	.on .leg-text {
		max-height: 140px;
		opacity: 1;
	}
	.graph {
		position: sticky;
		top: calc(var(--nav-h) + 24px);
		margin: 0;
		padding: 18px;
		border-radius: 24px;
		background: var(--paper);
		border: 1px solid var(--rule);
	}
	.graph svg {
		width: 100%;
		height: auto;
	}
	.edge {
		fill: none;
		stroke: #c3c8d0;
		stroke-width: 2;
		transition:
			stroke 0.3s var(--ease),
			stroke-width 0.3s var(--ease);
	}
	.edge.past {
		stroke: #98a2b3;
	}
	.edge.on {
		stroke: var(--cobalt);
		stroke-width: 4;
	}
	.edge.hot {
		stroke: var(--signal);
	}
	.ah {
		fill: #c3c8d0;
	}
	.ah-on {
		fill: var(--cobalt);
	}
	.ah-hot {
		fill: var(--signal);
	}
	.tag rect {
		fill: var(--white);
		stroke: var(--rule);
	}
	.tag text {
		font: 600 15px var(--font);
		fill: var(--ink);
		text-anchor: middle;
		font-variant-numeric: tabular-nums;
	}
	.node rect,
	.node circle {
		fill: var(--white);
		stroke: #8a9099;
		stroke-width: 1.5;
	}
	.node.euler rect {
		stroke: var(--signal);
		stroke-width: 3;
	}
	.node text {
		font: 500 15px var(--font);
		fill: var(--ink-2);
		text-anchor: middle;
	}
	figcaption {
		margin-top: 10px;
		font-size: 13.5px;
		color: var(--muted);
	}
	.outcome {
		display: grid;
		grid-template-columns: minmax(0, 0.9fr) minmax(0, 1.1fr);
		gap: 20px;
		margin-top: 56px;
	}
	.net,
	.alerts {
		padding: clamp(24px, 3vw, 40px);
		border-radius: 24px;
		border: 1px solid var(--rule);
		background: var(--paper);
	}
	.net p,
	.alerts p {
		color: var(--ink-2);
	}
	dl {
		display: grid;
		gap: 14px;
		margin: 22px 0 6px;
	}
	dt {
		font-size: 14px;
		color: var(--graphite);
	}
	dd {
		margin: 2px 0 0;
		font-size: 30px;
		font-weight: 600;
		letter-spacing: -0.02em;
		font-variant-numeric: tabular-nums;
	}
	dd.neg {
		color: var(--signal);
	}
	.small {
		font-size: 14.5px;
	}
	.alerts ul {
		list-style: none;
		margin: 18px 0 18px;
		padding: 0;
		display: grid;
		gap: 12px;
	}
	.alerts li {
		padding: 16px 18px;
		border-radius: 14px;
		background: var(--white);
		border: 1px solid var(--rule);
	}
	.row1 {
		display: flex;
		align-items: center;
		gap: 10px;
	}
	.lane {
		font-size: 13px;
		color: var(--graphite);
	}
	.t {
		margin: 10px 0 4px;
		font-weight: 600;
		color: var(--ink) !important;
		line-height: 1.4;
	}
	.d {
		margin: 0;
		font-size: 14px;
	}
	@media (max-width: 900px) {
		.explorer,
		.outcome {
			grid-template-columns: minmax(0, 1fr);
		}
		.graph {
			position: static;
			order: -1;
		}
	}
</style>
