<script lang="ts">
	let { size = 24, tone = 'ink' }: { size?: number; tone?: 'ink' | 'light' } = $props();
	const fill = $derived(tone === 'ink' ? 'var(--ink)' : '#fff');
	const cut = $derived(tone === 'ink' ? '#fff' : 'var(--ink)');
</script>

<svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
	<path d="M12 1.8 20.6 5v6.6c0 5.1-3.6 9.1-8.6 10.6-5-1.5-8.6-5.5-8.6-10.6V5z" fill={fill} />
	<path d="M7.6 12.2h2.6l1.4-3.4 2.2 6.6 1.5-3.2h1.9" fill="none" stroke={cut} stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" />
</svg>
