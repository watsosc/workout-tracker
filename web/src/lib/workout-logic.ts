import type { SessionEntry, SessionSet, WorkoutSession } from '$lib/types';

// Pure helpers for the in-workout screen. Mirrored in ios/.../Core/OfflineWorkoutStore.swift.

export type PendingSet = {
	entry: SessionEntry;
	setItem: SessionSet;
	targetReps: number;
	weightKg: number;
};

/** The next set to do: first set that is neither completed nor skipped, in exercise order. */
export function pendingSet(
	session: WorkoutSession | null,
	weightOverrides: Record<number, number> = {}
): PendingSet | null {
	if (!session) return null;
	for (const entry of session.entries) {
		for (const setItem of entry.sets) {
			if (setItem.completed || setItem.skipped) continue;
			return {
				entry,
				setItem,
				targetReps: setItem.targetReps ?? entry.plannedReps,
				weightKg: weightForSet(entry, setItem, weightOverrides)
			};
		}
	}
	return null;
}

/**
 * Weight for an upcoming set. A weight the user picked for this exercise wins; otherwise a change
 * made on an earlier set carries forward (if you dropped the weight on set 2, set 3 starts there).
 */
export function weightForSet(
	entry: SessionEntry,
	setItem: SessionSet,
	weightOverrides: Record<number, number> = {}
): number {
	const override = weightOverrides[entry.id];
	if (override !== undefined) return override;
	const done = entry.sets.filter((s) => s.completed && s.setIndex < setItem.setIndex && s.weightKg !== null);
	const previous = done[done.length - 1];
	if (previous && previous.weightKg !== (setItem.weightKg ?? entry.plannedWeightKg)) {
		return previous.weightKg as number;
	}
	return setItem.weightKg ?? entry.plannedWeightKg;
}

export function lastCompletedSet(session: WorkoutSession | null): SessionSet | null {
	if (!session) return null;
	let latest: SessionSet | null = null;
	for (const entry of session.entries) {
		for (const setItem of entry.sets) {
			if (!setItem.completed) continue;
			if (!latest || (setItem.completedAt ?? '') >= (latest.completedAt ?? '')) latest = setItem;
		}
	}
	return latest;
}

export type EntryStatus = 'done' | 'skipped' | 'in-progress' | 'todo';

export function entryStatus(entry: SessionEntry): EntryStatus {
	const remaining = entry.sets.filter((s) => !s.completed);
	if (remaining.length === 0) return 'done';
	if (remaining.every((s) => s.skipped)) return 'skipped';
	return entry.sets.some((s) => s.completed) ? 'in-progress' : 'todo';
}

/** Validate a rep count entered after a set. Failed sets must be below the target. */
export function validateReps(raw: string, target: number, mode: 'success' | 'fail', isAmrap: boolean): string | null {
	const reps = Number(raw);
	if (!Number.isInteger(reps) || reps < 0) return 'Enter a whole number of reps';
	if (mode === 'fail' && reps >= target) return `A failed set is fewer than ${target} reps`;
	if (mode === 'success' && isAmrap && reps < target) return `AMRAP reps must be at least ${target}`;
	return null;
}
