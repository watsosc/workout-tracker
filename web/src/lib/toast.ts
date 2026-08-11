import { get, writable } from 'svelte/store';

export type ToastKind = 'success' | 'error' | 'info';

export type ToastItem = {
	id: number;
	message: string;
	kind: ToastKind;
};

export const toasts = writable<ToastItem[]>([]);

let nextToastId = 1;
const dismissTimers = new Map<number, ReturnType<typeof setTimeout>>();

function scheduleDismiss(id: number, durationMs: number): void {
	const previous = dismissTimers.get(id);
	if (previous) clearTimeout(previous);
	const handle = setTimeout(() => removeToast(id), Math.max(600, durationMs));
	dismissTimers.set(id, handle);
}

export function pushToast(message: string, kind: ToastKind = 'info', durationMs = 4200): number {
	const existing = get(toasts).find((item) => item.message === message && item.kind === kind);
	if (existing) {
		scheduleDismiss(existing.id, durationMs);
		return existing.id;
	}

	const id = nextToastId++;
	toasts.update((items) => [...items, { id, message, kind }]);
	scheduleDismiss(id, durationMs);
	return id;
}

export function removeToast(id: number): void {
	const handle = dismissTimers.get(id);
	if (handle) {
		clearTimeout(handle);
		dismissTimers.delete(id);
	}
	toasts.update((items) => items.filter((item) => item.id !== id));
}
