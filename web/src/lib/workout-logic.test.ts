import { describe, expect, it } from 'vitest';
import type { SessionEntry, SessionSet, WorkoutSession } from './types';
import { entryStatus, lastCompletedSet, pendingSet, validateReps, weightForSet } from './workout-logic';

let nextId = 1;
function set(overrides: Partial<SessionSet> = {}): SessionSet {
	return {
		id: nextId++,
		setIndex: 1,
		targetReps: 5,
		isAmrap: false,
		repsCompleted: null,
		weightKg: 100,
		durationSeconds: null,
		completed: false,
		completedAt: null,
		skipped: false,
		...overrides
	};
}

function entry(id: number, sets: SessionSet[], overrides: Partial<SessionEntry> = {}): SessionEntry {
	return {
		id,
		planWorkoutExerciseId: id,
		exerciseId: id,
		exerciseName: `Exercise ${id}`,
		equipmentType: null,
		plannedSets: sets.length,
		plannedReps: 5,
		plannedWeightKg: 100,
		progressionProtocol: 'BASIC',
		tier: null,
		expectedRestSeconds: 90,
		sets: sets.map((s, i) => ({ ...s, setIndex: i + 1 })),
		...overrides
	};
}

function session(entries: SessionEntry[]): WorkoutSession {
	return {
		id: 1,
		planWorkoutId: 1,
		planWorkoutName: 'A',
		status: 'IN_PROGRESS',
		startedAt: '2026-01-01T00:00:00',
		finishedAt: null,
		heartRateSampleCount: 0,
		avgHeartRateBpm: null,
		maxHeartRateBpm: null,
		stravaExportStatus: null,
		stravaActivityId: null,
		stravaActivityUrl: null,
		stravaLastError: null,
		entries
	};
}

const done = (weightKg = 100, at = '2026-01-01T00:01:00') =>
	set({ completed: true, repsCompleted: 5, weightKg, completedAt: at });

describe('pendingSet', () => {
	it('returns the first set that is neither done nor skipped', () => {
		const s = session([
			entry(1, [done(), done()]),
			entry(2, [set({ skipped: true }), set({ skipped: true })]),
			entry(3, [done(), set()])
		]);
		const pending = pendingSet(s);
		expect(pending?.entry.id).toBe(3);
		expect(pending?.setItem.setIndex).toBe(2);
	});

	it('is null when everything is done or skipped', () => {
		expect(pendingSet(session([entry(1, [done(), set({ skipped: true })])]))).toBeNull();
		expect(pendingSet(null)).toBeNull();
	});
});

describe('weightForSet', () => {
	it('uses the planned weight by default', () => {
		const e = entry(1, [set(), set()]);
		expect(weightForSet(e, e.sets[0])).toBe(100);
	});

	it('carries a weight change forward from an earlier set', () => {
		const e = entry(1, [done(90), set()]);
		expect(weightForSet(e, e.sets[1])).toBe(90);
	});

	it('prefers a weight the user picked for this exercise', () => {
		const e = entry(1, [done(90), set()]);
		expect(weightForSet(e, e.sets[1], { 1: 80 })).toBe(80);
		expect(pendingSet(session([e]), { 1: 80 })?.weightKg).toBe(80);
	});
});

describe('lastCompletedSet', () => {
	it('finds the most recently completed set across exercises', () => {
		const latest = done(100, '2026-01-01T00:09:00');
		const s = session([entry(1, [done(100, '2026-01-01T00:05:00')]), entry(2, [latest, set()])]);
		expect(lastCompletedSet(s)?.completedAt).toBe('2026-01-01T00:09:00');
	});
});

describe('entryStatus', () => {
	it('classifies exercises', () => {
		expect(entryStatus(entry(1, [done(), done()]))).toBe('done');
		expect(entryStatus(entry(1, [done(), set({ skipped: true })]))).toBe('skipped');
		expect(entryStatus(entry(1, [done(), set()]))).toBe('in-progress');
		expect(entryStatus(entry(1, [set(), set()]))).toBe('todo');
	});
});

describe('validateReps', () => {
	it('requires failed sets to be below target', () => {
		expect(validateReps('5', 5, 'fail', false)).toMatch(/fewer than 5/);
		expect(validateReps('3', 5, 'fail', false)).toBeNull();
	});

	it('requires AMRAP successes to reach target', () => {
		expect(validateReps('4', 5, 'success', true)).toMatch(/at least 5/);
		expect(validateReps('9', 5, 'success', true)).toBeNull();
	});

	it('rejects non-integers', () => {
		expect(validateReps('2.5', 5, 'fail', false)).toMatch(/whole number/);
		expect(validateReps('', 5, 'fail', false)).toBeNull(); // empty -> 0 reps, a valid fail
	});
});
