<script lang="ts">
	import { onMount } from 'svelte';
	import { DOCS, REPO, dashboardUrl } from '#lib/config.ts';
	import Mark from './Mark.svelte';

	type Item = { label: string; href: string; desc: string };
	type Menu = { id: string; label: string; groups: { title: string; items: Item[] }[]; feature?: { kicker: string; title: string; desc: string; href: string } };

	const menus: Menu[] = [
		{
			id: 'product',
			label: 'Product',
			groups: [
				{
					title: 'Detection',
					items: [
						{ label: 'Rules', href: '#lanes', desc: 'Known attack shapes, written as reviewable YAML' },
						{ label: 'Invariants', href: '#lanes', desc: 'Pegs, oracle health and outflow limits per protocol' },
						{ label: 'Anomaly detection', href: '#lanes', desc: 'Statistical signals for attacks nobody wrote a rule for' }
					]
				},
				{
					title: 'Platform',
					items: [
						{ label: 'Risk scores', href: '#platform', desc: 'A 0 to 100 health score per protocol, with its reasons' },
						{ label: 'Audit trail', href: '#platform', desc: 'Every decision hash-chained and append-only' },
						{ label: 'Compliance reports', href: '#platform', desc: 'Evidence and lifecycle of an alert as a PDF' }
					]
				}
			],
			feature: {
				kicker: 'Case study',
				title: 'Replaying the Euler Finance exploit',
				desc: 'What ChainGuard raises, step by step, on the March 2023 attack.',
				href: '#case-study'
			}
		},
		{
			id: 'solutions',
			label: 'Solutions',
			groups: [
				{
					title: 'Who uses it',
					items: [
						{ label: 'Exchanges', href: '#teams', desc: 'Screen deposits from exploits and mixers before crediting' },
						{ label: 'Funds and treasuries', href: '#teams', desc: 'Watch the protocols your positions depend on' },
						{ label: 'Insurers', href: '#teams', desc: 'Incident evidence that holds up in a claim' },
						{ label: 'Protocol security teams', href: '#teams', desc: 'Get paged on your own contracts, with proof' }
					]
				}
			]
		},
		{
			id: 'developers',
			label: 'Developers',
			groups: [
				{
					title: 'Build',
					items: [
						{ label: 'Quickstart', href: '#developers', desc: 'Run the whole stack with one command' },
						{ label: 'API reference', href: `${REPO}/blob/main/docs/api.md`, desc: 'Alerts, scores, audit and organization endpoints' },
						{ label: 'Writing rules', href: DOCS.rules, desc: 'The rule format and how to test a rule' }
					]
				},
				{
					title: 'Project',
					items: [
						{ label: 'Source code', href: REPO, desc: 'MIT licensed, on GitHub' },
						{ label: 'Architecture decisions', href: DOCS.adrs, desc: 'Why ChainGuard is built the way it is' },
						{ label: 'Security model', href: '#security', desc: 'What ChainGuard will never do' }
					]
				}
			]
		}
	];

	let open = $state<string | null>(null);
	let sheet = $state(false);
	let scrolled = $state(false);
	let closeTimer: ReturnType<typeof setTimeout> | undefined;

	const show = (id: string) => {
		clearTimeout(closeTimer);
		open = id;
	};
	const hideSoon = () => {
		clearTimeout(closeTimer);
		closeTimer = setTimeout(() => (open = null), 120);
	};

	onMount(() => {
		const onScroll = () => (scrolled = window.scrollY > 8);
		const onKey = (e: KeyboardEvent) => {
			if (e.key === 'Escape') {
				open = null;
				sheet = false;
			}
		};
		onScroll();
		window.addEventListener('scroll', onScroll, { passive: true });
		window.addEventListener('keydown', onKey);
		return () => {
			window.removeEventListener('scroll', onScroll);
			window.removeEventListener('keydown', onKey);
		};
	});

	$effect(() => {
		document.documentElement.style.overflow = sheet ? 'hidden' : '';
	});
</script>

<header class="nav" class:scrolled class:menu-open={open !== null}>
	<div class="bar wrap">
		<a class="brand" href="/" aria-label="ChainGuard home">
			<Mark size={24} />
			<span>ChainGuard</span>
		</a>

		<nav class="menus" aria-label="Main">
			<ul>
				{#each menus as m (m.id)}
					<li onmouseenter={() => show(m.id)} onmouseleave={hideSoon}>
						<button
							type="button"
							class="trigger"
							aria-expanded={open === m.id}
							aria-controls="panel-{m.id}"
							onclick={() => (open = open === m.id ? null : m.id)}
						>
							{m.label}
							<svg class="chev" viewBox="0 0 12 12" aria-hidden="true"><path d="M3 4.5 6 7.5 9 4.5" /></svg>
						</button>
					</li>
				{/each}
				<li><a class="trigger" href={DOCS.readme}>Docs</a></li>
			</ul>
		</nav>

		<div class="actions">
			<a class="gh" href={REPO} aria-label="ChainGuard on GitHub">
				<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8" /></svg>
			</a>
			<a class="btn btn-quiet small" href={dashboardUrl()}>Dashboard</a>
			<a class="btn btn-primary small" href="#developers">Get started</a>
			<button type="button" class="burger" aria-label={sheet ? 'Close menu' : 'Open menu'} aria-expanded={sheet} onclick={() => (sheet = !sheet)}>
				<span></span><span></span>
			</button>
		</div>
	</div>

	{#each menus as m (m.id)}
		<div
			id="panel-{m.id}"
			class="panel"
			class:show={open === m.id}
			role="region"
			aria-label={m.label}
			onmouseenter={() => show(m.id)}
			onmouseleave={hideSoon}
		>
			<div class="panel-inner wrap" class:has-feature={!!m.feature}>
				{#each m.groups as g (g.title)}
					<div class="group">
						<p class="group-title">{g.title}</p>
						<ul>
							{#each g.items as it (it.label)}
								<li>
									<a href={it.href} onclick={() => (open = null)}>
										<span class="it-label">{it.label}</span>
										<span class="it-desc">{it.desc}</span>
									</a>
								</li>
							{/each}
						</ul>
					</div>
				{/each}
				{#if m.feature}
					<a class="feature" href={m.feature.href} onclick={() => (open = null)}>
						<span class="f-kicker">{m.feature.kicker}</span>
						<span class="f-title">{m.feature.title}</span>
						<span class="f-desc">{m.feature.desc}</span>
						<span class="f-art" aria-hidden="true">
							<span class="blk"></span><span class="blk"></span><span class="blk hot"></span><span class="blk"></span>
						</span>
					</a>
				{/if}
			</div>
		</div>
	{/each}
</header>

{#if open}
	<button type="button" class="scrim" aria-label="Close menu" tabindex="-1" onclick={() => (open = null)}></button>
{/if}

{#if sheet}
	<div class="sheet" role="dialog" aria-modal="true" aria-label="Menu">
		<div class="sheet-inner">
			{#each menus as m (m.id)}
				<details>
					<summary>{m.label}</summary>
					{#each m.groups as g (g.title)}
						<ul>
							{#each g.items as it (it.label)}
								<li><a href={it.href} onclick={() => (sheet = false)}>{it.label}<span>{it.desc}</span></a></li>
							{/each}
						</ul>
					{/each}
				</details>
			{/each}
			<a class="sheet-link" href={DOCS.readme}>Docs</a>
			<a class="sheet-link" href={REPO}>GitHub</a>
			<div class="sheet-cta">
				<a class="btn btn-primary" href="#developers" onclick={() => (sheet = false)}>Get started</a>
				<a class="btn btn-quiet" href={dashboardUrl()}>Open the dashboard</a>
			</div>
		</div>
	</div>
{/if}

<style>
	.nav {
		position: sticky;
		top: 0;
		z-index: 50;
		background: rgba(245, 246, 247, 0.82);
		backdrop-filter: saturate(1.6) blur(18px);
		-webkit-backdrop-filter: saturate(1.6) blur(18px);
		border-bottom: 1px solid transparent;
		transition:
			border-color 0.25s var(--ease),
			background 0.25s var(--ease);
	}
	.nav.scrolled,
	.nav.menu-open {
		border-bottom-color: var(--rule);
	}
	.nav.menu-open {
		background: rgba(255, 255, 255, 0.97);
	}
	.bar {
		display: flex;
		align-items: center;
		gap: 28px;
		height: var(--nav-h);
	}
	.brand {
		display: inline-flex;
		align-items: center;
		gap: 10px;
		color: var(--ink);
		font-weight: 600;
		font-size: 17px;
		letter-spacing: -0.01em;
	}
	.brand:hover {
		text-decoration: none;
	}
	.menus ul {
		display: flex;
		gap: 4px;
		margin: 0;
		padding: 0;
		list-style: none;
	}
	.trigger {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		height: 36px;
		padding: 0 12px;
		border: 0;
		border-radius: 8px;
		background: none;
		color: var(--ink-2);
		font: 450 15px/1 var(--font);
		cursor: pointer;
	}
	.trigger:hover,
	.trigger[aria-expanded='true'] {
		color: var(--ink);
		background: rgba(13, 17, 23, 0.05);
		text-decoration: none;
	}
	.chev {
		width: 12px;
		height: 12px;
		fill: none;
		stroke: currentColor;
		stroke-width: 1.5;
		transition: transform 0.2s var(--ease);
	}
	[aria-expanded='true'] .chev {
		transform: rotate(180deg);
	}
	.actions {
		margin-left: auto;
		display: flex;
		align-items: center;
		gap: 10px;
	}
	.gh {
		display: grid;
		place-items: center;
		width: 36px;
		height: 36px;
		border-radius: 8px;
		color: var(--ink-2);
	}
	.gh:hover {
		background: rgba(13, 17, 23, 0.05);
		color: var(--ink);
	}
	.gh svg {
		width: 20px;
		height: 20px;
		fill: currentColor;
	}
	.small {
		min-height: 36px;
		padding: 0 16px;
		font-size: 14.5px;
	}

	/* mega panel */
	.panel {
		position: absolute;
		left: 0;
		right: 0;
		top: 100%;
		background: var(--white);
		border-bottom: 1px solid var(--rule);
		box-shadow: 0 24px 48px -32px rgba(13, 17, 23, 0.28);
		visibility: hidden;
		opacity: 0;
		transform: translateY(-6px);
		transition:
			opacity 0.18s var(--ease),
			transform 0.18s var(--ease),
			visibility 0s linear 0.18s;
	}
	.panel.show {
		visibility: visible;
		opacity: 1;
		transform: none;
		transition:
			opacity 0.18s var(--ease),
			transform 0.18s var(--ease);
	}
	.panel-inner {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(240px, 300px));
		gap: 40px;
		padding: 28px 0 32px;
	}
	.panel-inner.has-feature {
		grid-template-columns: minmax(240px, 300px) minmax(240px, 300px) 1fr;
	}
	.group-title {
		margin: 0 0 10px;
		font-size: 13px;
		font-weight: 500;
		color: var(--muted);
	}
	.group ul {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		gap: 2px;
	}
	.group a {
		display: grid;
		gap: 2px;
		padding: 9px 12px;
		margin-left: -12px;
		border-radius: 10px;
		color: var(--ink);
	}
	.group a:hover {
		background: var(--paper);
		text-decoration: none;
	}
	.it-label {
		font-weight: 500;
		font-size: 15px;
	}
	.it-desc {
		font-size: 13.5px;
		color: var(--graphite);
		line-height: 1.45;
	}
	.feature {
		position: relative;
		display: grid;
		align-content: start;
		gap: 6px;
		padding: 22px;
		border-radius: var(--r);
		background: var(--night);
		color: var(--night-ink);
		overflow: hidden;
		min-height: 190px;
	}
	.feature:hover {
		text-decoration: none;
	}
	.f-kicker {
		font-size: 13px;
		color: var(--night-ink-2);
	}
	.f-title {
		font-size: 19px;
		font-weight: 600;
		letter-spacing: -0.01em;
		max-width: 22ch;
	}
	.f-desc {
		font-size: 14px;
		color: var(--night-ink-2);
		max-width: 34ch;
	}
	.f-art {
		position: absolute;
		right: 22px;
		bottom: 22px;
		display: flex;
		gap: 6px;
	}
	.blk {
		width: 28px;
		height: 18px;
		border-radius: 4px;
		border: 1px solid var(--night-rule);
		background: var(--night-2);
	}
	.blk.hot {
		border-color: var(--signal);
		background: rgba(194, 53, 45, 0.25);
	}
	.scrim {
		position: fixed;
		inset: 0;
		z-index: 40;
		border: 0;
		background: rgba(13, 17, 23, 0.12);
		cursor: default;
	}

	/* mobile */
	.burger {
		display: none;
		width: 40px;
		height: 40px;
		border: 0;
		background: none;
		cursor: pointer;
		position: relative;
	}
	.burger span {
		position: absolute;
		left: 11px;
		right: 11px;
		height: 1.5px;
		background: var(--ink);
		transition: transform 0.2s var(--ease);
	}
	.burger span:first-child {
		top: 16px;
	}
	.burger span:last-child {
		top: 23px;
	}
	.burger[aria-expanded='true'] span:first-child {
		transform: translateY(3.5px) rotate(45deg);
	}
	.burger[aria-expanded='true'] span:last-child {
		transform: translateY(-3.5px) rotate(-45deg);
	}
	.sheet {
		position: fixed;
		inset: var(--nav-h) 0 0 0;
		z-index: 45;
		background: var(--white);
		overflow-y: auto;
	}
	.sheet-inner {
		padding: 12px 24px 40px;
	}
	details {
		border-bottom: 1px solid var(--rule-soft);
	}
	summary {
		padding: 18px 0;
		font-size: 22px;
		font-weight: 600;
		list-style: none;
		cursor: pointer;
	}
	summary::-webkit-details-marker {
		display: none;
	}
	details ul {
		list-style: none;
		margin: 0 0 12px;
		padding: 0;
	}
	details a {
		display: grid;
		padding: 10px 0;
		color: var(--ink);
		font-weight: 500;
	}
	details a span {
		font-weight: 400;
		font-size: 14px;
		color: var(--graphite);
	}
	.sheet-link {
		display: block;
		padding: 18px 0;
		font-size: 22px;
		font-weight: 600;
		color: var(--ink);
		border-bottom: 1px solid var(--rule-soft);
	}
	.sheet-cta {
		display: grid;
		gap: 10px;
		margin-top: 28px;
	}

	@media (max-width: 980px) {
		.menus,
		.actions .btn,
		.gh {
			display: none;
		}
		.burger {
			display: block;
		}
		.panel,
		.scrim {
			display: none;
		}
	}
</style>
