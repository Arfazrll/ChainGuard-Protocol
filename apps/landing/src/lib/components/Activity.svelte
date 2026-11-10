<script lang="ts">
	/**
	 * What ChainGuard saw on mainnet. Live when an engine is reachable,
	 * otherwise the recorded run, and it says which.
	 */
	import { RUN } from '#lib/data/recorded.ts';
	import { int, usdCompact } from '#lib/format.ts';
	import { live } from '#lib/live.svelte.ts';
	import { countUp, reveal } from '#lib/motion.ts';

	const figures = $derived([
		{ label: 'transactions checked', value: live.figures.txs, format: int },
		{ label: 'in priced token transfers', value: live.figures.usd, format: usdCompact },
		{ label: 'blocks, each confirmed by 2 nodes', value: live.figures.blocks, format: int },
		{ label: 'alerts raised', value: live.figures.alerts, format: int }
	]);
	const source = $derived(
		live.mode === 'live'
			? `Live from the engine at ${live.engine.replace(/^https?:\/\//, '')}.`
			: `Recorded on Ethereum mainnet, blocks ${RUN.first_block.toLocaleString('en-US')} to ${RUN.last_block.toLocaleString('en-US')}, with publicnode and drpc. Alerts are from the two incident replays.`
	);
</script>

<section class="activity" aria-labelledby="activity-title">
	<div class="wrap" use:reveal>
		<h2 id="activity-title" class="visually-hidden">ChainGuard on mainnet</h2>
		<div class="figs">
			{#each figures as f, i (f.label)}
				<div class="fig" data-reveal data-reveal-index={i}>
					<span class="num" use:countUp={{ value: f.value, format: f.format }}>{f.format(f.value)}</span>
					<span class="lbl">{f.label}</span>
				</div>
			{/each}
		</div>
		<p class="src" data-reveal>
			<span class="dot" class:on={live.mode === 'live'} aria-hidden="true"></span>{source}
			{#if live.mode !== 'live'}<a class="fn" href="#fn-4" aria-label="Footnote 4">4</a>{/if}
		</p>
	</div>
</section>

<style>
	.activity {
		border-block: 1px solid var(--rule);
		background: var(--white);
		padding-block: 44px 36px;
	}
	.figs {
		display: grid;
		grid-template-columns: repeat(4, minmax(0, 1fr));
	}
	.fig {
		display: grid;
		gap: 6px;
		padding: 4px 28px;
		border-left: 1px solid var(--rule);
	}
	.fig:first-child {
		border-left: 0;
		padding-left: 0;
	}
	.num {
		font-size: clamp(30px, 3.4vw, 44px);
		font-weight: 600;
		letter-spacing: -0.03em;
		font-variant-numeric: tabular-nums;
		line-height: 1.1;
	}
	.lbl {
		color: var(--graphite);
		font-size: 15px;
	}
	.src {
		display: flex;
		align-items: baseline;
		gap: 8px;
		margin: 28px 0 0;
		font-size: 13.5px;
		color: var(--muted);
	}
	.dot {
		flex: none;
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: #b8bdc4;
		transform: translateY(-1px);
	}
	.dot.on {
		background: var(--ok);
	}
	@media (max-width: 860px) {
		.figs {
			grid-template-columns: repeat(2, minmax(0, 1fr));
			row-gap: 28px;
		}
		.fig:nth-child(3) {
			border-left: 0;
			padding-left: 0;
		}
	}
	@media (max-width: 480px) {
		.figs {
			grid-template-columns: minmax(0, 1fr);
		}
		.fig {
			border-left: 0;
			padding-left: 0;
		}
	}
</style>
