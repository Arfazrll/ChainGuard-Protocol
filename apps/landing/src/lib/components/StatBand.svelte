<script lang="ts">
	import { RUN } from '#lib/data/recorded.ts';
	import { int, usdCompact } from '#lib/format.ts';
	import { live } from '#lib/live.svelte.ts';
	import { countUp, reveal } from '#lib/motion.ts';

	const recordedSpan = $derived.by(() => {
		const mins = Math.max(1, Math.round((RUN.last_ts - RUN.first_ts) / 60));
		return `${RUN.blocks} blocks (~${mins} min) of live mainnet, ${RUN.providers.join(' + ')}`;
	});

	const tiles = $derived([
		{
			label: 'Transactions watched',
			value: live.figures.txs,
			format: int,
			source: live.mode === 'live' ? live.figures.source : `Recorded run: ${recordedSpan}`
		},
		{
			label: 'Priced value observed',
			value: live.figures.usd,
			format: usdCompact,
			source:
				live.mode === 'live'
					? 'Gross priced transfer volume (a flash loan counts out and back); unpriced tokens excluded'
					: 'Same run, gross: a flash loan counts out and back. Priced by labels and Chainlink, never guessed'
		},
		{
			label: 'Alerts raised',
			value: live.figures.alerts,
			format: int,
			source:
				live.mode === 'live'
					? 'By this engine since start, after dedup and rate limits'
					: 'On the bundled incident replays: Euler (2023) and the USDC depeg'
		},
		{
			label: 'Chains covered',
			value: live.figures.chains,
			format: int,
			source: 'Ethereum mainnet today; more chains are a config entry each'
		}
	]);
</script>

<section class="band" aria-labelledby="band-title">
	<div class="wrap" use:reveal>
		<h2 id="band-title" class="visually-hidden">ChainGuard in numbers</h2>
		<p class="mode" data-reveal>
			{#if live.mode === 'live'}
				<span class="dot live" aria-hidden="true"></span> Live from the engine at <span class="mono">{live.engine}</span>
			{:else}
				<span class="dot" aria-hidden="true"></span> No engine reachable: showing a recorded real run, blocks
				<span class="mono">#{RUN.first_block.toLocaleString('en-US')}–#{RUN.last_block.toLocaleString('en-US')}</span>
			{/if}
		</p>
		<div class="tiles">
			{#each tiles as t, i (t.label)}
				<div class="tile glass" data-reveal data-reveal-index={i + 1}>
					<div class="value mono" use:countUp={{ value: t.value, format: t.format }}>{t.format(t.value)}</div>
					<div class="label">{t.label}</div>
					<div class="source">{t.source}</div>
				</div>
			{/each}
		</div>
	</div>
</section>

<style>
	.band {
		padding-block: 0 clamp(56px, 8vw, 96px);
	}
	.mode {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 4px 8px;
		color: var(--ink-3);
		font-size: 13px;
		margin: 0 0 14px;
	}
	.dot {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--ink-3);
	}
	.dot.live {
		background: var(--live);
		box-shadow: 0 0 0 4px var(--live-wash);
	}
	.tiles {
		display: grid;
		grid-template-columns: repeat(4, minmax(0, 1fr));
		gap: 12px;
	}
	.tile {
		padding: 22px 22px 18px;
		transition:
			border-color 0.25s,
			box-shadow 0.25s;
	}
	.tile:hover {
		border-color: color-mix(in oklab, var(--brand) 40%, transparent);
		box-shadow: 0 10px 50px -20px var(--brand-glow);
	}
	.value {
		font: 600 clamp(30px, 3.6vw, 44px)/1 var(--font-display);
		letter-spacing: -0.03em;
		font-variant-numeric: tabular-nums;
	}
	.label {
		margin-top: 10px;
		font-weight: 600;
		font-size: 14px;
	}
	.source {
		margin-top: 6px;
		color: var(--ink-3);
		font-size: 12.5px;
		line-height: 1.45;
	}
	@media (max-width: 900px) {
		.tiles {
			grid-template-columns: repeat(2, minmax(0, 1fr));
		}
	}
	@media (max-width: 480px) {
		.tiles {
			grid-template-columns: minmax(0, 1fr);
		}
	}
</style>
