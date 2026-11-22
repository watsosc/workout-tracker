import { defineConfig } from 'vitest/config';
import { fileURLToPath } from 'node:url';

// Unit tests for framework-free modules in src/lib (no SvelteKit plugin needed).
export default defineConfig({
	resolve: {
		alias: { $lib: fileURLToPath(new URL('./src/lib', import.meta.url)) }
	},
	test: {
		include: ['src/**/*.test.ts']
	}
});
