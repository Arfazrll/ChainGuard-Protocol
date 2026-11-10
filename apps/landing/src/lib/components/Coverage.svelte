<script lang="ts">
	import { DOCS } from '#lib/config.ts';
	import { reveal } from '#lib/motion.ts';

	// From data/labels/ethereum-mainnet.json: public contracts SvlteChain labels today.
	const names = ['Aave', 'Uniswap', 'Chainlink', 'Balancer', 'Compound', 'Morpho', 'Curve', 'Euler', 'Maker', 'Lido', 'Circle', 'Tether', 'Arbitrum', 'Optimism', 'Base', 'Polygon', 'Wormhole', 'zkSync'];
</script>

<section class="coverage" aria-labelledby="coverage-title">
	<div class="wrap" use:reveal>
		<h2 id="coverage-title" data-reveal>Watching the contracts that move Ethereum's money</h2>
		<ul data-reveal>
			{#each names as n (n)}<li>{n}</li>{/each}
		</ul>
		<p data-reveal>
			Named because their public contracts are in SvlteChain's open <a href={DOCS.labels}>label dataset</a>. No
			partnership or endorsement is implied. Adding a protocol is a reviewed pull request.
		</p>
	</div>
</section>

<style>
	.coverage {
		padding-block: 64px 40px;
		text-align: center;
	}
	h2 {
		font-size: 15px;
		font-weight: 500;
		letter-spacing: 0;
		color: var(--graphite);
	}
	ul {
		list-style: none;
		display: flex;
		flex-wrap: wrap;
		justify-content: center;
		gap: 14px 40px;
		margin: 28px auto 0;
		padding: 0;
		max-width: 980px;
	}
	li {
		font-size: clamp(19px, 2vw, 24px);
		font-weight: 600;
		letter-spacing: -0.02em;
		color: #8a9099;
		transition: color 0.2s var(--ease);
	}
	li:hover {
		color: var(--ink);
	}
	p {
		margin: 28px auto 0;
		max-width: 64ch;
		font-size: 13.5px;
		color: var(--muted);
	}
</style>
