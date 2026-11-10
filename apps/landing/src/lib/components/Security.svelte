<script lang="ts">
	import { REPO } from '#lib/config.ts';
	import { reveal } from '#lib/motion.ts';

	const never = [
		{ t: 'Hold a private key', d: 'There is no wallet, keystore or signing code in ChainGuard, and the build fails if a signing library is added to the ingestion service.' },
		{ t: 'Sign or send a transaction', d: 'The only process that talks to nodes can call read methods only; anything else is refused before it reaches the network.' },
		{ t: 'Trade on what it sees', d: 'ChainGuard reports risk. It does not front-run, copy or act on detections, so it gives nobody a way to profit from an alert.' },
		{ t: 'Trust a single node', d: 'High and critical alerts need evidence attested by at least two independent nodes; otherwise they are capped at medium.' }
	];

	const enforced = [
		{ p: 'Read-only', how: 'Build fails if a signing or wallet dependency appears, or if the RPC allowlist check is removed' },
		{ p: 'Two-node evidence', how: 'Tests for forged answers, dropped logs and disagreeing nodes must pass' },
		{ p: 'Reorg safety', how: 'Reorg suite plus a reorg on a real test chain in CI' },
		{ p: 'Tamper-evident audit', how: 'Database triggers must exist; tamper tests must pass' },
		{ p: 'No false urgency', how: 'Dedup, rate-limit and ML severity-ceiling tests must pass' },
		{ p: 'Tenant isolation', how: 'Cross-organization access tests must pass' }
	];
</script>

<section id="security" class="chapter-dark section" aria-labelledby="security-title">
	<div class="wrap">
		<div class="section-head" use:reveal>
			<h2 id="security-title" class="h2" data-reveal>If ChainGuard is breached, there is nothing to steal.</h2>
			<p class="lead" data-reveal>
				A monitor that can move funds is a target. ChainGuard is built so that it cannot: it observes and reports, and
				the rules below are checked automatically before any change is merged.
			</p>
		</div>

		<div class="grid" use:reveal>
			<div data-reveal>
				<h3 class="sub">What ChainGuard will never do</h3>
				<ul class="never">
					{#each never as n (n.t)}
						<li>
							<span class="x" aria-hidden="true"></span>
							<div><strong>{n.t}</strong><p>{n.d}</p></div>
						</li>
					{/each}
				</ul>
			</div>
			<div data-reveal>
				<h3 class="sub">Enforced on every pull request</h3>
				<table>
					<thead><tr><th>Property</th><th>How the build enforces it</th></tr></thead>
					<tbody>
						{#each enforced as e (e.p)}
							<tr><td>{e.p}</td><td>{e.how}</td></tr>
						{/each}
					</tbody>
				</table>
				<p class="foot">
					The guard itself was tested by deliberately breaking several of these protections and checking that the
					build failed. <a href="{REPO}/blob/main/scripts/check-invariants.sh">Read the guard</a>
				</p>
			</div>
		</div>
	</div>
</section>

<style>
	.grid {
		display: grid;
		grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
		gap: clamp(32px, 5vw, 72px);
	}
	.sub {
		font-size: 17px;
		font-weight: 600;
		letter-spacing: 0;
		margin-bottom: 18px;
		color: var(--night-ink);
	}
	.never {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		gap: 4px;
	}
	.never li {
		display: grid;
		grid-template-columns: 28px 1fr;
		gap: 14px;
		padding: 18px 0;
		border-top: 1px solid var(--night-rule);
	}
	.x {
		position: relative;
		width: 22px;
		height: 22px;
		border-radius: 50%;
		border: 1px solid #5a2a2a;
		margin-top: 2px;
	}
	.x::before,
	.x::after {
		content: '';
		position: absolute;
		left: 5px;
		right: 5px;
		top: 10px;
		height: 1.5px;
		background: #ff8a80;
		transform: rotate(45deg);
	}
	.x::after {
		transform: rotate(-45deg);
	}
	.never strong {
		font-weight: 600;
		color: var(--night-ink);
	}
	.never p {
		margin: 4px 0 0;
		color: var(--night-ink-2);
		font-size: 15.5px;
	}
	table {
		width: 100%;
		border-collapse: collapse;
		font-size: 15px;
	}
	th {
		text-align: left;
		font-weight: 500;
		font-size: 13.5px;
		color: var(--night-ink-2);
		padding: 0 12px 12px 0;
		border-bottom: 1px solid var(--night-rule);
	}
	td {
		padding: 15px 12px 15px 0;
		border-bottom: 1px solid var(--night-rule);
		color: var(--night-ink-2);
		vertical-align: top;
	}
	td:first-child {
		color: var(--night-ink);
		font-weight: 500;
		white-space: nowrap;
	}
	.foot {
		margin: 18px 0 0;
		color: var(--night-ink-2);
		font-size: 15px;
	}
	@media (max-width: 900px) {
		.grid {
			grid-template-columns: minmax(0, 1fr);
		}
	}
</style>
