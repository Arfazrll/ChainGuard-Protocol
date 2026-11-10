<script lang="ts">
	import { REPO } from '#lib/config.ts';
	import { reveal } from '#lib/motion.ts';
</script>

<section class="closing chapter-dark" aria-labelledby="closing-title">
	<div class="wrap inner" use:reveal>
		<h2 id="closing-title" class="h2" data-reveal>See your first verified alert in about a minute.</h2>
		<p class="lead" data-reveal>Clone the repository, run one command, and replay two real incidents on your own machine.</p>
		<div class="ctas" data-reveal>
			<a class="btn btn-light" href="#developers">Get started</a>
			<a class="btn btn-outline" href={REPO}>View on GitHub</a>
		</div>
	</div>
</section>

<style>
	.closing {
		padding-block: clamp(88px, 10vw, 140px);
		text-align: center;
	}
	.inner {
		display: grid;
		justify-items: center;
		gap: 22px;
	}
	.lead {
		margin: 0;
	}
	.ctas {
		display: flex;
		flex-wrap: wrap;
		justify-content: center;
		gap: 12px;
		margin-top: 8px;
	}
	.btn-light {
		background: #fff;
		color: var(--ink);
	}
	.btn-light:hover {
		background: #e8ebef;
	}
	.btn-outline {
		border-color: #4a5260;
		color: #fff !important;
	}
	.btn-outline:hover {
		border-color: #8a93a0;
	}
</style>
