<script lang="ts">
	import { INCIDENT_ALERTS } from '#lib/data/recorded.ts';
	import { etherscanTx, short } from '#lib/format.ts';

	const rule = INCIDENT_ALERTS[0];
</script>

<article class="card glass" aria-label="Example alert, replayed from a real incident">
	<header>
		<span class="sev sev--critical"><i aria-hidden="true">◆</i>Critical</span>
		<span class="lanes">
			<span class="lane">Rule</span><span class="plus" aria-hidden="true">+</span><span class="lane">Invariant</span>
		</span>
	</header>
	<h2 class="title">{rule.title}</h2>
	<dl>
		<div>
			<dt>Transaction</dt>
			<dd class="mono"><a href={etherscanTx(rule.tx!)} rel="noopener" target="_blank">{short(rule.tx!, 10, 6)}</a></dd>
		</div>
		<div>
			<dt>Block</dt>
			<dd class="mono">#{rule.block.toLocaleString('en-US')}</dd>
		</div>
		<div>
			<dt>Evidence</dt>
			<dd><span class="ok" aria-hidden="true">✓</span> 2 independent nodes</dd>
		</div>
		<div>
			<dt>Weakness</dt>
			<dd class="mono">flash-loan-attack</dd>
		</div>
	</dl>
	<div class="flow" aria-hidden="true">
		<span>Aave aDAI</span><i></i><span>exploit</span><i></i><span class="hot">Euler −$8.9M</span>
	</div>
	<footer>Replayed from mainnet: {rule.replay}. Rule and invariant lanes agree on the same tx.</footer>
</article>

<style>
	.card {
		position: relative;
		padding: 20px 22px 18px;
		max-width: 460px;
		margin-left: auto;
		background: var(--glass-strong);
	}
	.card::before {
		content: '';
		position: absolute;
		inset: -1px;
		border-radius: inherit;
		padding: 1px;
		background: linear-gradient(140deg, color-mix(in oklab, var(--sev-critical) 70%, transparent), transparent 40%, var(--brand-wash));
		mask:
			linear-gradient(#000 0 0) content-box,
			linear-gradient(#000 0 0);
		mask-composite: exclude;
		pointer-events: none;
	}
	@media (prefers-reduced-motion: no-preference) {
		.card {
			animation: float 7s ease-in-out infinite;
		}
		@keyframes float {
			50% {
				transform: translateY(-8px);
			}
		}
	}
	header {
		display: flex;
		justify-content: space-between;
		align-items: center;
	}
	.lanes {
		display: inline-flex;
		align-items: center;
		gap: 5px;
	}
	.lane {
		border: 1px solid var(--hairline-strong);
		border-radius: 999px;
		padding: 0 8px;
		font-size: 11.5px;
		line-height: 19px;
		color: var(--ink-2);
	}
	.plus {
		color: var(--ink-3);
		font-size: 11px;
	}
	.title {
		font: 600 17px/1.35 var(--font-ui);
		letter-spacing: -0.01em;
		margin: 14px 0 16px;
	}
	dl {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 12px 18px;
		margin: 0;
	}
	dt {
		color: var(--ink-3);
		font-size: 11.5px;
		margin-bottom: 2px;
	}
	dd {
		margin: 0;
		font-size: 13px;
		color: var(--ink-1);
	}
	dd a {
		color: var(--brand-ink);
		text-decoration: none;
	}
	.ok {
		color: var(--live);
	}
	.flow {
		display: flex;
		align-items: center;
		gap: 6px;
		margin-top: 18px;
		font: 500 11.5px/1 var(--font-mono);
		color: var(--ink-2);
	}
	.flow span {
		padding: 5px 8px;
		border-radius: 6px;
		background: var(--surface-2);
		border: 1px solid var(--hairline);
		white-space: nowrap;
	}
	.flow .hot {
		color: var(--sev-critical);
		border-color: color-mix(in oklab, var(--sev-critical) 45%, transparent);
	}
	.flow i {
		flex: 1;
		height: 1px;
		min-width: 10px;
		background: linear-gradient(90deg, var(--hairline-strong), var(--brand));
	}
	footer {
		margin-top: 16px;
		padding-top: 12px;
		border-top: 1px solid var(--hairline);
		color: var(--ink-3);
		font-size: 12px;
	}
	@media (max-width: 900px) {
		.card {
			margin: 8px auto 0;
		}
	}
</style>
