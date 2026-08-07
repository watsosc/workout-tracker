<script lang="ts">
	import { page } from '$app/state';
	import favicon from '$lib/assets/favicon.svg';

	let { children } = $props();

	const navItems = [
		{ href: '/workout', label: 'Workout' },
		{ href: '/plan', label: 'Plan' },
		{ href: '/analytics', label: 'Analytics' },
		{ href: '/history', label: 'History' },
		{ href: '/settings', label: 'Settings' }
	];

	function isActive(href: string): boolean {
		const pathname = page.url.pathname;
		if (href === '/') return pathname === '/';
		return pathname === href || pathname.startsWith(`${href}/`);
	}
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
</svelte:head>

<div class="app-shell">
	<header class="topbar">
		<div class="brand">Workout Tracker</div>
		<nav>
			{#each navItems as item}
				<a
					href={item.href}
					class:active={isActive(item.href)}
					aria-current={isActive(item.href) ? 'page' : undefined}
				>
					{item.label}
				</a>
			{/each}
		</nav>
	</header>

	<main class="content">
		{@render children()}
	</main>
</div>

<style>
	:global(body) {
		margin: 0;
		font-family: Inter, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
		background: #0f172a;
		color: #e2e8f0;
	}

	.app-shell {
		min-height: 100vh;
	}

	.topbar {
		position: sticky;
		top: 0;
		z-index: 10;
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 1rem;
		padding: 0.75rem 1rem;
		background: rgba(11, 18, 32, 0.92);
		backdrop-filter: blur(6px);
		border-bottom: 1px solid #1f2937;
	}

	:global(body.session-active-workout) .topbar {
		display: none;
	}

	:global(body.session-active-workout) {
		overflow: hidden;
	}

	.brand {
		font-weight: 700;
	}

	nav {
		display: flex;
		gap: 0.4rem;
		flex-wrap: wrap;
	}

	nav a {
		color: #cbd5e1;
		text-decoration: none;
		padding: 0.35rem 0.55rem;
		border-radius: 8px;
		border: 1px solid transparent;
	}

	nav a:hover {
		border-color: #334155;
		background: #1e293b;
		color: #fff;
	}

	nav a.active {
		background: #2563eb;
		border-color: #1d4ed8;
		color: #ffffff;
		font-weight: 600;
	}

	.content {
		max-width: 1100px;
		margin: 0 auto;
		padding: 1rem;
		display: grid;
		gap: 1rem;
	}

	:global(.card) {
		background: #111827;
		border: 1px solid #1f2937;
		border-radius: 14px;
		padding: 1rem;
	}

	:global(.subtle) {
		color: #cbd5e1;
	}

	:global(.banner) {
		padding: 0.6rem 0.8rem;
		border-radius: 10px;
	}

	:global(.banner.success) {
		background: #052e16;
		border: 1px solid #166534;
	}

	:global(.banner.error) {
		background: #450a0a;
		border: 1px solid #991b1b;
	}

	:global(button),
	:global(input),
	:global(select) {
		font: inherit;
	}

	:global(button) {
		background: #1e293b;
		color: #e2e8f0;
		border: 1px solid #334155;
		border-radius: 10px;
		padding: 0.55rem 0.85rem;
		cursor: pointer;
	}

	:global(button:hover) {
		filter: brightness(1.08);
	}

	:global(button:disabled) {
		opacity: 0.6;
		cursor: not-allowed;
	}

	:global(button.primary) {
		background: #2563eb;
		border-color: #1d4ed8;
	}

	:global(button.danger) {
		background: #7f1d1d;
		border-color: #b91c1c;
	}

	:global(input),
	:global(select) {
		background: #0b1220;
		color: #e2e8f0;
		border: 1px solid #334155;
		border-radius: 8px;
		padding: 0.45rem 0.55rem;
		width: 100%;
		min-width: 0;
		box-sizing: border-box;
	}

	:global(h1),
	:global(h2),
	:global(h3) {
		margin: 0 0 0.5rem;
	}

	:global(label) {
		display: grid;
		gap: 0.35rem;
		font-size: 0.92rem;
		min-width: 0;
		overflow-wrap: anywhere;
	}

	@media (max-width: 760px) {
		.topbar {
			position: static;
			padding: 0.65rem 0.75rem;
			flex-direction: column;
			align-items: stretch;
			gap: 0.55rem;
		}

		nav {
			flex-wrap: nowrap;
			overflow-x: auto;
			padding-bottom: 0.1rem;
			scrollbar-width: thin;
		}

		nav a {
			white-space: nowrap;
		}

		.content {
			padding: 0.75rem;
			gap: 0.75rem;
		}

		:global(.card) {
			padding: 0.85rem;
			border-radius: 12px;
		}
	}
</style>
