<script lang="ts">
	import { DOCS } from '#lib/config.ts';
	import { magnetic, reveal } from '#lib/motion.ts';
	import AlertCard from './AlertCard.svelte';
	import HeroField from './HeroField.svelte';
</script>

<section class="hero">
	<div class="atmosphere" aria-hidden="true">
		<div class="bloom bloom--violet b1"></div>
		<div class="bloom bloom--green b2"></div>
		<HeroField />
	</div>

	<div class="wrap grid" use:reveal>
		<div class="copy">
			<p class="eyebrow" data-reveal>Open source · read-only · Ethereum mainnet</p>
			<h1 data-reveal>Watch every block.<br /><span class="accent">Trust no single node.</span></h1>
			<p class="lede" data-reveal>
				ChainGuard is a real-time watchtower for on-chain risk. It confirms every block across
				independent nodes, survives reorgs, and raises alerts from three detection lanes with the
				exact on-chain evidence behind each one.
			</p>
			<div class="ctas" data-reveal>
				<a class="btn btn--primary" href={DOCS.run} use:magnetic>
					Run it locally <span class="arrow" aria-hidden="true">→</span>
				</a>
				<a class="btn" href="#live">View live demo</a>
			</div>
			<p class="fine" data-reveal>
				<span aria-hidden="true">✓</span> No keys. No signing. No transactions, ever. A watchtower, not a trader.
			</p>
		</div>
		<div class="card-slot" data-reveal data-reveal-index="3">
			<AlertCard />
		</div>
	</div>
</section>

<style>
	.hero {
		padding-block: clamp(56px, 9vw, 112px) clamp(64px, 9vw, 120px);
		overflow: hidden;
		isolation: isolate;
	}
	.atmosphere {
		position: absolute;
		inset: 0;
		z-index: -1;
	}
	.b1 {
		width: 720px;
		height: 560px;
		left: -180px;
		top: -160px;
	}
	.b2 {
		width: 560px;
		height: 460px;
		right: -120px;
		bottom: -180px;
	}
	@media (prefers-reduced-motion: no-preference) {
		.b1 {
			animation: drift 22s ease-in-out infinite alternate;
		}
		.b2 {
			animation: drift 28s ease-in-out infinite alternate-reverse;
		}
		@keyframes drift {
			to {
				transform: translate3d(60px, 40px, 0) scale(1.08);
			}
		}
	}
	.grid {
		display: grid;
		grid-template-columns: minmax(0, 1.35fr) minmax(0, 0.85fr);
		gap: clamp(32px, 5vw, 72px);
		align-items: center;
	}
	h1 {
		font-size: clamp(40px, 5.5vw, 76px);
		letter-spacing: -0.035em;
		line-height: 1;
	}
	.accent {
		background: linear-gradient(100deg, var(--ink-1) 10%, var(--brand-ink) 55%, var(--live) 110%);
		-webkit-background-clip: text;
		background-clip: text;
		color: transparent;
	}
	.ctas {
		display: flex;
		flex-wrap: wrap;
		gap: 12px;
		margin-top: 34px;
	}
	.ctas :global(.btn--primary) {
		will-change: transform;
		transition:
			transform 0.35s var(--ease),
			box-shadow 0.25s var(--ease);
	}
	.fine {
		margin: 22px 0 0;
		color: var(--ink-3);
		font-size: 13.5px;
	}
	.fine span {
		color: var(--live);
		margin-right: 4px;
	}
	@media (max-width: 900px) {
		.grid {
			grid-template-columns: minmax(0, 1fr);
		}
	}
</style>
