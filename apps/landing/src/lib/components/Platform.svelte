<script lang="ts">
	import { REPO } from '#lib/config.ts';
	import { reveal } from '#lib/motion.ts';

	const scores = [
		{ p: 'Euler Finance', s: 0, band: 'Critical', why: '2 critical alerts, outflow invariant broken', tone: 'crit' },
		{ p: 'Circle (USDC)', s: 45, band: 'High', why: '1 high alert, peg invariant broken', tone: 'high' },
		{ p: 'Aave', s: 100, band: 'Low', why: 'No open alerts; lent and was repaid', tone: 'ok' },
		{ p: 'Compound V3', s: 100, band: 'Low', why: 'No open alerts', tone: 'ok' }
	];
</script>

<section id="platform" class="section" aria-labelledby="platform-title">
	<div class="wrap">
		<div class="section-head" use:reveal>
			<h2 id="platform-title" class="h2" data-reveal>From alert to answer. <span class="soft">Scores, records and reports your risk and compliance teams can use.</span></h2>
		</div>

		<div class="bento" use:reveal>
			<article class="tile risk" data-reveal>
				<div class="tcopy">
					<h3>Risk scores with their reasons</h3>
					<p>
						Every protocol gets a health score from 0 to 100. Open alerts and broken invariants lower it, older alerts
						count less over time, and every point is explained. No black box: the same inputs always give the same score.
					</p>
				</div>
				<ul class="scores">
					{#each scores as s (s.p)}
						<li class="tone--{s.tone}">
							<span class="pn">{s.p}</span>
							<span class="sv">{s.s}</span>
							<span class="bd">{s.band}</span>
							<span class="meter" aria-hidden="true"><span style="width:{Math.max(2, s.s)}%"></span></span>
							<span class="why">{s.why}</span>
						</li>
					{/each}
				</ul>
			</article>

			<article class="tile audit" data-reveal>
				<div class="tcopy">
					<h3>A record nobody can quietly edit</h3>
					<p>
						Each alert event and score change is appended to a hash chain in PostgreSQL. The database refuses edits and
						deletions, and one call re-checks the whole history.
					</p>
				</div>
				<pre class="code"><code><span class="c">$ curl localhost:4000/api/audit/verify</span>
{'{'}
  "valid": true,
  "entries": 15,
  "head": "24eb8810b0892f18…5191908"
{'}'}</code></pre>
			</article>

			<article class="tile report" data-reveal>
				<div class="tcopy">
					<h3>Reports that stand on their own</h3>
					<p>
						One click turns an alert into a PDF: the evidence, the nodes that attested it, its history in the audit chain,
						and the report’s own re-check of every hash.
					</p>
				</div>
				<div class="paper" aria-hidden="true">
					<img src="/media/report.png" alt="" loading="lazy" width="800" height="976" />
				</div>
			</article>

			<article class="tile tenants" data-reveal>
				<div class="tcopy">
					<h3>One deployment, many teams</h3>
					<p>
						Chain data is public; what each organization watches and where its alerts go is not. Every team gets its own
						keys, roles, watchlist and alert routes, and never sees another team’s.
					</p>
				</div>
				<div class="orgs" aria-hidden="true">
					<div class="org">
						<span class="on">Acme Exchange</span>
						<span class="w">Watching 14 addresses</span>
						<span class="r">Routes to PagerDuty</span>
					</div>
					<div class="wall"></div>
					<div class="org">
						<span class="on">Beta Fund</span>
						<span class="w">Watching 6 addresses</span>
						<span class="r">Routes to its own webhook</span>
					</div>
				</div>
			</article>

			<article class="tile api" data-reveal>
				<div class="tcopy">
					<h3>Everything has an API</h3>
					<p>Alerts, scores, the audit chain and your organization’s configuration, over REST and live WebSocket channels.</p>
					<a href="{REPO}/blob/main/docs/api.md">API reference</a>
				</div>
				<pre class="code"><code><span class="c">GET /api/scores/euler</span>
{'{'} "protocol": "euler", "score": 0,
  "band": "critical", "confidence": "high",
  "model": "risk-v1" {'}'}</code></pre>
			</article>
		</div>
	</div>
</section>

<style>
	.bento {
		display: grid;
		grid-template-columns: repeat(6, minmax(0, 1fr));
		gap: 16px;
	}
	.tile {
		display: grid;
		align-content: space-between;
		gap: 24px;
		padding: clamp(24px, 3vw, 36px);
		border-radius: 24px;
		background: var(--white);
		border: 1px solid var(--rule);
		overflow: hidden;
		transition:
			border-color 0.25s var(--ease),
			transform 0.25s var(--ease);
	}
	.tile:hover {
		border-color: #c6cbd2;
	}
	.risk {
		grid-column: span 4;
	}
	.audit {
		grid-column: span 2;
	}
	.report {
		grid-column: span 2;
		grid-row: span 2;
	}
	.tenants {
		grid-column: span 4;
	}
	.api {
		grid-column: span 4;
	}
	h3 {
		font-size: 22px;
		letter-spacing: -0.015em;
		margin-bottom: 10px;
	}
	.tcopy p {
		margin: 0;
		color: var(--ink-2);
		font-size: 16px;
		max-width: 56ch;
	}
	.tcopy a {
		display: inline-block;
		margin-top: 12px;
		font-weight: 500;
	}
	.scores {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		gap: 4px;
	}
	.scores li {
		display: grid;
		grid-template-columns: 1fr 44px 84px;
		grid-template-areas: 'pn sv bd' 'meter meter meter' 'why why why';
		gap: 4px 12px;
		align-items: baseline;
		padding: 12px 0;
		border-top: 1px solid var(--rule-soft);
	}
	.pn {
		grid-area: pn;
		font-weight: 500;
	}
	.sv {
		grid-area: sv;
		text-align: right;
		font-weight: 600;
		font-size: 20px;
		font-variant-numeric: tabular-nums;
	}
	.bd {
		grid-area: bd;
		font-size: 14px;
		font-weight: 500;
		color: var(--ok);
	}
	.meter {
		grid-area: meter;
		height: 4px;
		border-radius: 4px;
		background: var(--rule-soft);
		overflow: hidden;
	}
	.meter span {
		display: block;
		height: 100%;
		border-radius: 4px;
		background: var(--ok);
	}
	.why {
		grid-area: why;
		font-size: 14px;
		color: var(--graphite);
	}
	.tone--crit .bd {
		color: var(--signal);
	}
	.tone--crit .meter span {
		background: var(--signal);
	}
	.tone--high .bd {
		color: #b3461b;
	}
	.tone--high .meter span {
		background: #d0682f;
	}
	.code {
		margin: 0;
		padding: 18px 20px;
		border-radius: 14px;
		background: var(--night);
		color: #d6dbe2;
		font: 13.5px/1.6 var(--mono);
		overflow-x: auto;
	}
	.code .c {
		color: #8b95a3;
	}
	.paper {
		margin: 0 -8px -60px;
		border-radius: 12px 12px 0 0;
		border: 1px solid var(--rule);
		box-shadow: 0 20px 40px -24px rgba(13, 17, 23, 0.3);
		overflow: hidden;
		transform: rotate(-2deg) translateY(4px);
		transition: transform 0.4s var(--ease);
	}
	.report:hover .paper {
		transform: rotate(0deg) translateY(-6px);
	}
	.paper img {
		width: 100%;
		height: auto;
	}
	.orgs {
		display: grid;
		grid-template-columns: 1fr 1px 1fr;
		gap: 24px;
		align-items: stretch;
	}
	.org {
		display: grid;
		gap: 6px;
		padding: 18px;
		border-radius: 14px;
		background: var(--paper);
		border: 1px solid var(--rule);
	}
	.on {
		font-weight: 600;
	}
	.w,
	.r {
		font-size: 14px;
		color: var(--graphite);
	}
	.wall {
		background: repeating-linear-gradient(180deg, var(--rule) 0 6px, transparent 6px 12px);
	}
	@media (max-width: 1000px) {
		.risk,
		.tenants,
		.api {
			grid-column: span 6;
		}
		.audit,
		.report {
			grid-column: span 3;
			grid-row: auto;
		}
	}
	@media (max-width: 680px) {
		.audit,
		.report {
			grid-column: span 6;
		}
		.orgs {
			grid-template-columns: 1fr;
		}
		.wall {
			height: 1px;
		}
	}
</style>
