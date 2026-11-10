<script lang="ts">
	import { DOCS, REPO } from '#lib/config.ts';
	import { reveal } from '#lib/motion.ts';

	const tabs = [
		{
			id: 'native',
			label: 'One command',
			intro: 'Starts ingestion, the engine, the model and report services and the dashboard on your machine. --replay plays back the real incidents, so you see alerts within a minute without an RPC endpoint.',
			code: 'git clone https://github.com/Arfazrll/ChainGuard-Protocol\ncd ChainGuard-Protocol\nscripts/up.sh --replay\n\n# Dashboard   http://localhost:4300\n# Stop        scripts/down.sh',
			needs: 'Needs Rust, Elixir, Python with uv, Node and PostgreSQL.'
		},
		{
			id: 'docker',
			label: 'Docker',
			intro: 'The same stack in containers, with PostgreSQL included. The live profile adds Redpanda and ingestion from two RPC providers of your choice.',
			code: 'docker compose -f deploy/compose/docker-compose.yml up --build\n\n# Live Ethereum mainnet instead of the replay\nexport CHAINGUARD_RPC_A=https://ethereum-rpc.publicnode.com\nexport CHAINGUARD_RPC_B=https://eth.drpc.org\nCHAINGUARD_SOURCE=kafka docker compose \\\n  -f deploy/compose/docker-compose.yml --profile live up --build',
			needs: 'Needs Docker with Compose.'
		},
		{
			id: 'api',
			label: 'API',
			intro: 'Public chain data needs no key. Organization endpoints take an API key with a role: viewer, analyst or admin.',
			code: 'curl localhost:4000/api/alerts?limit=5\ncurl localhost:4000/api/scores/euler\ncurl localhost:4000/api/audit/verify\n\n# Your organization\ncurl -H "authorization: Bearer $CHAINGUARD_KEY" \\\n  localhost:4000/api/org/alerts',
			needs: 'Full reference in docs/api.md.'
		},
		{
			id: 'rule',
			label: 'Write a rule',
			intro: 'A rule is a YAML file. It is validated when the engine starts, runs in its own process, and should come with a positive and a negative test.',
			code: 'id: emergency-pause\nseverity: high\nweakness: { class: centralization-risk }\nscope: record\nmatch:\n  kind: paused\n  label.contract: { exists: true }\ntitle: "{{label.contract.name}} was paused by {{event.account|short}}"',
			needs: 'Format and examples in docs/rules.md.'
		}
	];

	let active = $state('native');
	let copied = $state(false);
	const current = $derived(tabs.find((t) => t.id === active)!);

	async function copy() {
		try {
			await navigator.clipboard.writeText(current.code);
			copied = true;
			setTimeout(() => (copied = false), 1600);
		} catch {
			copied = false;
		}
	}

	const measured = [
		{ what: 'Rules and invariants per block', value: '267 ms', cond: 'p50 over 45 live mainnet blocks, about 1,100 records each', fn: 5 },
		{ what: 'Record derived to rules evaluated', value: '~530–600 ms', cond: 'p50, one development machine, file tail polling every 250 ms', fn: 5 },
		{ what: 'Model false positives', value: '2 of ~15,500', cond: 'Transactions in the 200 real blocks before the Euler exploit', fn: 3 },
		{ what: 'One-command start', value: '63 s', cond: 'All services healthy with replayed alerts, warm build caches', fn: 6 },
		{ what: 'Block time to alert', value: 'Not measured', cond: 'The test machine’s clock was 117 s behind; SvlteChain withheld the figure', fn: 5 }
	];
</script>

<section id="developers" class="section" aria-labelledby="dev-title">
	<div class="wrap">
		<div class="section-head" use:reveal>
			<h2 id="dev-title" class="h2" data-reveal>Run it yourself. <span class="soft">Open source, MIT licensed, on your own infrastructure.</span></h2>
		</div>

		<div class="dev" use:reveal>
			<div class="console" data-reveal>
				<div class="tabs" role="tablist" aria-label="Ways to start">
					{#each tabs as t (t.id)}
						<button type="button" role="tab" aria-selected={active === t.id} aria-controls="dev-panel" onclick={() => (active = t.id)}>{t.label}</button>
					{/each}
				</div>
				<div id="dev-panel" role="tabpanel" class="body">
					<p class="intro">{current.intro}</p>
					<div class="codewrap">
						<pre><code>{current.code}</code></pre>
						<button type="button" class="copy" onclick={copy} aria-live="polite">{copied ? 'Copied' : 'Copy'}</button>
					</div>
					<p class="needs">{current.needs}</p>
				</div>
			</div>

			<div class="links" data-reveal>
				<a href={`${REPO}/blob/main/docs/api.md`}><strong>API reference</strong><span>Alerts, scores, audit and organization endpoints</span></a>
				<a href={DOCS.rules}><strong>Detection rules</strong><span>Format, predicates and how to test a rule</span></a>
				<a href={DOCS.invariants}><strong>Invariant monitors</strong><span>Pegs, oracle health and outflow limits</span></a>
				<a href={DOCS.adrs}><strong>Architecture decisions</strong><span>Why each part is built the way it is</span></a>
			</div>
		</div>

		<div class="measured" use:reveal>
			<h3 class="h3" data-reveal>Measured, not promised</h3>
			<p class="mlead" data-reveal>Every number on this page comes from a test or a recorded run. Where a figure could not be measured honestly, it says so.</p>
			<table data-reveal>
				<thead><tr><th>What</th><th>Result</th><th>Conditions</th></tr></thead>
				<tbody>
					{#each measured as m (m.what)}
						<tr>
							<td>{m.what}</td>
							<td class="val">{m.value}</td>
							<td>{m.cond}<a class="fn" href="#fn-{m.fn}" aria-label="Footnote {m.fn}">{m.fn}</a></td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	</div>
</section>

<style>
	.dev {
		display: grid;
		grid-template-columns: minmax(0, 1.5fr) minmax(0, 1fr);
		gap: 24px;
		align-items: start;
	}
	.console {
		border-radius: 24px;
		background: var(--white);
		border: 1px solid var(--rule);
		overflow: hidden;
	}
	.tabs {
		display: flex;
		gap: 2px;
		padding: 8px;
		border-bottom: 1px solid var(--rule);
		overflow-x: auto;
	}
	[role='tab'] {
		flex: none;
		padding: 9px 16px;
		border: 0;
		border-radius: 10px;
		background: none;
		font: 500 15px/1 var(--font);
		color: var(--graphite);
		cursor: pointer;
	}
	[role='tab']:hover {
		color: var(--ink);
	}
	[role='tab'][aria-selected='true'] {
		background: var(--paper);
		color: var(--ink);
	}
	.body {
		padding: 24px;
	}
	.intro {
		margin: 0 0 18px;
		color: var(--ink-2);
	}
	.codewrap {
		position: relative;
	}
	pre {
		margin: 0;
		padding: 20px 22px;
		border-radius: 14px;
		background: var(--night);
		color: #d6dbe2;
		font: 14px/1.7 var(--mono);
		overflow-x: auto;
		min-height: 210px;
	}
	.copy {
		position: absolute;
		top: 12px;
		right: 12px;
		padding: 6px 12px;
		border-radius: 8px;
		border: 1px solid #333b46;
		background: #1a2029;
		color: #d6dbe2;
		font: 500 13px/1 var(--font);
		cursor: pointer;
	}
	.copy:hover {
		background: #232a35;
	}
	.needs {
		margin: 14px 0 0;
		font-size: 14.5px;
		color: var(--muted);
	}
	.links {
		display: grid;
		gap: 12px;
	}
	.links a {
		display: grid;
		gap: 4px;
		padding: 20px 22px;
		border-radius: 18px;
		background: var(--white);
		border: 1px solid var(--rule);
		color: var(--ink);
		transition: border-color 0.2s var(--ease);
	}
	.links a:hover {
		border-color: #b9c0c9;
		text-decoration: none;
	}
	.links strong {
		font-weight: 600;
	}
	.links span {
		font-size: 14.5px;
		color: var(--graphite);
	}
	.measured {
		margin-top: clamp(72px, 9vw, 120px);
	}
	.mlead {
		margin: 12px 0 28px;
		color: var(--graphite);
		max-width: 60ch;
	}
	table {
		width: 100%;
		border-collapse: collapse;
		font-size: 15.5px;
	}
	th {
		text-align: left;
		font-weight: 500;
		font-size: 13.5px;
		color: var(--muted);
		padding: 0 16px 12px 0;
		border-bottom: 1px solid var(--rule);
	}
	td {
		padding: 16px 16px 16px 0;
		border-bottom: 1px solid var(--rule-soft);
		color: var(--graphite);
		vertical-align: top;
	}
	td:first-child {
		color: var(--ink);
		font-weight: 500;
	}
	.val {
		color: var(--ink) !important;
		font-weight: 600;
		white-space: nowrap;
		font-variant-numeric: tabular-nums;
	}
	@media (max-width: 600px) {
		pre {
			padding-top: 52px;
		}
	}
	@media (max-width: 900px) {
		.dev {
			grid-template-columns: minmax(0, 1fr);
		}
		table,
		tbody,
		tr,
		td {
			display: block;
		}
		thead {
			display: none;
		}
		tr {
			padding: 14px 0;
			border-bottom: 1px solid var(--rule-soft);
		}
		td {
			padding: 2px 0;
			border: 0;
		}
	}
</style>
