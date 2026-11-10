/**
 * Motion, disciplined: everything here is opt-out through
 * `prefers-reduced-motion`, and every section reads fine without JS.
 */

export const reducedMotion = () =>
	typeof matchMedia !== 'undefined' && matchMedia('(prefers-reduced-motion: reduce)').matches;

/** Fade + small rise as content enters; children marked `data-reveal` stagger. */
export function reveal(node: HTMLElement) {
	const items = [node, ...node.querySelectorAll<HTMLElement>('[data-reveal]')].filter((el) =>
		el.hasAttribute('data-reveal')
	);
	items.forEach((el, i) => el.style.setProperty('--i', String(el.dataset.revealIndex ?? i % 6)));
	if (reducedMotion() || typeof IntersectionObserver === 'undefined') {
		items.forEach((el) => el.classList.add('in'));
		return {};
	}
	const io = new IntersectionObserver(
		(entries) => {
			for (const e of entries) {
				if (e.isIntersecting) {
					e.target.classList.add('in');
					io.unobserve(e.target);
				}
			}
		},
		{ rootMargin: '0px 0px -8% 0px', threshold: 0.1 }
	);
	items.forEach((el) => io.observe(el));
	return { destroy: () => io.disconnect() };
}

/**
 * Calls `cb(progress)` on scroll, where progress goes 0 → 1 while the
 * element travels from `start` (fraction of viewport height from the top,
 * measured at the element's top) to `end`. One rAF per frame at most.
 */
export function scrollProgress(
	node: HTMLElement,
	params: { cb: (p: number) => void; start?: number; end?: number }
) {
	let { cb, start = 1, end = 0.25 } = params;
	let raf = 0;
	const measure = () => {
		raf = 0;
		const r = node.getBoundingClientRect();
		const vh = window.innerHeight;
		const p = (start * vh - r.top) / ((start - end) * vh);
		cb(Math.min(1, Math.max(0, p)));
	};
	const onScroll = () => {
		if (!raf) raf = requestAnimationFrame(measure);
	};
	if (reducedMotion()) {
		cb(1);
		return {};
	}
	measure();
	window.addEventListener('scroll', onScroll, { passive: true });
	window.addEventListener('resize', onScroll);
	return {
		update(next: typeof params) {
			({ cb, start = 1, end = 0.25 } = next);
			onScroll();
		},
		destroy() {
			cancelAnimationFrame(raf);
			window.removeEventListener('scroll', onScroll);
			window.removeEventListener('resize', onScroll);
		}
	};
}

export interface CountUp {
	value: number;
	format: (v: number) => string;
}

/** Counts up to `value` when first in view, then animates between later values. */
export function countUp(node: HTMLElement, params: CountUp) {
	let p = params;
	let shown = 0;
	let seen = false;
	let raf = 0;
	node.setAttribute('aria-label', p.format(p.value));

	const run = (to: number) => {
		cancelAnimationFrame(raf);
		if (reducedMotion()) {
			shown = to;
			node.textContent = p.format(to);
			return;
		}
		const from = shown;
		const startT = performance.now();
		const dur = from === 0 ? 1200 : 500;
		const tick = (t: number) => {
			const k = Math.min(1, (t - startT) / dur);
			shown = from + (to - from) * (1 - Math.pow(1 - k, 3));
			node.textContent = p.format(shown);
			if (k < 1) raf = requestAnimationFrame(tick);
		};
		raf = requestAnimationFrame(tick);
	};

	node.textContent = p.format(reducedMotion() ? p.value : 0);
	const io = new IntersectionObserver(
		([e]) => {
			if (e.isIntersecting && !seen) {
				seen = true;
				run(p.value);
			}
		},
		{ threshold: 0.4 }
	);
	io.observe(node);

	return {
		update(next: CountUp) {
			p = next;
			node.setAttribute('aria-label', p.format(p.value));
			if (seen) run(p.value);
			else node.textContent = p.format(reducedMotion() ? p.value : 0);
		},
		destroy() {
			cancelAnimationFrame(raf);
			io.disconnect();
		}
	};
}
