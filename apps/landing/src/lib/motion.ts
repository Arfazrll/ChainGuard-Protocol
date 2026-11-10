/**
 * Motion, disciplined: every effect here is opt-out through
 * `prefers-reduced-motion`, and content is fully visible without JS.
 */

export const reducedMotion = () =>
	typeof matchMedia !== 'undefined' && matchMedia('(prefers-reduced-motion: reduce)').matches;

/** Fade + small rise as a section enters; children marked `data-reveal` stagger. */
export function reveal(node: HTMLElement) {
	const items = [node, ...node.querySelectorAll<HTMLElement>('[data-reveal]')].filter((el) =>
		el.hasAttribute('data-reveal')
	);
	items.forEach((el, i) => el.style.setProperty('--i', String(el.dataset.revealIndex ?? i)));
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
		{ rootMargin: '0px 0px -10% 0px', threshold: 0.12 }
	);
	items.forEach((el) => io.observe(el));
	return { destroy: () => io.disconnect() };
}

/** The primary CTA leans toward the pointer (fine pointers only). */
export function magnetic(node: HTMLElement, strength = 0.28) {
	if (reducedMotion() || !matchMedia('(pointer: fine)').matches) return {};
	const radius = 90;
	const move = (e: PointerEvent) => {
		const r = node.getBoundingClientRect();
		const dx = e.clientX - (r.left + r.width / 2);
		const dy = e.clientY - (r.top + r.height / 2);
		const near = Math.hypot(dx, dy) < Math.max(r.width, r.height) / 2 + radius;
		node.style.transform = near ? `translate(${dx * strength}px, ${dy * strength}px)` : '';
	};
	const leave = () => (node.style.transform = '');
	window.addEventListener('pointermove', move, { passive: true });
	node.addEventListener('pointerleave', leave);
	return {
		destroy() {
			window.removeEventListener('pointermove', move);
			node.removeEventListener('pointerleave', leave);
		}
	};
}

export interface CountUp {
	value: number;
	format: (v: number) => string;
}

/**
 * Counts up to `value` when first in view, then animates between later
 * values (live updates). Text is always the final value for assistive tech.
 */
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
		const start = performance.now();
		const dur = from === 0 ? 1400 : 600;
		const tick = (t: number) => {
			const k = Math.min(1, (t - start) / dur);
			const eased = 1 - Math.pow(1 - k, 3);
			shown = from + (to - from) * eased;
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
