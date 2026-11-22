import type { EquipmentType } from '$lib/types';
import type { WeightUnit } from '$lib/ui';

// Kept in sync with ios/WorkoutTrackerIOS/Shared/BarbellMath.swift.

export type WarmupSet = { weight: number; reps: number };
export type PlateBreakdown = { plates: number[]; remainder: number };

const PLATES: Record<WeightUnit, number[]> = {
	lb: [45, 35, 25, 10, 5, 2.5],
	kg: [25, 20, 15, 10, 5, 2.5, 1.25]
};

const WARMUP_RAMP: Array<[percent: number, reps: number]> = [
	[0.4, 5],
	[0.6, 3],
	[0.8, 2]
];

export function barWeight(unit: WeightUnit): number {
	return unit === 'lb' ? 45 : 20;
}

function loadIncrement(unit: WeightUnit): number {
	return unit === 'lb' ? 5 : 2.5;
}

/**
 * Whether to show plate math / warm-ups. Exercises linked to the catalog use their equipment;
 * unlinked T1/T2 lifts are assumed to be barbell compounds (that's what GZCLP prescribes there).
 */
export function usesBarbell(equipment: EquipmentType | null, tier: string | null): boolean {
	if (equipment) return equipment === 'BARBELL';
	return tier === 'T1' || tier === 'T2';
}

/** Plates needed on each side of the bar, largest first. Null if the weight is below the bar. */
export function platesPerSide(total: number, unit: WeightUnit): PlateBreakdown | null {
	const bar = barWeight(unit);
	if (total < bar - 0.01) return null;
	// Work in hundredths to avoid float drift (2.5 / 1.25 plates).
	let remaining = Math.round(((total - bar) / 2) * 100);
	const plates: number[] = [];
	for (const plate of PLATES[unit]) {
		const p = Math.round(plate * 100);
		while (remaining >= p) {
			plates.push(plate);
			remaining -= p;
		}
	}
	return { plates, remainder: remaining / 100 };
}

export function formatPlates(total: number, unit: WeightUnit): string {
	const breakdown = platesPerSide(total, unit);
	if (!breakdown) return 'Below bar weight';
	if (breakdown.plates.length === 0) return 'Empty bar';
	const text = breakdown.plates.join(' + ');
	return breakdown.remainder > 0 ? `${text} /side (+${breakdown.remainder} short)` : `${text} /side`;
}

/** Warm-up ramp toward a working weight: empty bar, then ~40/60/80%, rounded to loadable jumps. */
export function warmupSets(working: number, unit: WeightUnit): WarmupSet[] {
	const bar = barWeight(unit);
	const inc = loadIncrement(unit);
	if (working <= bar + inc) return [];
	const sets: WarmupSet[] = [{ weight: bar, reps: 10 }];
	for (const [percent, reps] of WARMUP_RAMP) {
		const weight = Math.round((working * percent) / inc) * inc;
		if (weight <= sets[sets.length - 1].weight || weight >= working) continue;
		sets.push({ weight, reps });
	}
	return sets;
}
