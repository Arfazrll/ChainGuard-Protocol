<script lang="ts">
	import { DOCS, REPO, dashboardUrl } from '#lib/config.ts';
	import { live } from '#lib/live.svelte.ts';
	import Mark from './Mark.svelte';

	const cols = [
		{
			h: 'Product',
			links: [
				['Live dashboard', dashboardUrl()],
				['Detection lanes', '#lanes'],
				['How it works', '#how'],
				['Roadmap', `${REPO}#roadmap`]
			]
		},
		{
			h: 'Docs',
			links: [
				['README', DOCS.readme],
				['Writing rules', DOCS.rules],
				['Invariants', DOCS.invariants],
				['Architecture decisions', DOCS.adrs]
			]
		},
		{
			h: 'Ecosystem',
			links: [
				['GitHub', REPO],
				['Issues', DOCS.issues],
				['Label dataset', DOCS.labels],
				['Incident fixtures', DOCS.incidents]
			]
		}
	];
</script>

<footer>
	<div class="wrap grid">
		<div class="brand">
			<a href="/" class="name"><Mark size={20} /> ChainGuard</a>
			<p>Real-time on-chain risk monitoring. Read-only by design: no keys, no signing, no transactions.</p>
			<p class="lic">MIT licensed · Detection is advisory; ChainGuard reports risk and never acts on it.</p>
		</div>
		{#each cols as c (c.h)}
			<nav aria-label={c.h}>
				<h2>{c.h}</h2>
				<ul>
					{#each c.links as [label, href] (label)}<li><a {href}>{label}</a></li>{/each}
				</ul>
			</nav>
		{/each}
		<div class="status">
			<h2>Status</h2>
			<p class="state state--{live.mode}">
				<span class="dot" aria-hidden="true"></span>
				{#if live.mode === 'live'}
					Engine reachable
				{:else if live.mode === 'recorded'}
					No engine reachable
				{:else}
					Checking
				{/if}
			</p>
			<p class="small mono">{live.engine || 'localhost:4000'}</p>
			<p class="small">
				{live.mode === 'live' ? 'Stats and terminal are live.' : 'Showing a recorded real run. Start an engine, or pass ?engine=…'}
			</p>
		</div>
	</div>
</footer>

<style>
	footer {
		border-top: 1px solid var(--hairline);
		background: var(--bg-deep);
		padding: 56px 0 40px;
	}
	.grid {
		display: grid;
		grid-template-columns: 1.6fr repeat(3, 1fr) 1.2fr;
		gap: 32px;
	}
	.name {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		font: 600 17px/1 var(--font-display);
		text-decoration: none;
	}
	.brand p {
		color: var(--ink-3);
		font-size: 13.5px;
		max-width: 36ch;
	}
	.lic {
		font-size: 12px !important;
	}
	h2 {
		font: 500 12.5px/1 var(--font-mono);
		letter-spacing: 0.01em;
		color: var(--ink-3);
		margin: 4px 0 14px;
	}
	ul {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		gap: 9px;
	}
	a {
		color: var(--ink-2);
		text-decoration: none;
		font-size: 14px;
	}
	ul a:hover {
		color: var(--ink-1);
	}
	.state {
		display: flex;
		align-items: center;
		gap: 8px;
		margin: 0;
		font-size: 14px;
		color: var(--ink-2);
	}
	.dot {
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--ink-3);
	}
	.state--live .dot {
		background: var(--live);
		box-shadow: 0 0 0 4px var(--live-wash);
	}
	.small {
		color: var(--ink-3);
		font-size: 12px;
		margin: 6px 0 0;
		overflow-wrap: anywhere;
	}
	@media (max-width: 900px) {
		.grid {
			grid-template-columns: repeat(2, minmax(0, 1fr));
		}
		.brand {
			grid-column: 1 / -1;
		}
	}
</style>
