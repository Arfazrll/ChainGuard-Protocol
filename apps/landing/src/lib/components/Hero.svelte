<script lang="ts">
	import { reveal, scrollProgress } from '#lib/motion.ts';
	import ProductWindow from './ProductWindow.svelte';

	// 0 when the window first enters, 1 once it sits in the upper part of the screen.
	let p = $state(0);
	const tilt = $derived(18 * (1 - p));
	const scale = $derived(0.92 + 0.08 * p);
</script>

<section class="hero">
	<div class="wrap copy" use:reveal>
		<h1 class="display" data-reveal>
			Watch every block.
			<span class="soft">Trust no single node.</span>
		</h1>
		<p class="lead" data-reveal>
			ChainGuard is open-source risk monitoring for blockchains. It confirms every block with independent nodes,
			detects exploits and protocol failures as they happen, and backs each alert with on-chain evidence your risk
			team can check for itself.
		</p>
		<div class="ctas" data-reveal>
			<a class="btn btn-primary" href="#developers">Get started</a>
			<a class="btn btn-secondary" href="#case-study">See the Euler replay</a>
		</div>
		<p class="assure" data-reveal>
			Read-only by design. ChainGuard holds no keys, signs nothing and never sends a transaction.
			<a href="#security">How that is enforced</a>
		</p>
	</div>

	<div class="stage" use:scrollProgress={{ cb: (v) => (p = v), start: 0.95, end: 0.2 }}>
		<div class="tilt" style="transform: perspective(2200px) rotateX({tilt}deg) scale({scale});">
			<ProductWindow />
		</div>
		<p class="caption">
			The dashboard after replaying two real incidents from Ethereum mainnet: the Euler Finance exploit and the USDC
			depeg of March 2023.
		</p>
	</div>
</section>

<style>
	.hero {
		padding-top: clamp(72px, 10vw, 132px);
		overflow: hidden;
	}
	.copy {
		display: grid;
		justify-items: center;
		text-align: center;
		gap: 26px;
	}
	.copy .lead {
		margin: 0;
		max-width: 680px;
	}
	.ctas {
		display: flex;
		flex-wrap: wrap;
		justify-content: center;
		gap: 12px;
		margin-top: 4px;
	}
	.assure {
		margin: 0;
		font-size: 14.5px;
		color: var(--muted);
		max-width: 60ch;
	}
	.stage {
		width: min(1240px, calc(100vw - 32px));
		margin: clamp(56px, 7vw, 88px) auto 0;
		padding-bottom: clamp(72px, 9vw, 120px);
	}
	.tilt {
		transform-origin: 50% 0%;
		will-change: transform;
	}
	.caption {
		margin: 22px auto 0;
		max-width: 64ch;
		text-align: center;
		font-size: 14px;
		color: var(--muted);
	}
</style>
