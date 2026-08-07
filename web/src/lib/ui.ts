import type { ExerciseProgressPoint } from '$lib/types';

export type WeightUnit = 'kg' | 'lb';

const LB_PER_KG = 2.2046226218;
const WEIGHT_UNIT_STORAGE_KEY = 'workout.weight-unit';
const WEIGHT_UNIT_EVENT = 'workout:weight-unit-changed';

export function getPreferredWeightUnit(): WeightUnit {
	if (typeof window === 'undefined') return 'lb';
	const raw = window.localStorage.getItem(WEIGHT_UNIT_STORAGE_KEY);
	return raw === 'kg' ? 'kg' : 'lb';
}

export function setPreferredWeightUnit(unit: WeightUnit): void {
	if (typeof window === 'undefined') return;
	window.localStorage.setItem(WEIGHT_UNIT_STORAGE_KEY, unit);
	window.dispatchEvent(new CustomEvent<WeightUnit>(WEIGHT_UNIT_EVENT, { detail: unit }));
}

export function onWeightUnitChange(listener: (unit: WeightUnit) => void): () => void {
	if (typeof window === 'undefined') return () => {};
	const handler = (event: Event) => {
		const custom = event as CustomEvent<WeightUnit>;
		listener(custom.detail ?? getPreferredWeightUnit());
	};
	window.addEventListener(WEIGHT_UNIT_EVENT, handler as EventListener);
	return () => window.removeEventListener(WEIGHT_UNIT_EVENT, handler as EventListener);
}

export function convertKgToUnit(valueKg: number, unit: WeightUnit): number {
	return unit === 'lb' ? valueKg * LB_PER_KG : valueKg;
}

export function convertUnitToKg(value: number, unit: WeightUnit): number {
	return unit === 'lb' ? value / LB_PER_KG : value;
}

export function snapWeightToHalfStep(value: number): number {
	return Math.round(value * 2) / 2;
}

export function displayWeightFromKg(valueKg: number, unit: WeightUnit, digits = 1): string {
	const value = convertKgToUnit(valueKg, unit);
	const snapped = snapWeightToHalfStep(value);
	return String(Number(snapped.toFixed(Math.max(1, digits))));
}

export function weightUnitLabel(unit: WeightUnit): string {
	return unit;
}

export function formatDate(value: string | null): string {
	if (!value) return '—';
	return new Date(value).toLocaleString();
}

export function parsePositiveFloat(value: string, label: string): number {
	const parsed = Number(value);
	if (!Number.isFinite(parsed) || parsed <= 0) {
		throw new Error(`${label} must be a positive number`);
	}
	return parsed;
}

export function parseNonNegativeFloat(value: string, label: string): number {
	const parsed = Number(value);
	if (!Number.isFinite(parsed) || parsed < 0) {
		throw new Error(`${label} must be a number >= 0`);
	}
	return parsed;
}

export function parsePositiveInt(value: string, label: string): number {
	const parsed = Number(value);
	if (!Number.isInteger(parsed) || parsed <= 0) {
		throw new Error(`${label} must be a positive whole number`);
	}
	return parsed;
}

export function parseNonNegativeInt(value: string, label: string): number {
	const parsed = Number(value);
	if (!Number.isInteger(parsed) || parsed < 0) {
		throw new Error(`${label} must be a whole number >= 0`);
	}
	return parsed;
}

export function polyline(
	points: ExerciseProgressPoint[],
	key: 'topWeightKg' | 'estimated1rmKg'
): string {
	if (points.length === 0) return '';
	const width = 680;
	const height = 240;
	const padding = 20;
	const chartWidth = width - padding * 2;
	const chartHeight = height - padding * 2;
	const allValues = points.flatMap((p) => [p.topWeightKg, p.estimated1rmKg]);
	const minValue = Math.min(...allValues);
	const maxValue = Math.max(...allValues);
	const span = maxValue === minValue ? 1 : maxValue - minValue;

	return points
		.map((point, index) => {
			const x = points.length === 1 ? width / 2 : padding + (index * chartWidth) / (points.length - 1);
			const y = padding + ((maxValue - point[key]) / span) * chartHeight;
			return `${x},${y}`;
		})
		.join(' ');
}
