import { describe, expect, it } from 'vitest';
import { formatPlates, platesPerSide, usesBarbell, warmupSets } from './barbell';

describe('platesPerSide', () => {
	it('loads the largest plates first', () => {
		expect(platesPerSide(225, 'lb')).toEqual({ plates: [45, 45], remainder: 0 });
		expect(platesPerSide(100, 'kg')).toEqual({ plates: [25, 15], remainder: 0 });
		expect(platesPerSide(137.5, 'lb')).toEqual({ plates: [45], remainder: 1.25 }); // no 1.25 lb plates
	});

	it('handles the empty bar and weights below it', () => {
		expect(platesPerSide(45, 'lb')).toEqual({ plates: [], remainder: 0 });
		expect(platesPerSide(30, 'lb')).toBeNull();
	});

	it('reports weight that cannot be loaded exactly', () => {
		expect(formatPlates(227.5, 'lb')).toBe('45 + 45 /side (+1.25 short)');
		expect(formatPlates(45, 'lb')).toBe('Empty bar');
	});
});

describe('warmupSets', () => {
	it('ramps from the empty bar toward the working weight', () => {
		expect(warmupSets(225, 'lb')).toEqual([
			{ weight: 45, reps: 10 },
			{ weight: 90, reps: 5 },
			{ weight: 135, reps: 3 },
			{ weight: 180, reps: 2 }
		]);
	});

	it('skips steps that would repeat or reach the working weight', () => {
		expect(warmupSets(50, 'lb')).toEqual([]);
		const light = warmupSets(75, 'lb');
		expect(light[0]).toEqual({ weight: 45, reps: 10 });
		expect(light.every((s, i) => i === 0 || s.weight > light[i - 1].weight)).toBe(true);
		expect(light.every((s) => s.weight < 75)).toBe(true);
	});
});

describe('usesBarbell', () => {
	it('trusts catalog equipment, otherwise assumes T1/T2 are barbell lifts', () => {
		expect(usesBarbell('BARBELL', 'T3')).toBe(true);
		expect(usesBarbell('DUMBBELL', 'T1')).toBe(false);
		expect(usesBarbell(null, 'T2')).toBe(true);
		expect(usesBarbell(null, 'T3')).toBe(false);
	});
});
