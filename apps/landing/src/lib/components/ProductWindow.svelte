<script lang="ts">
	/**
	 * A faithful, static rendering of the ChainGuard dashboard after the
	 * incident replay. Every value is what the engine produced on the real
	 * Euler and USDC fixtures (see apps/engine/test/fixtures/incidents).
	 */
	import { EULER_FLOW, INCIDENT_ALERTS } from '#lib/data/recorded.ts';

	const scores = [
		{ p: 'Euler', s: 0, band: 'Critical', tone: 'crit' },
		{ p: 'Circle', s: 45, band: 'High', tone: 'high' },
		{ p: 'Aave', s: 100, band: 'Low', tone: 'ok' },
		{ p: 'Balancer', s: 100, band: 'Low', tone: 'ok' },
		{ p: 'Compound', s: 100, band: 'Low', tone: 'ok' }
	];
	const blocks = [
		{ n: '16,817,996', rec: 410, tx: 113, hot: true },
		{ n: '16,802,135', rec: 615, tx: 222, hot: true },
		{ n: '16,802,107', rec: 292, tx: 96, hot: false }
	];
	const pos: Record<string, [number, number]> = {
		aave: [40, 92],
		exploit: [150, 92],
		violator: [250, 34],
		euler: [330, 92],
		liquidator: [250, 150]
	};
	const edges = EULER_FLOW.edges.map((e, i) => {
		const [x1, y1] = pos[e.from];
		const [x2, y2] = pos[e.to];
		const bend = i === 0 ? -26 : i === 5 ? -26 : 0;
		const mx = (x1 + x2) / 2;
		const my = (y1 + y2) / 2;
		const len = Math.hypot(x2 - x1, y2 - y1);
		const cx = mx + (-(y2 - y1) / len) * bend;
		const cy = my + ((x2 - x1) / len) * bend;
		return { d: `M${x1},${y1} Q${cx},${cy} ${x2},${y2}`, hot: e.from === 'euler' };
	});
</script>

<div class="window" role="img" aria-label="The ChainGuard dashboard after replaying the Euler Finance exploit: three alerts, Euler's risk score at 0, the exploit's fund flows and a verified audit chain.">
	<div class="chrome">
		<span class="dots" aria-hidden="true"><i></i><i></i><i></i></span>
		<span class="url">localhost:4300</span>
		<span class="live"><i aria-hidden="true"></i>Replay of mainnet blocks</span>
	</div>
	<div class="app">
		<aside class="side">
			<div class="logo"><span class="sq"></span>ChainGuard</div>
			<nav>
				<span class="on">Overview</span><span>Alerts</span><span>Fund flows</span><span>Risk</span><span>Audit</span><span>Organization</span>
			</nav>
			<div class="chain">Ethereum mainnet</div>
		</aside>
		<main>
			<div class="tiles">
				<div class="tile"><span class="k">Head block</span><b>#16,817,996</b><span class="s">2 nodes agreed</span></div>
				<div class="tile"><span class="k">Open alerts</span><b>3</b><span class="s">2 critical, 1 high</span></div>
				<div class="tile"><span class="k">Audit chain</span><b>Verified</b><span class="s">15 entries</span></div>
				<div class="tile"><span class="k">Detection</span><b>3 lanes</b><span class="s">5 rules, 9 invariants, ML</span></div>
			</div>
			<div class="grid">
				<section class="card alerts">
					<h4>Alerts</h4>
					{#each INCIDENT_ALERTS as a (a.id)}
						<div class="alert">
							<span class="chip chip--{a.severity}">{a.severity === 'critical' ? 'Critical' : 'High'}</span>
							<div>
								<p class="t">{a.title}</p>
								<p class="m">{a.lane === 'rule' ? 'Rule' : 'Invariant'} lane, block {a.block.toLocaleString('en-US')}, 2 nodes</p>
							</div>
						</div>
					{/each}
				</section>
				<section class="card flow">
					<h4>Fund flows, tx 0xc310…111d</h4>
					<svg viewBox="0 0 370 184" aria-hidden="true">
						{#each edges as e, i (i)}<path d={e.d} class:hot={e.hot} />{/each}
						{#each Object.entries(pos) as [id, [x, y]] (id)}
							<circle cx={x} cy={y} r={id === 'euler' || id === 'aave' ? 9 : 7} class:euler={id === 'euler'} class:lend={id === 'aave'} />
						{/each}
						<text x="40" y="118">Aave</text><text x="330" y="118">Euler</text><text x="150" y="118">exploit</text>
					</svg>
				</section>
				<section class="card risk">
					<h4>Protocol risk</h4>
					{#each scores as r (r.p)}
						<div class="row tone--{r.tone}">
							<span>{r.p}</span><b>{r.s}</b><em>{r.band}</em>
							<span class="bar"><span style="width:{Math.max(3, r.s)}%"></span></span>
						</div>
					{/each}
				</section>
				<section class="card blocks">
					<h4>Blocks</h4>
					{#each blocks as b (b.n)}
						<div class="brow"><span class="mono">#{b.n}</span><span>{b.rec} records</span><span>{b.tx} txs</span><span class="att">2 of 2 nodes</span>{#if b.hot}<span class="flag">alert</span>{/if}</div>
					{/each}
				</section>
			</div>
		</main>
	</div>
</div>

<style>
	.window {
		border-radius: 16px;
		overflow: hidden;
		background: var(--night);
		border: 1px solid #262d37;
		box-shadow:
			0 1px 0 rgba(255, 255, 255, 0.06) inset,
			0 40px 80px -40px rgba(13, 17, 23, 0.55),
			0 18px 36px -24px rgba(13, 17, 23, 0.4);
		color: var(--night-ink);
		font-size: 12px;
		text-align: left;
		user-select: none;
	}
	.chrome {
		display: flex;
		align-items: center;
		gap: 14px;
		height: 38px;
		padding: 0 14px;
		background: var(--night-2);
		border-bottom: 1px solid var(--night-rule);
	}
	.dots {
		display: flex;
		gap: 6px;
	}
	.dots i {
		width: 10px;
		height: 10px;
		border-radius: 50%;
		background: #3a424e;
	}
	.url {
		flex: 0 1 280px;
		margin-inline: auto;
		padding: 4px 12px;
		border-radius: 6px;
		background: var(--night);
		color: var(--night-ink-2);
		font-size: 11.5px;
		text-align: center;
	}
	.live {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		color: var(--night-ink-2);
		font-size: 11.5px;
	}
	.live i {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		background: #4ec27e;
	}
	.app {
		display: grid;
		grid-template-columns: 168px 1fr;
		min-height: 440px;
	}
	.side {
		display: flex;
		flex-direction: column;
		gap: 18px;
		padding: 16px 14px;
		border-right: 1px solid var(--night-rule);
		background: #10151b;
	}
	.logo {
		display: flex;
		align-items: center;
		gap: 8px;
		font-weight: 600;
		font-size: 13px;
	}
	.sq {
		width: 14px;
		height: 14px;
		border-radius: 4px;
		background: var(--night-ink);
	}
	.side nav {
		display: grid;
		gap: 2px;
		color: var(--night-ink-2);
	}
	.side nav span {
		padding: 6px 8px;
		border-radius: 6px;
	}
	.side nav .on {
		background: var(--night-3);
		color: var(--night-ink);
	}
	.chain {
		margin-top: auto;
		color: var(--night-ink-2);
		font-size: 11px;
	}
	main {
		padding: 16px;
		display: grid;
		gap: 12px;
		align-content: start;
	}
	.tiles {
		display: grid;
		grid-template-columns: repeat(4, 1fr);
		gap: 10px;
	}
	.tile {
		display: grid;
		gap: 2px;
		padding: 10px 12px;
		border-radius: 10px;
		background: var(--night-2);
		border: 1px solid var(--night-rule);
	}
	.tile .k,
	.tile .s {
		color: var(--night-ink-2);
		font-size: 11px;
	}
	.tile b {
		font-size: 17px;
		font-weight: 600;
		letter-spacing: -0.01em;
	}
	.grid {
		display: grid;
		grid-template-columns: 1.25fr 1fr;
		gap: 10px;
	}
	.card {
		padding: 12px 14px;
		border-radius: 10px;
		background: var(--night-2);
		border: 1px solid var(--night-rule);
	}
	h4 {
		margin: 0 0 8px;
		font-size: 12px;
		font-weight: 600;
		letter-spacing: 0;
		color: var(--night-ink);
	}
	.alert {
		display: grid;
		grid-template-columns: 62px 1fr;
		gap: 10px;
		padding: 8px 0;
		border-top: 1px solid var(--night-rule);
	}
	.alert:first-of-type {
		border-top: 0;
	}
	.chip {
		align-self: start;
		padding: 1px 6px;
		border-radius: 5px;
		font-size: 10.5px;
		font-weight: 600;
		text-align: center;
	}
	.chip--critical {
		background: rgba(229, 72, 61, 0.18);
		color: #ff8a80;
	}
	.chip--high {
		background: rgba(236, 131, 90, 0.18);
		color: #f5a47e;
	}
	.t {
		margin: 0;
		font-size: 12px;
		line-height: 1.4;
		color: var(--night-ink);
	}
	.m {
		margin: 2px 0 0;
		font-size: 11px;
		color: var(--night-ink-2);
	}
	.flow svg {
		width: 100%;
		height: auto;
	}
	.flow path {
		fill: none;
		stroke: #4f5f80;
		stroke-width: 1.6;
	}
	.flow path.hot {
		stroke: #ef5a4f;
		stroke-width: 2.2;
	}
	.flow circle {
		fill: #2a3340;
		stroke: #6b7686;
	}
	.flow circle.euler {
		stroke: #ef5a4f;
		stroke-width: 2;
	}
	.flow circle.lend {
		stroke: #8ea2d8;
	}
	.flow text {
		fill: var(--night-ink-2);
		font: 10px var(--font);
		text-anchor: middle;
	}
	.row {
		display: grid;
		grid-template-columns: 1fr 28px 54px;
		grid-template-areas: 'name score band' 'bar bar bar';
		gap: 2px 8px;
		align-items: baseline;
		padding: 5px 0;
	}
	.row b {
		text-align: right;
		font-weight: 600;
	}
	.row em {
		font-style: normal;
		font-size: 11px;
		color: var(--night-ink-2);
	}
	.bar {
		grid-area: bar;
		height: 3px;
		border-radius: 3px;
		background: var(--night-3);
	}
	.bar span {
		display: block;
		height: 100%;
		border-radius: 3px;
		background: #4ec27e;
	}
	.tone--crit .bar span {
		background: #ef5a4f;
	}
	.tone--crit em {
		color: #ff8a80;
	}
	.tone--high .bar span {
		background: #f5a47e;
	}
	.tone--high em {
		color: #f5a47e;
	}
	.brow {
		display: flex;
		gap: 14px;
		padding: 6px 0;
		border-top: 1px solid var(--night-rule);
		color: var(--night-ink-2);
		white-space: nowrap;
	}
	.brow:first-of-type {
		border-top: 0;
	}
	.brow .mono {
		color: var(--night-ink);
	}
	.att {
		color: #7fd0a0;
	}
	.flag {
		margin-left: auto;
		color: #ff8a80;
	}
	@media (max-width: 760px) {
		.app {
			grid-template-columns: 1fr;
		}
		.side {
			display: none;
		}
		.tiles {
			grid-template-columns: repeat(2, 1fr);
		}
		.grid {
			grid-template-columns: 1fr;
		}
		.blocks,
		.flow,
		.live {
			display: none;
		}
	}
</style>
