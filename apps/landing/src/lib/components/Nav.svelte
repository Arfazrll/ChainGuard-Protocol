<script lang="ts">
	import { DOCS, REPO } from '#lib/config.ts';
	import { live } from '#lib/live.svelte.ts';
	import Mark from './Mark.svelte';
</script>

<header class="nav">
	<div class="wrap row">
		<a class="brand" href="/" aria-label="ChainGuard home"><Mark /> ChainGuard</a>
		<nav aria-label="Sections">
			<a href="#how">How it works</a>
			<a href="#lanes">Detection</a>
			<a href="#builders">Builders</a>
			<a href={DOCS.readme}>Docs</a>
		</nav>
		<span class="status status--{live.mode}" role="status">
			<span class="dot" aria-hidden="true"></span>
			{live.mode === 'live' ? 'Live engine' : live.mode === 'recorded' ? 'Recorded data' : 'Checking'}
		</span>
		<a class="gh" href={REPO}>GitHub</a>
	</div>
</header>

<style>
	.nav {
		position: sticky;
		top: 0;
		z-index: 20;
		background: color-mix(in oklab, var(--bg) 72%, transparent);
		backdrop-filter: blur(14px);
		-webkit-backdrop-filter: blur(14px);
		border-bottom: 1px solid var(--hairline);
	}
	.row {
		display: flex;
		align-items: center;
		gap: 22px;
		height: 60px;
	}
	.brand {
		display: inline-flex;
		align-items: center;
		gap: 9px;
		font: 600 17px/1 var(--font-display);
		letter-spacing: -0.02em;
		text-decoration: none;
		margin-right: auto;
	}
	nav {
		display: flex;
		gap: 22px;
	}
	nav a,
	.gh {
		color: var(--ink-2);
		text-decoration: none;
		font-size: 14px;
		transition: color 0.2s;
	}
	nav a:hover,
	.gh:hover {
		color: var(--ink-1);
	}
	.gh {
		padding: 7px 14px;
		border: 1px solid var(--hairline-strong);
		border-radius: 999px;
	}
	.status {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		color: var(--ink-3);
		font: 500 12px/1 var(--font-mono);
	}
	.dot {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--ink-3);
	}
	.status--live {
		color: var(--live);
	}
	.status--live .dot {
		background: var(--live);
		box-shadow: 0 0 0 4px var(--live-wash);
	}
	@media (max-width: 860px) {
		nav {
			display: none;
		}
	}
	@media (max-width: 420px) {
		.status {
			display: none;
		}
	}
</style>
