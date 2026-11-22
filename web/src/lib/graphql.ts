export type GraphQLErrorItem = {
	message: string;
	extensions?: { code?: string };
};

type GraphQLResponse<T> = {
	data?: T;
	errors?: GraphQLErrorItem[];
};

import { redirectToLogin, UnauthorizedError } from '$lib/auth';

const GRAPHQL_ENDPOINT = import.meta.env.VITE_GRAPHQL_ENDPOINT || '/graphql';

export async function gql<T>(query: string, variables?: Record<string, unknown>): Promise<T> {
	const response = await fetch(GRAPHQL_ENDPOINT, {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		credentials: 'same-origin',
		body: JSON.stringify({ query, variables })
	});

	if (!response.ok) {
		throw new Error(`GraphQL HTTP error: ${response.status}`);
	}

	const json = (await response.json()) as GraphQLResponse<T>;
	if (json.errors?.some((e) => e.extensions?.code === 'UNAUTHENTICATED')) {
		redirectToLogin();
		throw new UnauthorizedError();
	}

	if (json.errors && json.errors.length > 0) {
		throw new Error(json.errors.map((e) => e.message).join('; '));
	}

	if (!json.data) {
		throw new Error('GraphQL response missing data');
	}

	return json.data;
}
