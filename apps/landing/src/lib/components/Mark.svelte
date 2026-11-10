<script lang="ts">
	let { size = 22 }: { size?: number } = $props();
</script>

<svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
	<path d="M12 2.5 20 6v6.2c0 4.6-3.3 8.1-8 9.3-4.7-1.2-8-4.7-8-9.3V6z" fill="var(--brand)" />
	<path
		d="M8.2 12.4l2.6 2.6 5-5.2"
		fill="none"
		stroke="var(--bg)"
		stroke-width="2.2"
		stroke-linecap="round"
		stroke-linejoin="round"
	/>
</svg>
