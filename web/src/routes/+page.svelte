<script lang="ts">
	import { goto } from '$app/navigation';
	import { onMount } from 'svelte';

	onMount(() => {
		goto('/workout', { replaceState: true });
	});
</script>

<section class="card">
	<p class="subtle">Redirecting to Workout…</p>
	<p><a href="/workout">Continue to Workout</a></p>
</section>
