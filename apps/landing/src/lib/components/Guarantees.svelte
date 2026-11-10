<script lang="ts">
	import { onMount } from 'svelte';
	import { reveal } from '#lib/motion.ts';

	const steps = [
		{
			title: 'Every block, confirmed twice',
			body: [
				'SvlteChain asks at least two independent RPC providers for each block: its header and its complete set of event logs. It only moves on when a strict majority returns them identically, byte for byte.',
				'A node that lags, forks or quietly drops a log is outvoted. If there is no majority, ingestion stops instead of guessing, and the dashboard says why.'
			],
			note: 'While collecting this project’s own test data, one public RPC returned an empty answer for a block range that held 21 Chainlink price updates. A monitor reading from that single node would have missed the start of the USDC depeg.'
		},
		{
			title: 'Provisional until it is final',
			body: [
				'The newest blocks on a chain can still be replaced by a reorganization. SvlteChain emits records right away but marks them provisional until their block is 64 blocks deep, about 13 minutes on Ethereum.',
				'If a block is orphaned, its records are retracted, the canonical ones are emitted, and every alert built on the orphaned block is retracted too. PagerDuty incidents resolve and webhooks receive the retraction.'
			],
			note: 'A fork deeper than finality is never papered over: ingestion halts and raises a critical alert about itself.'
		},
		{
			title: 'Three lanes, one verdict',
			body: [
				'Each block is checked three ways at once. Rules match attack shapes that are already known. Invariants check properties a protocol must always keep. A statistical model flags what nobody has written a rule for yet.',
				'Every rule and every invariant runs in its own supervised process. If one of them crashes on bad data, only that one restarts, and detection keeps going.'
			],
			note: 'On the Euler exploit, the rule lane and the invariant lane raised critical alerts on the same transaction independently, and the model flagged it as well.'
		},
		{
			title: 'Every decision on the record',
			body: [
				'Each alert event and each change to a risk score is written to an append-only log in PostgreSQL. Every entry’s hash covers its contents and the hash of the entry before it, so the log forms a chain.',
				'The database refuses edits and deletions. Anyone who bypasses that and changes an entry breaks the chain at that point, and verification reports exactly where.'
			],
			note: 'The latest hash can be published or recorded outside SvlteChain, which makes rewriting history after that point detectable as well.'
		}
	];

	let active = $state(0);
	let stepEls: HTMLElement[] = [];

	onMount(() => {
		const io = new IntersectionObserver(
			(entries) => {
				for (const e of entries) if (e.isIntersecting) active = Number((e.target as HTMLElement).dataset.step);
			},
			{ rootMargin: '-45% 0px -45% 0px' }
		);
		stepEls.forEach((el) => io.observe(el));
		return () => io.disconnect();
	});
</script>

{#snippet visual(i: number)}
	{#if i === 0}
		<div class="v v-quorum">
			<div class="vhead">Block 26,383,012</div>
			<div class="node ok"><span class="nm">publicnode</span><span class="mono">0xcd02…90a5</span><span class="st">agrees</span></div>
			<div class="node ok"><span class="nm">drpc</span><span class="mono">0xcd02…90a5</span><span class="st">agrees</span></div>
			<div class="node bad"><span class="nm">a lagging node</span><span class="mono">no logs</span><span class="st">outvoted</span></div>
			<div class="verdict">Strict majority reached: 2 of 3. Block accepted.</div>
		</div>
	{:else if i === 1}
		<div class="v v-reorg">
			<div class="chainrow">
				<span class="b">h-2</span><span class="ln"></span><span class="b">h-1</span><span class="ln"></span><span class="b orphan">h</span>
			</div>
			<div class="chainrow fork">
				<span class="b ghost"></span><span class="ln ghost"></span><span class="b ghost"></span><span class="ln up"></span><span class="b canon">h′</span><span class="ln"></span><span class="b canon">h+1</span>
			</div>
			<ul class="events">
				<li><span class="tag">orphaned</span> block h, replaced by h′</li>
				<li><span class="tag">retracted</span> 1 alert built on block h</li>
				<li><span class="tag ok">final</span> after 64 confirmations</li>
			</ul>
		</div>
	{:else if i === 2}
		<div class="v v-lanes">
			<div class="lane"><span class="ln-name">Rules</span><span class="ln-bar"></span><span class="sev sev--critical">Critical</span></div>
			<div class="lane"><span class="ln-name">Invariants</span><span class="ln-bar"></span><span class="sev sev--critical">Critical</span></div>
			<div class="lane"><span class="ln-name">Model</span><span class="ln-bar"></span><span class="sev sev--medium">Medium</span></div>
			<div class="verdict">Euler Finance, tx 0xc310…111d: three independent signals on one transaction.</div>
		</div>
	{:else}
		<div class="v v-audit">
			<!-- Real entries from the incident replay behind the sample report. -->
			{#each [{ s: 10, h: '5a78…4645', k: 'previous entry' }, { s: 11, h: '91c3…3243', k: 'alert.raised' }, { s: 15, h: '24eb…1908', k: 'head (latest)' }] as e, j (e.s)}
				<div class="entry">
					<span class="seq">#{e.s}</span><span class="kind">{e.k}</span><span class="mono h">{e.h}</span>
				</div>
				{#if j < 2}<div class="link" aria-hidden="true"></div>{/if}
			{/each}
			<div class="verdict">Entries 12 to 14 not shown. Verified: 15 entries, every link intact.</div>
		</div>
	{/if}
{/snippet}

<section id="how" class="chapter-dark section" aria-labelledby="how-title">
	<div class="wrap">
		<div class="section-head" use:reveal>
			<h2 id="how-title" class="h2" data-reveal>Built on four guarantees. <span class="soft">Each one enforced in code and checked on every change.</span></h2>
		</div>
		<div class="layout">
			<div class="stage" aria-hidden="true">
				<div class="stage-inner">
					{#each steps as _, i (i)}
						<div class="frame" class:on={active === i}>{@render visual(i)}</div>
					{/each}
				</div>
			</div>
			<ol class="steps">
				{#each steps as s, i (s.title)}
					<li class="step" class:on={active === i} data-step={i} bind:this={stepEls[i]}>
						<span class="n">{i + 1}</span>
						<h3 class="h3">{s.title}</h3>
						{#each s.body as para (para)}<p>{para}</p>{/each}
						<p class="note">{s.note}</p>
						<div class="inline-visual" aria-hidden="true">{@render visual(i)}</div>
					</li>
				{/each}
			</ol>
		</div>
	</div>
</section>

<style>
	.layout {
		display: grid;
		grid-template-columns: minmax(0, 1fr) minmax(0, 0.9fr);
		gap: clamp(40px, 6vw, 96px);
	}
	.stage {
		position: relative;
	}
	.stage-inner {
		position: sticky;
		top: calc(var(--nav-h) + 12vh);
		height: 440px;
	}
	.frame {
		position: absolute;
		inset: 0;
		opacity: 0;
		transform: translateY(12px) scale(0.985);
		transition:
			opacity 0.5s var(--ease),
			transform 0.5s var(--ease);
		pointer-events: none;
	}
	.frame.on {
		opacity: 1;
		transform: none;
	}
	.steps {
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.step {
		min-height: 74vh;
		padding: 8vh 0;
		color: var(--night-ink-2);
		transition: color 0.4s var(--ease);
	}
	.step:first-child {
		padding-top: 0;
	}
	.step.on {
		color: var(--night-ink);
	}
	.n {
		display: inline-grid;
		place-items: center;
		width: 30px;
		height: 30px;
		border-radius: 50%;
		border: 1px solid var(--night-rule);
		font-size: 14px;
		color: var(--night-ink-2);
		margin-bottom: 18px;
	}
	.step.on .n {
		border-color: var(--night-ink);
		color: var(--night-ink);
	}
	.step h3 {
		color: var(--night-ink);
		margin-bottom: 16px;
	}
	.step p {
		margin: 0 0 14px;
		font-size: 17.5px;
		line-height: 1.65;
		max-width: 56ch;
	}
	.note {
		padding: 14px 16px;
		border-radius: 10px;
		background: var(--night-2);
		border: 1px solid var(--night-rule);
		font-size: 15px !important;
		color: var(--night-ink-2);
	}
	.inline-visual {
		display: none;
	}

	/* visuals */
	.v {
		height: 100%;
		display: grid;
		align-content: center;
		gap: 12px;
		padding: 32px;
		border-radius: var(--r-lg);
		background: linear-gradient(180deg, var(--night-2), #12171e);
		border: 1px solid var(--night-rule);
		font-size: 15px;
		color: var(--night-ink);
	}
	.vhead {
		color: var(--night-ink-2);
		font-size: 14px;
	}
	.node {
		display: grid;
		grid-template-columns: 1fr auto auto;
		gap: 16px;
		align-items: center;
		padding: 14px 16px;
		border-radius: 12px;
		background: var(--night);
		border: 1px solid var(--night-rule);
	}
	.node .mono {
		color: var(--night-ink-2);
	}
	.st {
		font-size: 13px;
		font-weight: 500;
	}
	.node.ok .st {
		color: #7fd0a0;
	}
	.node.bad {
		opacity: 0.7;
	}
	.node.bad .st {
		color: #ff8a80;
	}
	.verdict {
		margin-top: 8px;
		color: var(--night-ink-2);
		font-size: 14px;
	}
	.chainrow {
		display: flex;
		align-items: center;
	}
	.b {
		display: grid;
		place-items: center;
		width: 64px;
		height: 44px;
		border-radius: 10px;
		background: var(--night);
		border: 1px solid #3a4350;
		font-size: 14px;
	}
	.b.orphan {
		border-style: dashed;
		color: var(--night-ink-2);
		text-decoration: line-through;
	}
	.b.canon {
		border-color: #7fd0a0;
	}
	.b.ghost,
	.ln.ghost {
		visibility: hidden;
	}
	.ln {
		width: 26px;
		height: 1px;
		background: #3a4350;
	}
	.ln.up {
		position: relative;
		width: 26px;
		background: none;
	}
	.ln.up::before {
		content: '';
		position: absolute;
		left: 0;
		bottom: 22px;
		width: 37px;
		height: 1px;
		background: #7fd0a0;
		transform: rotate(-50deg);
		transform-origin: left bottom;
	}
	.fork {
		margin-top: 14px;
	}
	.events {
		list-style: none;
		margin: 18px 0 0;
		padding: 0;
		display: grid;
		gap: 8px;
		color: var(--night-ink-2);
		font-size: 14px;
	}
	.tag {
		display: inline-block;
		min-width: 76px;
		margin-right: 8px;
		color: #ff8a80;
	}
	.tag.ok {
		color: #7fd0a0;
	}
	.lane {
		display: grid;
		grid-template-columns: 96px 1fr auto;
		gap: 14px;
		align-items: center;
		padding: 16px;
		border-radius: 12px;
		background: var(--night);
		border: 1px solid var(--night-rule);
	}
	.ln-bar {
		height: 2px;
		background: linear-gradient(90deg, #3a4350, #6b7686);
	}
	.entry {
		display: grid;
		grid-template-columns: 52px 1fr auto;
		gap: 14px;
		align-items: center;
		padding: 14px 16px;
		border-radius: 12px;
		background: var(--night);
		border: 1px solid var(--night-rule);
	}
	.seq {
		color: var(--night-ink-2);
	}
	.h {
		color: var(--night-ink-2);
		font-size: 13px;
	}
	.link {
		width: 1px;
		height: 14px;
		margin: -6px 0 -6px 41px;
		background: #7fd0a0;
	}

	@media (max-width: 900px) {
		.layout {
			grid-template-columns: minmax(0, 1fr);
		}
		.stage {
			display: none;
		}
		.step {
			min-height: 0;
			padding: 0 0 56px;
			color: var(--night-ink);
		}
		.inline-visual {
			display: block;
			margin-top: 20px;
		}
		.inline-visual .v {
			height: auto;
			padding: 22px;
		}
		.b {
			width: 48px;
			height: 38px;
		}
		.ln {
			width: 14px;
		}
		.ln.up::before {
			width: 27px;
			bottom: 18px;
		}
	}
</style>
