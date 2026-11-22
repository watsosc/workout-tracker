// Sign-in uses an HttpOnly session cookie set by the server's `login` mutation, so there is
// nothing to store client-side.

export class UnauthorizedError extends Error {
	constructor() {
		super('Sign in required');
		this.name = 'UnauthorizedError';
	}
}

/** Send the user to the sign-in page, returning to the current page afterwards. */
export function redirectToLogin(): void {
	if (typeof window === 'undefined') return;
	if (window.location.pathname.startsWith('/login')) return;
	const next = window.location.pathname + window.location.search;
	window.location.assign(`/login?next=${encodeURIComponent(next)}`);
}
