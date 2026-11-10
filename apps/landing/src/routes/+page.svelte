<script lang="ts">
	import { onMount } from 'svelte';
	import Builders from '#lib/components/Builders.svelte';
	import FlowPreview from '#lib/components/FlowPreview.svelte';
	import Footer from '#lib/components/Footer.svelte';
	import Hero from '#lib/components/Hero.svelte';
	import Lanes from '#lib/components/Lanes.svelte';
	import Nav from '#lib/components/Nav.svelte';
	import Pipeline from '#lib/components/Pipeline.svelte';
	import StatBand from '#lib/components/StatBand.svelte';
	import Terminal from '#lib/components/Terminal.svelte';
	import TrustWall from '#lib/components/TrustWall.svelte';
	import { live } from '#lib/live.svelte.ts';

	onMount(() => {
		// Reveal styles apply only with JS, so the prerendered page is fully visible without it.
		document.documentElement.classList.add('js');
		live.start();
		return () => live.destroy();
	});
</script>

<svelte:head>
	<title>ChainGuard: real-time on-chain risk monitoring</title>
	<meta
		name="description"
		content="Open-source, read-only watchtower for on-chain risk. Multi-node verified, reorg-safe, with rules, per-protocol invariants and ML anomaly detection."
	/>
</svelte:head>

<a class="skip" href="#main">Skip to content</a>
<Nav />
<main id="main">
	<Hero />
	<StatBand />
	<Terminal />
	<Pipeline />
	<TrustWall />
	<FlowPreview />
	<Lanes />
	<Builders />
</main>
<Footer />

<style>
	.skip {
		position: absolute;
		left: -999px;
		top: 8px;
		z-index: 50;
		padding: 8px 14px;
		border-radius: 8px;
		background: var(--surface-3);
	}
	.skip:focus {
		left: 8px;
	}
</style>
