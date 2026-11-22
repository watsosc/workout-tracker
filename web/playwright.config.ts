import { defineConfig, devices } from '@playwright/test';

const API_PORT = 8010;
const WEB_PORT = 5190;

// End-to-end tests: a throwaway backend (fresh DB + seeded plan) behind the Vite dev server.
export default defineConfig({
	testDir: 'e2e',
	fullyParallel: false,
	workers: 1,
	timeout: 60_000,
	reporter: [['list']],
	use: {
		baseURL: `http://127.0.0.1:${WEB_PORT}`,
		...devices['Pixel 7'],
		trace: 'retain-on-failure',
		screenshot: 'only-on-failure'
	},
	webServer: [
		{
			command: 'bash e2e/start-backend.sh',
			url: `http://127.0.0.1:${API_PORT}/health`,
			env: { E2E_API_PORT: String(API_PORT) },
			reuseExistingServer: false,
			timeout: 60_000
		},
		{
			command: `npx vite dev --host 127.0.0.1 --port ${WEB_PORT} --strictPort`,
			url: `http://127.0.0.1:${WEB_PORT}`,
			env: { API_PROXY_TARGET: `http://127.0.0.1:${API_PORT}` },
			reuseExistingServer: false,
			timeout: 60_000
		}
	]
});
