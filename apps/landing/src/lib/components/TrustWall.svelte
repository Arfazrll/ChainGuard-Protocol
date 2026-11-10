<script lang="ts">
	import { DOCS } from '#lib/config.ts';
	import { reveal } from '#lib/motion.ts';

	// Names from data/labels/ethereum-mainnet.json: contracts ChainGuard labels.
	const groups = [
		{
			title: 'DeFi protocols and assets',
			names: ['Aave', 'Uniswap', 'Balancer', 'Compound', 'Morpho', 'Curve', 'Euler', 'Maker', 'Lido', 'Chainlink', 'Circle', 'Tether', '0x', '1inch', 'CoW Protocol', 'OpenSea']
		},
		{ title: 'Bridges watched', names: ['Arbitrum', 'Optimism', 'Base', 'Polygon', 'zkSync', 'Wormhole'] },
		{ title: 'Mixers watched', names: ['Tornado Cash'] },
		{ title: 'Chains', names: ['Ethereum mainnet'] }
	];

	const teams = [
		{
			who: 'Exchanges',
			what: 'Know when a deposit comes from an exploit or a mixer path before it is credited, and when a listed stablecoin leaves its peg.'
		},
		{
			who: 'Funds',
			what: 'A 0 to 100 health score per protocol with its reasons, plus a private watchlist whose alerts route only to your team.'
		},
		{
			who: 'Insurers',
			what: 'A PDF incident report with the exact transactions, blocks and attesting nodes, backed by a hash-chained audit log anyone can re-verify.'
		}
	];
</script>

<section class="trust" aria-labelledby="trust-title">
	<div class="wrap" use:reveal>
		<p class="eyebrow" data-reveal>Coverage</p>
		<h2 id="trust-title" data-reveal>What ChainGuard watches today.</h2>
		<div class="wall" data-reveal>
			{#each groups as g (g.title)}
				<div class="group">
					<h3>{g.title}</h3>
					<ul>
						{#each g.names as n (n)}<li>{n}</li>{/each}
					</ul>
				</div>
			{/each}
		</div>
		<p class="note" data-reveal>
			Named because their public contracts are in ChainGuard's open <a href={DOCS.labels}>label dataset</a>. No
			endorsement or partnership is implied.
		</p>

		<div class="strip" data-reveal>
			<h3 class="strip-title">Built for risk and compliance teams</h3>
			<div class="teams">
				{#each teams as t (t.who)}
					<div>
						<strong>{t.who}</strong>
						<p>{t.what}</p>
					</div>
				{/each}
			</div>
		</div>
	</div>
</section>

<style>
	.trust {
		border-block: 1px solid var(--hairline);
		background: linear-gradient(var(--bg-deep), var(--bg));
	}
	.wall {
		display: grid;
		grid-template-columns: 2fr 1.2fr 0.8fr 0.8fr;
		gap: 28px;
		margin-top: 44px;
	}
	.group h3,
	.strip-title {
		font: 500 12.5px/1 var(--font-mono);
		letter-spacing: 0.01em;
		color: var(--ink-3);
		margin: 0 0 16px;
	}
	ul {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-wrap: wrap;
		gap: 10px 22px;
	}
	li {
		font: 600 clamp(18px, 2vw, 24px)/1.1 var(--font-display);
		letter-spacing: -0.025em;
		color: var(--ink-2);
		transition: color 0.2s;
	}
	li:hover {
		color: var(--ink-1);
	}
	.note {
		margin: 28px 0 0;
		color: var(--ink-3);
		font-size: 13px;
	}
	.note a {
		color: var(--ink-2);
	}
	.strip {
		margin-top: 64px;
		padding-top: 32px;
		border-top: 1px solid var(--hairline);
	}
	.teams {
		display: grid;
		grid-template-columns: repeat(3, minmax(0, 1fr));
		gap: 28px;
	}
	.teams strong {
		font: 600 20px/1.2 var(--font-display);
		letter-spacing: -0.02em;
	}
	.teams p {
		margin: 8px 0 0;
		color: var(--ink-2);
		font-size: 14.5px;
	}
	@media (max-width: 900px) {
		.wall,
		.teams {
			grid-template-columns: minmax(0, 1fr);
		}
	}
</style>
