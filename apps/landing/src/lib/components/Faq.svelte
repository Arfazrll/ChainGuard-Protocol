<script lang="ts">
	import { reveal } from '#lib/motion.ts';

	const faqs = [
		{
			q: 'Is the data on this page real?',
			a: 'Yes. In live mode SvlteChain reads Ethereum mainnet from two independent providers. The incidents shown here are real mainnet blocks, captured from two providers and replayed unchanged, and their transaction hashes can be checked on any block explorer. Only the automated tests use made-up data.'
		},
		{
			q: 'How is this different from a block explorer or simple wallet alerts?',
			a: 'Explorers show what happened; SvlteChain decides whether it is dangerous. It verifies every block across independent nodes, understands protocol-level events like flash loans and oracle updates, nets flows per protocol, checks invariants, and attaches the exact evidence to every alert, with a lifecycle that follows chain reorganizations.'
		},
		{
			q: 'Why does it need two nodes?',
			a: 'A single node can lag, sit on a fork, or simply return incomplete data. SvlteChain only accepts a block when a strict majority of at least two independent providers return it identically. It is slower to trust and much harder to fool.'
		},
		{
			q: 'What happens when the chain reorganizes?',
			a: 'Everything stays provisional until its block is final. If a block is replaced, its records are retracted, the canonical ones are processed, and any alert built on the replaced block is retracted and announced as such: PagerDuty incidents resolve and webhooks receive a retraction.'
		},
		{
			q: 'Will the anomaly model wake up my on-call team?',
			a: 'No. Model alerts are capped at medium severity, enforced in the engine. They point a person at something unusual; pages come only from rules and invariants backed by two-node evidence.'
		},
		{
			q: 'Can SvlteChain stop an attack?',
			a: 'No, and deliberately so. It holds no keys and cannot send transactions. What it can do is tell the people who hold a protocol’s pause key within seconds of the block, with the transaction that proves it.'
		},
		{
			q: 'Which chains and protocols are covered?',
			a: 'Ethereum mainnet today, with labeled contracts for major lending markets, exchanges, bridges, stablecoins, oracles and mixers. Each additional chain is a configuration entry and a set of labels; protocols are added by pull request.'
		},
		{
			q: 'How tamper-evident is the audit trail, really?',
			a: 'Every entry is hash-chained and the database refuses edits and deletions. A database superuser could still rewrite the whole history consistently, which is why SvlteChain publishes the latest hash: recorded somewhere else, it makes any later rewrite detectable. It is tamper-evident, not tamper-proof, and we say so.'
		},
		{
			q: 'What does it cost?',
			a: 'SvlteChain is open source under the MIT license and runs on your own infrastructure. Your costs are the machines and the RPC providers you choose; the public providers used in the demo are free but rate-limited.'
		}
	];
</script>

<section id="faq" class="section faq" aria-labelledby="faq-title">
	<div class="narrow" use:reveal>
		<h2 id="faq-title" class="h2" data-reveal>Questions risk teams ask</h2>
		<div class="list" data-reveal>
			{#each faqs as f (f.q)}
				<details>
					<summary>{f.q}<span class="pm" aria-hidden="true"></span></summary>
					<p>{f.a}</p>
				</details>
			{/each}
		</div>
	</div>
</section>

<style>
	.faq {
		background: var(--white);
		border-top: 1px solid var(--rule);
	}
	.list {
		margin-top: 40px;
		border-top: 1px solid var(--rule);
	}
	details {
		border-bottom: 1px solid var(--rule);
	}
	summary {
		display: flex;
		justify-content: space-between;
		gap: 24px;
		padding: 24px 0;
		font-size: 19px;
		font-weight: 500;
		cursor: pointer;
		list-style: none;
	}
	summary::-webkit-details-marker {
		display: none;
	}
	summary:hover {
		color: var(--cobalt);
	}
	.pm {
		position: relative;
		flex: none;
		width: 18px;
		height: 18px;
		margin-top: 4px;
	}
	.pm::before,
	.pm::after {
		content: '';
		position: absolute;
		left: 2px;
		right: 2px;
		top: 8px;
		height: 1.5px;
		background: currentColor;
		transition: transform 0.25s var(--ease);
	}
	.pm::after {
		transform: rotate(90deg);
	}
	details[open] .pm::after {
		transform: rotate(0deg);
	}
	details p {
		margin: 0 0 26px;
		color: var(--ink-2);
		max-width: 68ch;
	}
</style>
