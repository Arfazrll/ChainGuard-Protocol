<script lang="ts">
	import { fly } from 'svelte/transition';
	import type { Tab, TermEvent } from '#lib/data/recorded.ts';
	import { RUN } from '#lib/data/recorded.ts';
	import { etherscanTx, short } from '#lib/format.ts';
	import { live } from '#lib/live.svelte.ts';
	import { reducedMotion, reveal } from '#lib/motion.ts';

	const TABS: { id: Tab; label: string }[] = [
		{ id: 'all', label: 'All' },
		{ id: 'defi', label: 'DeFi' },
		{ id: 'bridges', label: 'Bridges' },
		{ id: 'stablecoins', label: 'Stablecoins' }
	];
	const SEV = {
		critical: { label: 'Critical', glyph: '◆' },
		high: { label: 'High', glyph: '▲' },
		medium: { label: 'Medium', glyph: '●' },
		low: { label: 'Low', glyph: '○' },
		info: { label: 'Info', glyph: '·' }
	} as const;

	const LANES = { rule: 'Rule', invariant: 'Invariant', ml: 'ML', system: 'System' } as const;
	let tab = $state<Tab>('all');
	const counts = $derived(
		Object.fromEntries(
			TABS.map((t) => [t.id, t.id === 'all' ? live.events.length : live.events.filter((e) => e.category === t.id).length])
		) as Record<Tab, number>
	);
	const shown = $derived(tab === 'all' ? live.events : live.events.filter((e) => e.category === tab));
	const enter = (node: Element) => fly(node, { y: -8, duration: reducedMotion() ? 0 : 320 });

	function onKey(e: KeyboardEvent, i: number) {
		const d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
		if (!d) return;
		const next = TABS[(i + d + TABS.length) % TABS.length];
		tab = next.id;
		document.getElementById(`tab-${next.id}`)?.focus();
	}

	const when = (e: TermEvent) => (e.replay ? e.replay : `#${e.block.toLocaleString('en-US')}`);
</script>

<section id="live" class="terminal-section" aria-labelledby="live-title">
	<div class="bloom bloom--violet glow" aria-hidden="true"></div>
	<div class="wrap" use:reveal>
		<p class="eyebrow" data-reveal>Right now</p>
		<h2 id="live-title" data-reveal>What is happening on-chain, as ChainGuard sees it.</h2>
		<p class="lede" data-reveal>
			Large priced flows and every alert, newest first. Alerts carry their lane, weakness class and how many
			independent nodes attested the evidence.
		</p>

		<div class="term glass" data-reveal>
			<div class="bar">
				<div class="tabs" role="tablist" aria-label="Filter events">
					{#each TABS as t, i (t.id)}
						<button
							id="tab-{t.id}"
							role="tab"
							type="button"
							aria-selected={tab === t.id}
							aria-controls="term-panel"
							tabindex={tab === t.id ? 0 : -1}
							onclick={() => (tab = t.id)}
							onkeydown={(e) => onKey(e, i)}
						>
							{t.label} <span class="n mono">{counts[t.id]}</span>
						</button>
					{/each}
				</div>
				<span class="state state--{live.mode}">
					<span class="dot" aria-hidden="true"></span>
					{#if live.mode === 'live'}
						Live · <span class="mono">{live.engine.replace(/^https?:\/\//, '')}</span>
					{:else if live.mode === 'recorded'}
						Recorded · mainnet #{RUN.first_block.toLocaleString('en-US')}–#{RUN.last_block.toLocaleString('en-US')} + incident replays
					{:else}
						Connecting…
					{/if}
				</span>
			</div>

			<div id="term-panel" role="tabpanel" aria-labelledby="tab-{tab}" aria-live="polite" class="feed">
				{#if shown.length === 0}
					<p class="empty">
						Nothing in this category yet{live.mode === 'live' ? '. Events appear as blocks land.' : '.'}
					</p>
				{:else}
					<ol>
						{#each shown as e (e.id)}
							<li class="ev ev--{e.kind}" in:enter>
								<span class="when mono">{when(e)}</span>
								{#if e.kind === 'alert' && e.severity}
									<span class="sev sev--{e.severity}"><i aria-hidden="true">{SEV[e.severity].glyph}</i>{SEV[e.severity].label}</span>
								{:else}
									<span class="kind mono">flow</span>
								{/if}
								<span class="body">
									<span class="title">{e.title}</span>
									<span class="detail">
										{#if e.lane}<span class="lane">{LANES[e.lane]}</span>{/if}
										{e.detail}
										{#if e.tx}
											· <a class="mono" href={etherscanTx(e.tx)} target="_blank" rel="noopener">{short(e.tx, 8, 4)}</a>
										{/if}
									</span>
								</span>
							</li>
						{/each}
					</ol>
				{/if}
			</div>
		</div>
	</div>
</section>

<style>
	.terminal-section {
		overflow: hidden;
	}
	.glow {
		width: 760px;
		height: 520px;
		right: -220px;
		top: 80px;
		opacity: 0.35;
	}
	.term {
		position: relative;
		margin-top: 40px;
		overflow: hidden;
	}
	.bar {
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		align-items: center;
		gap: 10px 16px;
		padding: 12px 14px;
		border-bottom: 1px solid var(--hairline);
	}
	.tabs {
		display: flex;
		gap: 4px;
		flex-wrap: wrap;
	}
	[role='tab'] {
		background: none;
		border: 1px solid transparent;
		border-radius: 999px;
		padding: 6px 12px;
		color: var(--ink-3);
		font: 500 13px/1 var(--font-ui);
		cursor: pointer;
		transition:
			color 0.2s,
			background 0.2s;
	}
	[role='tab']:hover {
		color: var(--ink-1);
	}
	[role='tab'][aria-selected='true'] {
		color: var(--ink-1);
		background: var(--surface-3);
		border-color: var(--hairline-strong);
	}
	.n {
		color: var(--ink-3);
		margin-left: 4px;
		font-size: 11.5px;
	}
	.state {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		color: var(--ink-3);
		font-size: 12px;
	}
	.dot {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--ink-3);
		flex: none;
	}
	.state--live .dot {
		background: var(--live);
		box-shadow: 0 0 0 4px var(--live-wash);
	}
	@media (prefers-reduced-motion: no-preference) {
		.state--live .dot {
			animation: pulse 2.2s var(--ease) infinite;
		}
		@keyframes pulse {
			50% {
				box-shadow: 0 0 0 7px transparent;
			}
		}
	}
	.feed {
		height: 440px;
		overflow: hidden;
		mask-image: linear-gradient(black 78%, transparent);
	}
	ol {
		list-style: none;
		margin: 0;
		padding: 4px 0;
	}
	.ev {
		display: grid;
		grid-template-columns: 150px 92px minmax(0, 1fr);
		gap: 12px;
		align-items: baseline;
		padding: 11px 16px;
		border-bottom: 1px solid var(--hairline);
		font-size: 13.5px;
	}
	.ev--alert {
		background: linear-gradient(90deg, color-mix(in oklab, var(--surface-3) 60%, transparent), transparent 60%);
	}
	.when {
		color: var(--ink-3);
		font-size: 12px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.kind {
		color: var(--brand-ink);
		font-size: 12px;
	}
	.body {
		display: grid;
		gap: 3px;
		min-width: 0;
	}
	.title {
		color: var(--ink-1);
		overflow-wrap: anywhere;
	}
	.detail {
		color: var(--ink-3);
		font-size: 12px;
		overflow-wrap: anywhere;
	}
	.detail a {
		color: var(--ink-2);
	}
	.lane {
		color: var(--ink-2);
		border: 1px solid var(--hairline-strong);
		border-radius: 999px;
		padding: 0 6px;
		margin-right: 4px;
	}
	.empty {
		margin: 0;
		padding: 40px 18px;
		color: var(--ink-3);
	}
	@media (max-width: 640px) {
		.ev {
			grid-template-columns: minmax(0, 1fr) auto;
			grid-template-areas: 'when sev' 'body body';
			padding: 11px 14px;
		}
		.when {
			grid-area: when;
		}
		.ev > :global(.sev),
		.kind {
			grid-area: sev;
			justify-self: end;
		}
		.body {
			grid-area: body;
		}
	}
</style>
