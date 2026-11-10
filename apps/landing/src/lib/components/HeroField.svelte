<script lang="ts">
	/**
	 * The hero's living background: lanes of blocks drifting toward a
	 * watchtower line. As a block crosses it, two attestation ticks light up
	 * (two independent nodes agreed); rarely, one is flagged. Canvas 2D,
	 * one draw per frame, paused off-screen and when the tab is hidden;
	 * a single still frame under prefers-reduced-motion.
	 */
	import { onMount } from 'svelte';
	import { reducedMotion } from '#lib/motion.ts';

	let canvas: HTMLCanvasElement;

	interface Block {
		x: number;
		w: number;
		lit: number;
		flagged: boolean;
		seen: boolean;
	}

	onMount(() => {
		const ctx = canvas.getContext('2d')!;
		const css = getComputedStyle(document.documentElement);
		const tok = (n: string) => css.getPropertyValue(n).trim();
		const colors = { line: tok('--ink-3'), brand: tok('--brand'), live: tok('--live'), crit: tok('--sev-critical') };

		let w = 0;
		let h = 0;
		let lanes: { y: number; speed: number; blocks: Block[] }[] = [];
		const LANES = 9;

		const seedLane = (i: number) => {
			const y = ((i + 1) / (LANES + 1)) * h;
			const speed = 14 + ((i * 37) % 23);
			const blocks: Block[] = [];
			let x = -Math.random() * 80;
			while (x < w + 120) {
				const bw = 26 + Math.random() * 30;
				// Blocks already past the watchtower start out seen (and dark).
				blocks.push({ x, w: bw, lit: 0, flagged: Math.random() < 0.025, seen: x + bw / 2 < w * 0.64 });
				x += bw + 18 + Math.random() * 60;
			}
			return { y, speed, blocks };
		};

		const resize = () => {
			const dpr = Math.min(2, devicePixelRatio || 1);
			const r = canvas.getBoundingClientRect();
			w = r.width;
			h = r.height;
			canvas.width = Math.round(w * dpr);
			canvas.height = Math.round(h * dpr);
			ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
			lanes = Array.from({ length: LANES }, (_, i) => seedLane(i));
		};

		const draw = (dt: number) => {
			ctx.clearRect(0, 0, w, h);
			const tower = w * 0.64;
			// The watchtower line.
			const g = ctx.createLinearGradient(0, 0, 0, h);
			g.addColorStop(0, 'transparent');
			g.addColorStop(0.5, colors.brand);
			g.addColorStop(1, 'transparent');
			ctx.globalAlpha = 0.35;
			ctx.fillStyle = g;
			ctx.fillRect(tower, 0, 1, h);

			for (const lane of lanes) {
				const bh = 10;
				for (const b of lane.blocks) {
					b.x -= lane.speed * dt;
					if (!b.seen && b.x + b.w / 2 < tower) {
						b.seen = true;
						b.lit = 1;
					}
					b.lit = Math.max(0, b.lit - dt * 0.6);
					const fade = Math.min(1, Math.max(0, b.x / (w * 0.18)), Math.max(0, (w - b.x) / (w * 0.12)));
					const y = lane.y - bh / 2;
					ctx.globalAlpha = (0.08 + 0.4 * b.lit) * fade;
					ctx.strokeStyle = b.lit > 0 ? (b.flagged ? colors.crit : colors.brand) : colors.line;
					ctx.lineWidth = 1;
					ctx.beginPath();
					ctx.roundRect(b.x, y, b.w, bh, 3);
					ctx.stroke();
					if (b.seen && b.lit > 0) {
						// Two attestation ticks: two independent nodes agreed.
						ctx.globalAlpha = 0.85 * b.lit * fade;
						ctx.fillStyle = b.flagged ? colors.crit : colors.live;
						ctx.fillRect(b.x + 5, y + bh + 4, 3, 3);
						ctx.fillRect(b.x + 11, y + bh + 4, 3, 3);
					}
				}
				// Recycle blocks that left on the left edge.
				const last = lane.blocks[lane.blocks.length - 1];
				if (lane.blocks[0].x + lane.blocks[0].w < -10) {
					const b = lane.blocks.shift()!;
					b.x = Math.max(w + 20, last.x + last.w + 18 + Math.random() * 60);
					b.seen = false;
					b.lit = 0;
					b.flagged = Math.random() < 0.025;
					lane.blocks.push(b);
				}
			}
			ctx.globalAlpha = 1;
		};

		resize();
		const ro = new ResizeObserver(resize);
		ro.observe(canvas);

		if (reducedMotion()) {
			draw(0);
			return () => ro.disconnect();
		}

		let raf = 0;
		let last = performance.now();
		let visible = true;
		const loop = (t: number) => {
			const dt = Math.min(0.05, (t - last) / 1000);
			last = t;
			draw(dt);
			raf = requestAnimationFrame(loop);
		};
		const startStop = () => {
			cancelAnimationFrame(raf);
			if (visible && !document.hidden) {
				last = performance.now();
				raf = requestAnimationFrame(loop);
			}
		};
		const io = new IntersectionObserver(([e]) => {
			visible = e.isIntersecting;
			startStop();
		});
		io.observe(canvas);
		document.addEventListener('visibilitychange', startStop);
		startStop();

		return () => {
			cancelAnimationFrame(raf);
			ro.disconnect();
			io.disconnect();
			document.removeEventListener('visibilitychange', startStop);
		};
	});
</script>

<canvas bind:this={canvas} aria-hidden="true"></canvas>

<style>
	canvas {
		position: absolute;
		inset: 0;
		width: 100%;
		height: 100%;
		/* Strongest behind the alert card, fading out under the copy. */
		mask-image: radial-gradient(70% 85% at 72% 50%, black 35%, transparent 80%);
	}
</style>
