<script lang="ts">
	import { onMount } from 'svelte';
	import Activity from '#lib/components/Activity.svelte';
	import CaseStudy from '#lib/components/CaseStudy.svelte';
	import Closing from '#lib/components/Closing.svelte';
	import Coverage from '#lib/components/Coverage.svelte';
	import Developers from '#lib/components/Developers.svelte';
	import Faq from '#lib/components/Faq.svelte';
	import Footer from '#lib/components/Footer.svelte';
	import Guarantees from '#lib/components/Guarantees.svelte';
	import Hero from '#lib/components/Hero.svelte';
	import LaneStack from '#lib/components/LaneStack.svelte';
	import Nav from '#lib/components/Nav.svelte';
	import Platform from '#lib/components/Platform.svelte';
	import Security from '#lib/components/Security.svelte';
	import Teams from '#lib/components/Teams.svelte';
	import { live } from '#lib/live.svelte.ts';

	onMount(() => {
		// Reveal styles apply only with JS, so the prerendered page is fully visible without it.
		document.documentElement.classList.add('js');
		live.start();
		return () => live.destroy();
	});
</script>

<svelte:head>
	<title>SvlteChain: on-chain risk monitoring you can verify</title>
	<meta
		name="description"
		content="Open-source, read-only risk monitoring for blockchains. Every block confirmed by independent nodes, three detection lanes, risk scores, a tamper-evident audit trail and compliance reports."
	/>
</svelte:head>

<a class="skip" href="#main">Skip to content</a>
<Nav />
<main id="main">
	<Hero />
	<Activity />
	<Coverage />
	<Guarantees />
	<LaneStack />
	<CaseStudy />
	<Platform />
	<Teams />
	<Security />
	<Developers />
	<Faq />
	<Closing />
</main>
<Footer />

<style>
	.skip {
		position: absolute;
		left: -999px;
		top: 8px;
		z-index: 60;
		padding: 10px 16px;
		border-radius: 10px;
		background: var(--ink);
		color: #fff;
	}
	.skip:focus {
		left: 8px;
	}
</style>
