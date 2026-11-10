<script lang="ts">
	import { reveal } from '#lib/motion.ts';

	const teams = [
		{
			id: 'exchanges',
			name: 'Exchanges',
			headline: 'Know where a deposit came from before you credit it.',
			story:
				'When a protocol is exploited, stolen funds usually reach an exchange deposit address within hours. ChainGuard flags the exploit as it happens and flags transfers through labeled mixers, and alerts that touch your own addresses reach only your team, so you can hold a deposit while it is still pending review.',
			setup: ['Watch your hot and deposit wallets', 'Route critical alerts to your on-call rotation', 'Use risk scores to decide which tokens need extra review'],
			gets: ['Alerts when watched addresses touch an exploit or a mixer', 'Evidence your compliance team can attach to a case', 'A record of when you were told, kept in the audit chain'],
			example: { sev: 'low', label: 'Low', text: 'Mixer interaction in a transaction touching a watched deposit address' }
		},
		{
			id: 'funds',
			name: 'Funds and treasuries',
			headline: 'Watch the protocols your positions depend on.',
			story:
				'A position is only as safe as the protocol holding it. ChainGuard checks those protocols on every block: whether their stablecoins hold their pegs, whether their oracles are fresh, whether money is leaving faster than normal, and whether an admin key just changed something.',
			setup: ['Add the contracts you are exposed to', 'Set outflow limits that match your risk appetite', 'Send alerts to the people who can act'],
			gets: ['A 0 to 100 score per protocol, with the reasons', 'High-severity alerts only with two-node evidence', 'Retractions when a chain reorganization undoes an event'],
			example: { sev: 'high', label: 'High', text: 'USDC/USD at $0.9765: 2.35% off its $1.0000 peg' }
		},
		{
			id: 'insurers',
			name: 'Insurers',
			headline: 'Incident evidence that holds up in a claim.',
			story:
				'Underwriting and claims both depend on knowing exactly what happened and when. Every ChainGuard alert carries the transactions, blocks and independent nodes behind it, and its history is hash-chained so it can be shown to be unaltered months later.',
			setup: ['Watch the protocols you cover', 'Export alerts as compliance PDFs', 'Record the audit head in your own systems'],
			gets: ['A timestamped record of each incident and its retractions', 'Reports that re-check the audit chain themselves', 'Scores you can track over the life of a policy'],
			example: { sev: 'critical', label: 'Critical', text: 'Euler Finance net outflow $8,904,507 in a flash-loan transaction' }
		},
		{
			id: 'protocols',
			name: 'Protocol security teams',
			headline: 'Get paged on your own contracts, with proof.',
			story:
				'Your team knows which properties of your protocol must never break. Write them as invariants, add rules for the attacks you fear most, and ChainGuard pages you with the exact transaction when one is hit, so the people holding your pause key can decide in seconds.',
			setup: ['Write invariants and rules as reviewed YAML', 'Route to PagerDuty, Telegram or a webhook', 'Replay past incidents to test before going live'],
			gets: ['Alerts on privileged changes, pauses and drains', 'Each rule isolated: one bad rule cannot stop the rest', 'A read-only monitor that holds no key to your protocol'],
			example: { sev: 'high', label: 'High', text: 'Proxy upgrade on a watched lending pool' }
		}
	];

	let active = $state('exchanges');
	const current = $derived(teams.find((t) => t.id === active)!);

	function onKey(e: KeyboardEvent, i: number) {
		const d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
		if (!d) return;
		e.preventDefault();
		const next = teams[(i + d + teams.length) % teams.length];
		active = next.id;
		document.getElementById(`team-tab-${next.id}`)?.focus();
	}
</script>

<section id="teams" class="teams section" aria-labelledby="teams-title">
	<div class="wrap">
		<div class="section-head" use:reveal>
			<h2 id="teams-title" class="h2" data-reveal>Built for the teams who answer for risk.</h2>
		</div>

		<div class="tabs" role="tablist" aria-label="Teams" use:reveal>
			{#each teams as t, i (t.id)}
				<button
					id="team-tab-{t.id}"
					type="button"
					role="tab"
					aria-selected={active === t.id}
					aria-controls="team-panel"
					tabindex={active === t.id ? 0 : -1}
					onclick={() => (active = t.id)}
					onkeydown={(e) => onKey(e, i)}
					data-reveal
				>{t.name}</button>
			{/each}
		</div>

		{#key active}
			<div id="team-panel" class="panel" role="tabpanel" aria-labelledby="team-tab-{active}">
				<div class="left">
					<h3 class="h3">{current.headline}</h3>
					<p>{current.story}</p>
					<div class="example">
						<span class="ex-k">For example</span>
						<span class="sev sev--{current.example.sev}">{current.example.label}</span>
						<span class="ex-t">{current.example.text}</span>
					</div>
				</div>
				<div class="cols">
					<div>
						<h4>What you set up</h4>
						<ul>{#each current.setup as s (s)}<li>{s}</li>{/each}</ul>
					</div>
					<div>
						<h4>What you get</h4>
						<ul>{#each current.gets as g (g)}<li>{g}</li>{/each}</ul>
					</div>
				</div>
			</div>
		{/key}
	</div>
</section>

<style>
	.teams {
		background: var(--white);
		border-block: 1px solid var(--rule);
	}
	.tabs {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		padding-bottom: 20px;
		border-bottom: 1px solid var(--rule);
	}
	[role='tab'] {
		padding: 10px 18px;
		border: 1px solid var(--rule);
		border-radius: 999px;
		background: var(--white);
		font: 500 15px/1 var(--font);
		color: var(--ink-2);
		cursor: pointer;
		transition:
			background 0.2s var(--ease),
			color 0.2s var(--ease),
			border-color 0.2s var(--ease);
	}
	[role='tab']:hover {
		border-color: #c6cbd2;
	}
	[role='tab'][aria-selected='true'] {
		background: var(--ink);
		border-color: var(--ink);
		color: #fff;
	}
	.panel {
		display: grid;
		grid-template-columns: minmax(0, 1.1fr) minmax(0, 0.9fr);
		gap: clamp(32px, 5vw, 80px);
		padding-top: 44px;
	}
	@media (prefers-reduced-motion: no-preference) {
		.panel {
			animation: fade 0.35s var(--ease);
		}
		@keyframes fade {
			from {
				opacity: 0;
				transform: translateY(6px);
			}
		}
	}
	.left p {
		margin: 18px 0 0;
		color: var(--ink-2);
		font-size: 17.5px;
		line-height: 1.65;
	}
	.example {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 10px;
		margin-top: 28px;
		padding: 16px 18px;
		border-radius: 14px;
		background: var(--paper);
		border: 1px solid var(--rule);
	}
	.ex-k {
		font-size: 13px;
		color: var(--muted);
		width: 100%;
	}
	.ex-t {
		font-weight: 500;
	}
	.cols {
		display: grid;
		gap: 32px;
		align-content: start;
	}
	h4 {
		font-size: 15px;
		font-weight: 600;
		letter-spacing: 0;
		margin-bottom: 12px;
	}
	ul {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		gap: 10px;
	}
	li {
		position: relative;
		padding-left: 26px;
		color: var(--ink-2);
	}
	li::before {
		content: '';
		position: absolute;
		left: 2px;
		top: 0.55em;
		width: 12px;
		height: 7px;
		border-left: 2px solid var(--ok);
		border-bottom: 2px solid var(--ok);
		transform: rotate(-45deg);
	}
	@media (max-width: 900px) {
		.panel {
			grid-template-columns: minmax(0, 1fr);
		}
	}
</style>
