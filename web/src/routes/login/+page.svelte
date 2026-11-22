<script lang="ts">
	import { onMount } from 'svelte';
	import { login } from '$lib/workout-api';

	let username = $state('');
	let password = $state('');
	let errorMessage = $state('');
	let checking = $state(false);

	function nextPath(): string {
		const next = new URLSearchParams(window.location.search).get('next') ?? '/workout';
		// Only allow same-site relative paths.
		return next.startsWith('/') && !next.startsWith('//') && !next.startsWith('/login') ? next : '/workout';
	}

	async function signIn(event: SubmitEvent) {
		event.preventDefault();
		if (!username.trim() || !password) {
			errorMessage = 'Enter your username and password';
			return;
		}
		checking = true;
		errorMessage = '';
		try {
			await login(username.trim(), password);
			window.location.assign(nextPath());
		} catch (error) {
			errorMessage = error instanceof Error ? error.message : String(error);
			password = '';
		} finally {
			checking = false;
		}
	}

	onMount(() => {
		document.getElementById('username')?.focus();
	});
</script>

<section class="card login">
	<h1>Sign in</h1>
	<form onsubmit={signIn}>
		<label>
			Username
			<input id="username" autocomplete="username" autocapitalize="none" bind:value={username} disabled={checking} />
		</label>
		<label>
			Password
			<input type="password" autocomplete="current-password" bind:value={password} disabled={checking} />
		</label>
		<button class="primary" type="submit" disabled={checking}>
			{checking ? 'Signing in…' : 'Sign in'}
		</button>
	</form>
	{#if errorMessage}
		<p class="banner error">{errorMessage}</p>
	{/if}
</section>

<style>
	.login {
		max-width: 380px;
		margin: 2rem auto;
	}

	form {
		display: grid;
		gap: 0.75rem;
	}
</style>
