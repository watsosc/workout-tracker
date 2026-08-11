<script lang="ts">
	import { onMount } from 'svelte';
	import {
		addDayToActivePlan,
		addExerciseToActivePlan,
		fetchActivePlan,
		moveExerciseToDay,
		removeDayFromActivePlan,
		removeExerciseFromActivePlan,
		seedPlan
	} from '$lib/workout-api';
	import type {
		ActivePlan,
		AddExerciseToPlanInput,
		Protocol,
		SeedExerciseInput,
		SeedWorkoutExerciseInput,
		SeedWorkoutInput
	} from '$lib/types';
	import { pushToast } from '$lib/toast';
	import {
		convertKgToUnit,
		convertUnitToKg,
		displayWeightFromKg,
		getPreferredWeightUnit,
		parseNonNegativeFloat,
		parsePositiveFloat,
		parsePositiveInt,
		parseNonNegativeInt,
		type WeightUnit,
		weightUnitLabel
	} from '$lib/ui';

	type PlanCreateMode = 'GZCLP' | 'CUSTOM';
	type Tier = 'T1' | 'T2' | 'T3';

	type GzclpExerciseDraft = {
		id: string;
		name: string;
		tier: Tier;
		baseline1rm: string;
		startWeight: string;
		progression: string;
	};

	type GzclpDayDraft = {
		id: string;
		name: string;
		exercises: GzclpExerciseDraft[];
	};

	type CustomExerciseRow = {
		id: string;
		name: string;
		baseline: string;
		sets: string;
		reps: string;
		weight: string;
		progressionValue: string;
		protocol: Protocol;
	};

	type CustomDayDraft = {
		id: string;
		name: string;
		exercises: CustomExerciseRow[];
	};

	type DropPosition = 'before' | 'after';
	type DayDropState = { dayId: string; valid: boolean };
	type ExerciseDropState = {
		dayId: string;
		exerciseId: string;
		valid: boolean;
		position: DropPosition;
	};
	type ActiveDayDropState = { dayIndex: number; valid: boolean };
	type ActiveExerciseDropState = {
		dayIndex: number;
		exerciseId: number;
		valid: boolean;
		position: DropPosition;
	};

	let loading = $state(false);
	let errorMessage = $state('');
	let infoMessage = $state('');
	let activePlan = $state<ActivePlan | null>(null);

	let planCreateMode = $state<PlanCreateMode>('GZCLP');

	let gzclpPlanName = $state('GZCLP');
	let gzclpDays = $state<GzclpDayDraft[]>([]);

	let customPlanName = $state('My Custom Plan');
	let customDays = $state<CustomDayDraft[]>([]);

	let addExerciseName = $state('');
	let addExerciseBaseline = $state('');
	let addExerciseProtocol = $state<Protocol>('GZCLP_T3');
	let addExerciseSets = $state('3');
	let addExerciseReps = $state('15');
	let addExerciseWeight = $state('30');
	let addExerciseProgression = $state('2.5');
	let addExerciseTargetDay = $state('0');
	let newDayName = $state('');
	let weightUnit = $state<WeightUnit>('lb');

	let draggedGzclp = $state<{ sourceDayId: string; exerciseId: string } | null>(null);
	let gzclpDropTarget = $state<DayDropState | null>(null);
	let gzclpDropExerciseTarget = $state<ExerciseDropState | null>(null);
	let draggedCustom = $state<{ sourceDayId: string; exerciseId: string } | null>(null);
	let customDropTarget = $state<DayDropState | null>(null);
	let customDropExerciseTarget = $state<ExerciseDropState | null>(null);
	let gzclpStartWeightFocus = $state<Record<string, boolean>>({});
	let gzclpStartWeightDraft = $state<Record<string, string>>({});
	let draggedActive = $state<{ sourceDayIndex: number; exerciseId: number } | null>(null);
	let activeDropTarget = $state<ActiveDayDropState | null>(null);
	let activeDropExerciseTarget = $state<ActiveExerciseDropState | null>(null);

	function displayFromKg(valueKg: number): string {
		return displayWeightFromKg(valueKg, weightUnit);
	}

	function formatDisplayWeight(value: number): string {
		return String(Number(value.toFixed(2)));
	}

	function activeTierProtocolLabel(tier: Tier | null, protocol: Protocol): string {
		if (tier) return tier;
		if (protocol === 'BASIC') return 'Basic';
		return protocol;
	}

	function setTransparentDragPreview(event: DragEvent) {
		if (!event.dataTransfer) return;
		const img = new Image();
		img.src =
			'data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/%3E';
		event.dataTransfer.setDragImage(img, 0, 0);
	}

	function makeExerciseDraft(tier: Tier = 'T3'): GzclpExerciseDraft {
		return {
			id: crypto.randomUUID(),
			name: '',
			tier,
			baseline1rm: '',
			startWeight:
				tier === 'T3' ? formatDisplayWeight(roundDisplayWeightToValidStep(convertKgToUnit(30, weightUnit))) : '0',
			progression: formatDisplayWeight(validIncrementInDisplayUnit())
		};
	}

	function makeDayDraft(index: number): GzclpDayDraft {
		return {
			id: crypto.randomUUID(),
			name: `Day ${index + 1}`,
			exercises: []
		};
	}

	function makeCustomExerciseRow(): CustomExerciseRow {
		return {
			id: crypto.randomUUID(),
			name: '',
			baseline: '',
			sets: '3',
			reps: '10',
			weight: formatDisplayWeight(roundDisplayWeightToValidStep(convertKgToUnit(40, weightUnit))),
			progressionValue: formatDisplayWeight(validIncrementInDisplayUnit()),
			protocol: 'BASIC'
		};
	}

	function makeCustomDay(index: number): CustomDayDraft {
		return {
			id: crypto.randomUUID(),
			name: `Day ${index + 1}`,
			exercises: [makeCustomExerciseRow()]
		};
	}

	function protocolDefaults(protocol: Protocol) {
		if (protocol === 'GZCLP_T1') return { sets: 5, reps: 3 };
		if (protocol === 'GZCLP_T2') return { sets: 3, reps: 10 };
		if (protocol === 'GZCLP_T3') return { sets: 3, reps: 15 };
		return { sets: 3, reps: 10 };
	}

	function tierToProtocol(tier: Tier): Protocol {
		if (tier === 'T1') return 'GZCLP_T1';
		if (tier === 'T2') return 'GZCLP_T2';
		return 'GZCLP_T3';
	}

	function parseDraftBaseline(value: string): number | null {
		const parsed = Number(value);
		if (!Number.isFinite(parsed) || parsed <= 0) return null;
		return parsed;
	}

	function baselineForGzclpExercise(exercise: GzclpExerciseDraft): number | null {
		const own = parseDraftBaseline(exercise.baseline1rm);
		if (own !== null) return own;

		const name = exercise.name.trim();
		if (!name) return null;

		for (const day of gzclpDays) {
			for (const row of day.exercises) {
				if (row.id === exercise.id || row.tier === 'T3') continue;
				if (row.name.trim() !== name) continue;
				const candidate = parseDraftBaseline(row.baseline1rm);
				if (candidate !== null) return candidate;
			}
		}

		return null;
	}

	function validIncrementInDisplayUnit(): number {
		return weightUnit === 'lb' ? 5 : 2.5;
	}

	function validIncrementKg(): number {
		return convertUnitToKg(validIncrementInDisplayUnit(), weightUnit);
	}

	function roundDisplayWeightToValidStep(value: number): number {
		const inc = validIncrementInDisplayUnit();
		return Math.round(value / inc) * inc;
	}

	function normalizeExerciseName(name: string): string {
		return name.trim().toLowerCase();
	}

	function baselineForMatchingGzclpName(name: string, excludeExerciseId?: string): string | null {
		const key = normalizeExerciseName(name);
		if (!key) return null;
		for (const day of gzclpDays) {
			for (const row of day.exercises) {
				if (row.id === excludeExerciseId || row.tier === 'T3') continue;
				if (normalizeExerciseName(row.name) !== key) continue;
				if (row.baseline1rm.trim()) return row.baseline1rm;
			}
		}
		return null;
	}

	function setGzclpExerciseName(dayId: string, exerciseId: string, name: string) {
		const sharedBaseline = baselineForMatchingGzclpName(name, exerciseId);
		gzclpDays = gzclpDays.map((day) => {
			if (day.id !== dayId) return day;
			return {
				...day,
				exercises: day.exercises.map((exercise) => {
					if (exercise.id !== exerciseId) return exercise;
					if (exercise.tier === 'T3' || !sharedBaseline) return { ...exercise, name };
					return { ...exercise, name, baseline1rm: sharedBaseline };
				})
			};
		});
	}

	function setGzclpBaseline(dayId: string, exerciseId: string, baseline1rm: string) {
		const sourceDay = gzclpDays.find((day) => day.id === dayId);
		const sourceExercise = sourceDay?.exercises.find((exercise) => exercise.id === exerciseId);
		if (!sourceExercise || sourceExercise.tier === 'T3') return;

		const key = normalizeExerciseName(sourceExercise.name);
		gzclpDays = gzclpDays.map((day) => ({
			...day,
			exercises: day.exercises.map((exercise) => {
				if (exercise.id === exerciseId) return { ...exercise, baseline1rm };
				if (exercise.tier === 'T3' || !key) return exercise;
				if (normalizeExerciseName(exercise.name) !== key) return exercise;
				return { ...exercise, baseline1rm };
			})
		}));
	}

	function gzclpRatioForTier(tier: Tier): number {
		return tier === 'T1' ? 0.85 : tier === 'T2' ? 0.65 : 1;
	}

	function computedStartWeightKg(exercise: GzclpExerciseDraft): string {
		if (exercise.tier === 'T3') return exercise.startWeight;
		const baseline = baselineForGzclpExercise(exercise);
		if (baseline === null) return '';
		const ratio = gzclpRatioForTier(exercise.tier);
		return String(Number(roundDisplayWeightToValidStep(baseline * ratio).toFixed(2)));
	}

	function displayedGzclpStartWeight(exercise: GzclpExerciseDraft): string {
		if (exercise.tier === 'T3') return exercise.startWeight;
		if (gzclpStartWeightFocus[exercise.id]) {
			return gzclpStartWeightDraft[exercise.id] ?? computedStartWeightKg(exercise);
		}
		return computedStartWeightKg(exercise);
	}

	function setGzclpStartWeight(dayId: string, exerciseId: string, startWeight: string) {
		const sourceDay = gzclpDays.find((day) => day.id === dayId);
		const sourceExercise = sourceDay?.exercises.find((exercise) => exercise.id === exerciseId);
		if (!sourceExercise || sourceExercise.tier === 'T3') return;

		const raw = startWeight.trim();
		if (!raw) {
			setGzclpBaseline(dayId, exerciseId, '');
			return;
		}

		const parsed = Number(raw);
		if (!Number.isFinite(parsed) || parsed <= 0) return;
		const ratio = gzclpRatioForTier(sourceExercise.tier);
		const computedBaseline = parsed / ratio;
		setGzclpBaseline(dayId, exerciseId, String(Number(computedBaseline.toFixed(2))));
	}

	function onGzclpStartWeightFocus(exercise: GzclpExerciseDraft) {
		if (exercise.tier === 'T3') return;
		gzclpStartWeightFocus = { ...gzclpStartWeightFocus, [exercise.id]: true };
		gzclpStartWeightDraft = {
			...gzclpStartWeightDraft,
			[exercise.id]: computedStartWeightKg(exercise)
		};
	}

	function onGzclpStartWeightInput(dayId: string, exerciseId: string, value: string) {
		gzclpStartWeightDraft = { ...gzclpStartWeightDraft, [exerciseId]: value };
		setGzclpStartWeight(dayId, exerciseId, value);
	}

	function onGzclpStartWeightBlur(dayId: string, exerciseId: string) {
		const value = gzclpStartWeightDraft[exerciseId] ?? '';
		setGzclpStartWeight(dayId, exerciseId, value);
		gzclpStartWeightFocus = { ...gzclpStartWeightFocus, [exerciseId]: false };
		const nextDraft = { ...gzclpStartWeightDraft };
		delete nextDraft[exerciseId];
		gzclpStartWeightDraft = nextDraft;
	}

	function addProtocolRequiresBaseline(protocol: Protocol): boolean {
		return protocol === 'GZCLP_T1' || protocol === 'GZCLP_T2';
	}

	function setAddProtocol(protocol: Protocol) {
		addExerciseProtocol = protocol;
		const defaults = protocolDefaults(protocol);
		addExerciseSets = String(defaults.sets);
		addExerciseReps = String(defaults.reps);
		if (protocol === 'GZCLP_T1' || protocol === 'GZCLP_T2') addExerciseWeight = '0';
		if (protocol === 'GZCLP_T3') {
			addExerciseWeight = formatDisplayWeight(
				roundDisplayWeightToValidStep(convertKgToUnit(30, weightUnit))
			);
		}
	}

	function setCustomProtocol(dayId: string, exerciseId: string, protocol: Protocol) {
		const next = customDays.map((day) => {
			if (day.id !== dayId) return day;
			return {
				...day,
				exercises: day.exercises.map((row) => {
					if (row.id !== exerciseId) return row;
					const defaults = protocolDefaults(protocol);
					return {
						...row,
						protocol,
						sets: String(defaults.sets),
						reps: String(defaults.reps)
					};
				})
			};
		});

		const day = next.find((d) => d.id === dayId);
		if (day && !isNonDecreasing(day.exercises.map((row) => tierRankFromProtocol(row.protocol)))) {
			errorMessage = 'Tier order must be T1 before T2 before T3';
			return;
		}

		customDays = next;
	}

	function addCustomDay() {
		customDays = [...customDays, makeCustomDay(customDays.length)];
	}

	function removeCustomDay(dayId: string) {
		if (customDays.length <= 1) return;
		customDays = customDays.filter((day) => day.id !== dayId);
	}

	function addCustomExercise(dayId: string) {
		customDays = customDays.map((day) =>
			day.id === dayId ? { ...day, exercises: [...day.exercises, makeCustomExerciseRow()] } : day
		);
	}

	function removeCustomExercise(dayId: string, exerciseId: string) {
		customDays = customDays.map((day) => {
			if (day.id !== dayId) return day;
			if (day.exercises.length <= 1) return day;
			return { ...day, exercises: day.exercises.filter((row) => row.id !== exerciseId) };
		});
	}

	function moveCustomExerciseToDay(
		sourceDayId: string,
		exerciseId: string,
		targetDayId: string,
		targetExerciseId: string | null = null,
		targetPosition: DropPosition = 'before'
	) {
		const sourceDay = customDays.find((day) => day.id === sourceDayId);
		const movingRow = sourceDay?.exercises.find((row) => row.id === exerciseId);
		if (!movingRow) return;
		const movingRank = tierRankFromProtocol(movingRow.protocol);

		customDays = customDays.map((day) => {
			if (day.id !== sourceDayId) return day;
			return { ...day, exercises: day.exercises.filter((row) => row.id !== exerciseId) };
		});

		customDays = customDays.map((day) => {
			if (day.id !== targetDayId) return day;
			const next = [...day.exercises];
			const insertAt = findTierInsertIndex(
				next,
				movingRank,
				(row) => tierRankFromProtocol(row.protocol),
				targetExerciseId,
				targetPosition
			);
			next.splice(insertAt, 0, movingRow);
			return { ...day, exercises: next };
		});
	}

	function tierRankFromProtocol(protocol: Protocol): number {
		if (protocol === 'GZCLP_T1') return 1;
		if (protocol === 'GZCLP_T2') return 2;
		return 3;
	}

	function tierRankFromTier(tier: Tier): number {
		if (tier === 'T1') return 1;
		if (tier === 'T2') return 2;
		return 3;
	}

	function isNonDecreasing(values: number[]): boolean {
		for (let i = 1; i < values.length; i += 1) {
			if (values[i] < values[i - 1]) return false;
		}
		return true;
	}

	function findTierInsertIndex<T extends { id: string }>(
		exercises: T[],
		movingRank: number,
		getRank: (row: T) => number,
		targetExerciseId: string | null,
		targetPosition: DropPosition
	): number {
		if (targetExerciseId) {
			const targetIndex = exercises.findIndex((row) => row.id === targetExerciseId);
			if (targetIndex >= 0) {
				return targetPosition === 'after' ? targetIndex + 1 : targetIndex;
			}
		}

		let index = 0;
		while (index < exercises.length && getRank(exercises[index]) <= movingRank) {
			index += 1;
		}
		return index;
	}

	function dropPositionFromEvent(event: DragEvent): DropPosition {
		const element = event.currentTarget as HTMLElement | null;
		if (!element) return 'after';
		const rect = element.getBoundingClientRect();
		return event.clientY < rect.top + rect.height / 2 ? 'before' : 'after';
	}

	function isCustomRowDropValid(
		dayId: string,
		targetExerciseId: string,
		position: DropPosition
	): boolean {
		if (!draggedCustom) return false;
		const sourceDay = customDays.find((day) => day.id === draggedCustom?.sourceDayId);
		const moving = sourceDay?.exercises.find((row) => row.id === draggedCustom?.exerciseId);
		const targetDay = customDays.find((day) => day.id === dayId);
		if (!sourceDay || !moving || !targetDay) return false;

		const sourceWithoutMoving = sourceDay.exercises.filter((row) => row.id !== moving.id);
		const targetExercises = sourceDay.id === dayId ? sourceWithoutMoving : [...targetDay.exercises];
		const targetIndex = targetExercises.findIndex((row) => row.id === targetExerciseId);
		if (targetIndex < 0) return false;

		const insertAt = position === 'after' ? targetIndex + 1 : targetIndex;
		const next = [...targetExercises];
		next.splice(insertAt, 0, moving);
		return isNonDecreasing(next.map((row) => tierRankFromProtocol(row.protocol)));
	}

	function isGzclpRowDropValid(
		dayId: string,
		targetExerciseId: string,
		position: DropPosition
	): boolean {
		if (!draggedGzclp) return false;
		const sourceDay = gzclpDays.find((day) => day.id === draggedGzclp?.sourceDayId);
		const moving = sourceDay?.exercises.find((exercise) => exercise.id === draggedGzclp?.exerciseId);
		const targetDay = gzclpDays.find((day) => day.id === dayId);
		if (!sourceDay || !moving || !targetDay) return false;

		const sourceWithoutMoving = sourceDay.exercises.filter((exercise) => exercise.id !== moving.id);
		const targetExercises = sourceDay.id === dayId ? sourceWithoutMoving : [...targetDay.exercises];
		const targetIndex = targetExercises.findIndex((exercise) => exercise.id === targetExerciseId);
		if (targetIndex < 0) return false;

		const insertAt = position === 'after' ? targetIndex + 1 : targetIndex;
		const next = [...targetExercises];
		next.splice(insertAt, 0, moving);
		return isNonDecreasing(next.map((exercise) => tierRankFromTier(exercise.tier)));
	}

	function onCustomDragStart(dayId: string, exerciseId: string, event: DragEvent) {
		draggedCustom = { sourceDayId: dayId, exerciseId };
		if (event.dataTransfer) {
			event.dataTransfer.effectAllowed = 'move';
			event.dataTransfer.setData('text/plain', exerciseId);
			setTransparentDragPreview(event);
		}
	}

	function onCustomDragOver(dayId: string, event: DragEvent) {
		if (!draggedCustom) return;
		event.preventDefault();
		const valid = draggedCustom.sourceDayId !== dayId;
		customDropTarget = { dayId, valid };
		customDropExerciseTarget = null;
		if (event.dataTransfer) event.dataTransfer.dropEffect = valid ? 'move' : 'none';
	}

	function onCustomRowDragOver(dayId: string, targetExerciseId: string, event: DragEvent) {
		if (!draggedCustom) return;
		event.preventDefault();
		event.stopPropagation();
		const position = dropPositionFromEvent(event);
		const valid = isCustomRowDropValid(dayId, targetExerciseId, position);
		customDropTarget = { dayId, valid };
		customDropExerciseTarget = { dayId, exerciseId: targetExerciseId, valid, position };
		if (event.dataTransfer) event.dataTransfer.dropEffect = valid ? 'move' : 'none';
	}

	function onCustomDrop(dayId: string, event: DragEvent) {
		event.preventDefault();
		if (draggedCustom && draggedCustom.sourceDayId !== dayId) {
			moveCustomExerciseToDay(draggedCustom.sourceDayId, draggedCustom.exerciseId, dayId);
		}
		draggedCustom = null;
		customDropTarget = null;
		customDropExerciseTarget = null;
	}

	function onCustomRowDrop(dayId: string, targetExerciseId: string, event: DragEvent) {
		event.preventDefault();
		event.stopPropagation();
		const dropState = customDropExerciseTarget;
		if (
			draggedCustom &&
			dropState &&
			dropState.dayId === dayId &&
			dropState.exerciseId === targetExerciseId &&
			dropState.valid
		) {
			moveCustomExerciseToDay(
				draggedCustom.sourceDayId,
				draggedCustom.exerciseId,
				dayId,
				targetExerciseId,
				dropState.position
			);
		}
		draggedCustom = null;
		customDropTarget = null;
		customDropExerciseTarget = null;
	}

	function onCustomDragEnd() {
		draggedCustom = null;
		customDropTarget = null;
		customDropExerciseTarget = null;
	}

	function addGzclpDay() {
		gzclpDays = [...gzclpDays, makeDayDraft(gzclpDays.length)];
	}

	function removeGzclpDay(dayId: string) {
		if (gzclpDays.length <= 1) return;
		gzclpDays = gzclpDays
			.filter((d) => d.id !== dayId)
			.map((d, index) => ({ ...d, name: d.name || `Day ${index + 1}` }));
	}

	function addGzclpExercise(dayId: string) {
		gzclpDays = gzclpDays.map((day) =>
			day.id === dayId ? { ...day, exercises: [...day.exercises, makeExerciseDraft('T3')] } : day
		);
	}

	function removeGzclpExercise(dayId: string, exerciseId: string) {
		gzclpDays = gzclpDays.map((day) =>
			day.id === dayId
				? { ...day, exercises: day.exercises.filter((exercise) => exercise.id !== exerciseId) }
				: day
		);
		const nextFocus = { ...gzclpStartWeightFocus };
		delete nextFocus[exerciseId];
		gzclpStartWeightFocus = nextFocus;
		const nextDraft = { ...gzclpStartWeightDraft };
		delete nextDraft[exerciseId];
		gzclpStartWeightDraft = nextDraft;
	}

	function setGzclpExerciseTier(dayId: string, exerciseId: string, tier: Tier) {
		const sourceDay = gzclpDays.find((day) => day.id === dayId);
		const sourceExercise = sourceDay?.exercises.find((exercise) => exercise.id === exerciseId);
		const sharedBaseline = sourceExercise
			? baselineForMatchingGzclpName(sourceExercise.name, exerciseId)
			: null;

		const next = gzclpDays.map((day) => {
			if (day.id !== dayId) return day;
			return {
				...day,
				exercises: day.exercises.map((exercise) => {
					if (exercise.id !== exerciseId) return exercise;
					return {
						...exercise,
						tier,
						baseline1rm:
							tier === 'T3'
								? exercise.baseline1rm
								: sharedBaseline ?? exercise.baseline1rm,
						startWeight: tier === 'T3' ? (exercise.startWeight || '30') : '0'
					};
				})
			};
		});

		const day = next.find((d) => d.id === dayId);
		if (day && !isNonDecreasing(day.exercises.map((exercise) => tierRankFromTier(exercise.tier)))) {
			errorMessage = 'Tier order must be T1 before T2 before T3';
			return;
		}

		gzclpDays = next;
		if (tier === 'T3') {
			const nextFocus = { ...gzclpStartWeightFocus };
			delete nextFocus[exerciseId];
			gzclpStartWeightFocus = nextFocus;
			const nextDraft = { ...gzclpStartWeightDraft };
			delete nextDraft[exerciseId];
			gzclpStartWeightDraft = nextDraft;
		}
	}

	function moveGzclpExerciseToDay(
		sourceDayId: string,
		exerciseId: string,
		targetDayId: string,
		targetExerciseId: string | null = null,
		targetPosition: DropPosition = 'before'
	) {
		const sourceDay = gzclpDays.find((day) => day.id === sourceDayId);
		const movingExercise = sourceDay?.exercises.find((exercise) => exercise.id === exerciseId);
		if (!movingExercise) return;
		const movingRank = tierRankFromTier(movingExercise.tier);

		gzclpDays = gzclpDays.map((day) => {
			if (day.id !== sourceDayId) return day;
			return {
				...day,
				exercises: day.exercises.filter((exercise) => exercise.id !== exerciseId)
			};
		});

		gzclpDays = gzclpDays.map((day) => {
			if (day.id !== targetDayId) return day;
			const next = [...day.exercises];
			const insertAt = findTierInsertIndex(
				next,
				movingRank,
				(exercise) => tierRankFromTier(exercise.tier),
				targetExerciseId,
				targetPosition
			);
			next.splice(insertAt, 0, movingExercise);
			return { ...day, exercises: next };
		});
	}

	function onGzclpDragStart(dayId: string, exerciseId: string, event: DragEvent) {
		draggedGzclp = { sourceDayId: dayId, exerciseId };
		if (event.dataTransfer) {
			event.dataTransfer.effectAllowed = 'move';
			event.dataTransfer.setData('text/plain', exerciseId);
			setTransparentDragPreview(event);
		}
	}

	function onGzclpDragOver(dayId: string, event: DragEvent) {
		if (!draggedGzclp) return;
		event.preventDefault();
		const valid = draggedGzclp.sourceDayId !== dayId;
		gzclpDropTarget = { dayId, valid };
		gzclpDropExerciseTarget = null;
		if (event.dataTransfer) event.dataTransfer.dropEffect = valid ? 'move' : 'none';
	}

	function onGzclpRowDragOver(dayId: string, targetExerciseId: string, event: DragEvent) {
		if (!draggedGzclp) return;
		event.preventDefault();
		event.stopPropagation();
		const position = dropPositionFromEvent(event);
		const valid = isGzclpRowDropValid(dayId, targetExerciseId, position);
		gzclpDropTarget = { dayId, valid };
		gzclpDropExerciseTarget = { dayId, exerciseId: targetExerciseId, valid, position };
		if (event.dataTransfer) event.dataTransfer.dropEffect = valid ? 'move' : 'none';
	}

	function onGzclpDrop(dayId: string, event: DragEvent) {
		event.preventDefault();
		if (draggedGzclp && draggedGzclp.sourceDayId !== dayId) {
			moveGzclpExerciseToDay(draggedGzclp.sourceDayId, draggedGzclp.exerciseId, dayId);
		}
		draggedGzclp = null;
		gzclpDropTarget = null;
		gzclpDropExerciseTarget = null;
	}

	function onGzclpRowDrop(dayId: string, targetExerciseId: string, event: DragEvent) {
		event.preventDefault();
		event.stopPropagation();
		const dropState = gzclpDropExerciseTarget;
		if (
			draggedGzclp &&
			dropState &&
			dropState.dayId === dayId &&
			dropState.exerciseId === targetExerciseId &&
			dropState.valid
		) {
			moveGzclpExerciseToDay(
				draggedGzclp.sourceDayId,
				draggedGzclp.exerciseId,
				dayId,
				targetExerciseId,
				dropState.position
			);
		}
		draggedGzclp = null;
		gzclpDropTarget = null;
		gzclpDropExerciseTarget = null;
	}

	function onGzclpDragEnd() {
		draggedGzclp = null;
		gzclpDropTarget = null;
		gzclpDropExerciseTarget = null;
	}

	function ensureDefaultGzclpDraft() {
		if (gzclpDays.length > 0) return;

		const ex = (
			name: string,
			tier: Tier,
			progressionKg: number,
			startWeightKg: number = tier === 'T3' ? 30 : 0
		): GzclpExerciseDraft => ({
			id: crypto.randomUUID(),
			name,
			tier,
			baseline1rm: '',
			startWeight:
				tier === 'T3'
					? formatDisplayWeight(
							roundDisplayWeightToValidStep(convertKgToUnit(startWeightKg, weightUnit))
						)
					: '0',
			progression: formatDisplayWeight(
				roundDisplayWeightToValidStep(convertKgToUnit(progressionKg, weightUnit))
			)
		});

		gzclpDays = [
			{
				id: crypto.randomUUID(),
				name: 'Day 1',
				exercises: [
					ex('Squat', 'T1', 2.5, 0),
					ex('Bench Press', 'T2', 2.5, 0),
					ex('Lat Pulldown', 'T3', 2.5, 35),
					ex('Tricep Pressdowns', 'T3', 2.5, 25)
				]
			},
			{
				id: crypto.randomUUID(),
				name: 'Day 2',
				exercises: [
					ex('Overhead Press', 'T1', 2.5, 0),
					ex('Deadlift', 'T2', 5, 0),
					ex('Dumbbell Rows', 'T3', 2.5, 25),
					ex('Bicep Curls', 'T3', 2.5, 15)
				]
			},
			{
				id: crypto.randomUUID(),
				name: 'Day 3',
				exercises: [
					ex('Bench Press', 'T1', 2.5, 0),
					ex('Squat', 'T2', 2.5, 0),
					ex('Lat Pulldown', 'T3', 2.5, 35),
					ex('Tricep Pressdowns', 'T3', 2.5, 25)
				]
			},
			{
				id: crypto.randomUUID(),
				name: 'Day 4',
				exercises: [
					ex('Deadlift', 'T1', 5, 0),
					ex('Overhead Press', 'T2', 2.5, 0),
					ex('Dumbbell Rows', 'T3', 2.5, 25),
					ex('Bicep Curls', 'T3', 2.5, 15)
				]
			}
		];
	}

	function ensureDefaultCustomDraft() {
		if (customDays.length > 0) return;
		customDays = [makeCustomDay(0)];
	}

	async function loadPlanPage() {
		activePlan = await fetchActivePlan();
		if (activePlan?.workouts.length) {
			addExerciseTargetDay = String(activePlan.workouts[0].sequenceIndex);
		}
	}

	async function runAction(action: () => Promise<void>, message?: string) {
		loading = true;
		errorMessage = '';
		try {
			await action();
			await loadPlanPage();
			if (message) {
				infoMessage = message;
				pushToast(message, 'success');
			}
		} catch (error) {
			errorMessage = error instanceof Error ? error.message : String(error);
			pushToast(errorMessage, 'error');
		} finally {
			loading = false;
		}
	}

	async function createGzclpPlan() {
		await runAction(async () => {
			if (!gzclpPlanName.trim()) throw new Error('Plan name is required');
			if (gzclpDays.length === 0) throw new Error('Add at least one day');

			const baselineByExerciseKey = new Map<string, number>();
			const exerciseNameByKey = new Map<string, string>();
			const requiredBaselineKeys = new Set<string>();
			const workouts: SeedWorkoutInput[] = [];

			for (let dayIndex = 0; dayIndex < gzclpDays.length; dayIndex += 1) {
				const day = gzclpDays[dayIndex];
				const dayName = day.name.trim() || `Day ${dayIndex + 1}`;
				if (!isNonDecreasing(day.exercises.map((exercise) => tierRankFromTier(exercise.tier)))) {
					throw new Error(`${dayName} has invalid tier order. Use T1 -> T2 -> T3.`);
				}
				const dayExercises: SeedWorkoutExerciseInput[] = [];

				for (const exercise of day.exercises) {
					const name = exercise.name.trim();
					if (!name) throw new Error(`Exercise name is required on ${dayName}`);

					const key = normalizeExerciseName(name);
					if (!exerciseNameByKey.has(key)) exerciseNameByKey.set(key, name);

					if (exercise.tier !== 'T3') {
						requiredBaselineKeys.add(key);
						const rawBaseline = exercise.baseline1rm.trim();
						if (rawBaseline) {
							const baseline = convertUnitToKg(
								parsePositiveFloat(rawBaseline, `${name} baseline 1RM`),
								weightUnit
							);
							if (
								baselineByExerciseKey.has(key) &&
								baselineByExerciseKey.get(key) !== baseline
							) {
								throw new Error(
									`Exercise ${name} has multiple baseline 1RM values. Keep them consistent.`
								);
							}
							baselineByExerciseKey.set(key, baseline);
						}
					}

					const progression = convertUnitToKg(
						parseNonNegativeFloat(exercise.progression, `${name} progression increment`),
						weightUnit
					);
					const protocol = tierToProtocol(exercise.tier);
					const defaults = protocolDefaults(protocol);

					let targetWeight = 0;
					if (exercise.tier === 'T3') {
						targetWeight = convertUnitToKg(
							parseNonNegativeFloat(exercise.startWeight, `${name} start weight`),
							weightUnit
						);
					}

					dayExercises.push({
						exerciseName: name,
						sets: defaults.sets,
						reps: defaults.reps,
						targetWeightKg: targetWeight,
						progressionType: 'LINEAR_KG',
						progressionProtocol: protocol,
						tier: exercise.tier,
						progressionValue: progression,
						weightIncrementKg: validIncrementKg()
					});
				}

				workouts.push({
					name: dayName,
					sequenceIndex: dayIndex,
					exercises: dayExercises
				});
			}

			for (const key of requiredBaselineKeys) {
				if (!baselineByExerciseKey.has(key)) {
					const name = exerciseNameByKey.get(key) ?? key;
					throw new Error(
						`Baseline 1RM is required for ${name} because it appears as Tier 1 or Tier 2.`
					);
				}
			}

			const exercises: SeedExerciseInput[] = Array.from(baselineByExerciseKey.entries()).map(
				([key, orm]) => ({
					name: exerciseNameByKey.get(key) ?? key,
					baseline1rmKg: orm
				})
			);

			await seedPlan({
				planName: gzclpPlanName.trim(),
				totalWeeks: null,
				daysPerWeek: gzclpDays.length,
				exercises,
				workouts
			});
		}, 'Created GZCLP plan');
	}

	async function createCustomPlan() {
		await runAction(async () => {
			if (!customPlanName.trim()) throw new Error('Plan name is required');
			if (customDays.length === 0) throw new Error('Add at least one day');

			const uniqueBaseline = new Map<string, number>();
			const workouts: SeedWorkoutInput[] = [];

			for (let dayIndex = 0; dayIndex < customDays.length; dayIndex += 1) {
				const day = customDays[dayIndex];
				const dayName = day.name.trim() || `Day ${dayIndex + 1}`;
				if (!isNonDecreasing(day.exercises.map((row) => tierRankFromProtocol(row.protocol)))) {
					throw new Error(`${dayName} has invalid tier order. Use T1 -> T2 -> T3.`);
				}
				const rows = day.exercises.map((row) => ({ ...row, name: row.name.trim() }));
				if (rows.some((row) => !row.name)) throw new Error(`Each exercise needs a name on ${dayName}`);

				const workoutExercises: SeedWorkoutExerciseInput[] = [];
				for (const row of rows) {
					const baseline = convertUnitToKg(
						parsePositiveFloat(row.baseline, `${row.name} 1RM`),
						weightUnit
					);
					if (uniqueBaseline.has(row.name) && uniqueBaseline.get(row.name) !== baseline) {
						throw new Error(
							`Exercise ${row.name} has multiple baseline values. Keep them consistent across days.`
						);
					}
					uniqueBaseline.set(row.name, baseline);

					workoutExercises.push({
						exerciseName: row.name,
						sets: parsePositiveInt(row.sets, `${row.name} sets`),
						reps: parsePositiveInt(row.reps, `${row.name} reps`),
						targetWeightKg: convertUnitToKg(
							parseNonNegativeFloat(row.weight, `${row.name} weight`),
							weightUnit
						),
						progressionType: 'LINEAR_KG',
						progressionProtocol: row.protocol,
						progressionValue: convertUnitToKg(
							parseNonNegativeFloat(row.progressionValue, `${row.name} progression`),
							weightUnit
						),
						weightIncrementKg: validIncrementKg()
					});
				}

				workouts.push({
					name: dayName,
					sequenceIndex: dayIndex,
					exercises: workoutExercises
				});
			}

			const exercises: SeedExerciseInput[] = Array.from(uniqueBaseline.entries()).map(([name, orm]) => ({
				name,
				baseline1rmKg: orm
			}));

			await seedPlan({
				planName: customPlanName.trim(),
				totalWeeks: null,
				daysPerWeek: customDays.length,
				exercises,
				workouts
			});
		}, 'Created custom plan');
	}

	async function addExerciseToExistingPlan() {
		await runAction(async () => {
			if (!activePlan) throw new Error('No active plan loaded');
			const trimmedName = addExerciseName.trim();
			if (!trimmedName) throw new Error('Exercise name is required');

			const requiresBaseline = addProtocolRequiresBaseline(addExerciseProtocol);
			const baseline1rmKg = requiresBaseline
				? convertUnitToKg(parsePositiveFloat(addExerciseBaseline, `${trimmedName} 1RM`), weightUnit)
				: null;
			const targetWeightKg = requiresBaseline
				? 0
				: convertUnitToKg(parseNonNegativeFloat(addExerciseWeight, 'Start weight'), weightUnit);

			const input: AddExerciseToPlanInput = {
				workoutSequenceIndex: parseNonNegativeInt(addExerciseTargetDay, 'Target day index'),
				exerciseName: trimmedName,
				baseline1rmKg,
				sets: parsePositiveInt(addExerciseSets, 'Sets'),
				reps: parsePositiveInt(addExerciseReps, 'Reps'),
				targetWeightKg,
				progressionType: 'LINEAR_KG',
				progressionProtocol: addExerciseProtocol,
				progressionValue: convertUnitToKg(
					parseNonNegativeFloat(addExerciseProgression, 'Progression step'),
					weightUnit
				),
				weightIncrementKg: validIncrementKg()
			};

			await addExerciseToActivePlan(input);
			addExerciseName = '';
			addExerciseBaseline = '';
		}, 'Added exercise to active plan');
	}

	async function addDayToExistingPlan() {
		await runAction(
			() => addDayToActivePlan(newDayName.trim() || undefined),
			'Added day to active plan'
		);
		newDayName = '';
	}

	async function removeDayFromExistingPlan(sequenceIndex: number) {
		await runAction(
			() => removeDayFromActivePlan(sequenceIndex),
			`Removed day ${sequenceIndex}`
		);
	}

	async function removeExerciseFromExistingDay(planExerciseId: number) {
		await runAction(
			() => removeExerciseFromActivePlan(planExerciseId),
			'Removed exercise from active plan'
		);
	}

	function clearActiveDragState() {
		draggedActive = null;
		activeDropTarget = null;
		activeDropExerciseTarget = null;
	}

	function onActiveDragStart(sourceDayIndex: number, exerciseId: number, event: DragEvent) {
		draggedActive = { sourceDayIndex, exerciseId };
		if (event.dataTransfer) {
			event.dataTransfer.effectAllowed = 'move';
			event.dataTransfer.setData('text/plain', String(exerciseId));
			setTransparentDragPreview(event);
		}
	}

	function onActiveDragOver(targetDayIndex: number, event: DragEvent) {
		if (!draggedActive) return;
		event.preventDefault();
		const valid = draggedActive.sourceDayIndex !== targetDayIndex;
		activeDropTarget = { dayIndex: targetDayIndex, valid };
		activeDropExerciseTarget = null;
		if (event.dataTransfer) event.dataTransfer.dropEffect = valid ? 'move' : 'none';
	}

	function onActiveRowDragOver(targetDayIndex: number, targetExerciseId: number, event: DragEvent) {
		if (!draggedActive) return;
		event.preventDefault();
		event.stopPropagation();
		const position = dropPositionFromEvent(event);
		const valid = draggedActive.sourceDayIndex !== targetDayIndex;
		activeDropTarget = { dayIndex: targetDayIndex, valid };
		activeDropExerciseTarget = {
			dayIndex: targetDayIndex,
			exerciseId: targetExerciseId,
			valid,
			position
		};
		if (event.dataTransfer) event.dataTransfer.dropEffect = valid ? 'move' : 'none';
	}

	async function moveActiveDraggedExercise(targetDayIndex: number) {
		const dragged = draggedActive;
		if (!dragged || dragged.sourceDayIndex === targetDayIndex) return;
		await runAction(
			() => moveExerciseToDay(dragged.exerciseId, targetDayIndex),
			'Moved exercise to selected day'
		);
	}

	async function onActiveDrop(targetDayIndex: number, event: DragEvent) {
		event.preventDefault();
		try {
			await moveActiveDraggedExercise(targetDayIndex);
		} finally {
			clearActiveDragState();
		}
	}

	async function onActiveRowDrop(targetDayIndex: number, targetExerciseId: number, event: DragEvent) {
		event.preventDefault();
		event.stopPropagation();
		const dropState = activeDropExerciseTarget;
		try {
			if (
				dropState &&
				dropState.dayIndex === targetDayIndex &&
				dropState.exerciseId === targetExerciseId &&
				dropState.valid
			) {
				await moveActiveDraggedExercise(targetDayIndex);
			}
		} finally {
			clearActiveDragState();
		}
	}

	function onActiveDragEnd() {
		clearActiveDragState();
	}

	onMount(async () => {
		weightUnit = getPreferredWeightUnit();
		if (addExerciseProtocol === 'GZCLP_T3') {
			addExerciseWeight = formatDisplayWeight(
				roundDisplayWeightToValidStep(convertKgToUnit(30, weightUnit))
			);
		}
		addExerciseProgression = formatDisplayWeight(validIncrementInDisplayUnit());
		ensureDefaultGzclpDraft();
		ensureDefaultCustomDraft();
		loading = true;
		try {
			await loadPlanPage();
		} catch (error) {
			errorMessage = error instanceof Error ? error.message : String(error);
		} finally {
			loading = false;
		}
	});
</script>

<section class="card">
	<h1>Plan</h1>
	{#if activePlan}
		<p class="subtle">
			Active plan: <strong>{activePlan.name}</strong> · days/week: {activePlan.daysPerWeek} · week
			{activePlan.currentWeek}
		</p>
	{:else}
		<p class="subtle">No plan loaded. Create one now.</p>
	{/if}
</section>

{#if infoMessage}
	<p class="banner success">{infoMessage}</p>
{/if}
{#if errorMessage}
	<p class="banner error">{errorMessage}</p>
{/if}

{#if !activePlan}
	<section class="card">
		<h2>Create Plan</h2>
		<div class="mode-toggle">
			<button class={planCreateMode === 'GZCLP' ? 'primary' : ''} onclick={() => (planCreateMode = 'GZCLP')}>
				GZCLP Template
			</button>
			<button class={planCreateMode === 'CUSTOM' ? 'primary' : ''} onclick={() => (planCreateMode = 'CUSTOM')}>
				Custom Plan
			</button>
		</div>

		{#if planCreateMode === 'GZCLP'}
			<div class="stack">
				<label>
					Plan name
					<input bind:value={gzclpPlanName} />
				</label>
				<p class="subtle">
					Add/remove days (Day 1, Day 2, ...), add exercises on each day, and move exercises between days.
				</p>
				<div class="inline-actions">
					<button onclick={addGzclpDay}>Add day</button>
				</div>

				<div class="day-grid">
					{#each gzclpDays as day, dayIndex}
						<article
							class="day-card"
							class:drop-target-valid={gzclpDropTarget?.dayId === day.id && gzclpDropTarget.valid}
							class:drop-target-invalid={gzclpDropTarget?.dayId === day.id && !gzclpDropTarget.valid}
							ondragover={(e) => onGzclpDragOver(day.id, e)}
							ondrop={(e) => onGzclpDrop(day.id, e)}
						>
							<div class="day-header">
								<label>
									Day name
									<input bind:value={gzclpDays[dayIndex].name} />
								</label>
								<button onclick={() => removeGzclpDay(day.id)} disabled={gzclpDays.length <= 1}>
									Remove day
								</button>
							</div>

							<div class="inline-actions">
								<button onclick={() => addGzclpExercise(day.id)}>Add exercise</button>
							</div>

							{#if day.exercises.length === 0}
								<p class="subtle">No exercises yet on this day.</p>
							{/if}

							{#each day.exercises as ex, exIndex}
								<div
									class="exercise-row"
									role="listitem"
									class:drop-slot-valid={
										gzclpDropExerciseTarget?.dayId === day.id &&
										gzclpDropExerciseTarget.exerciseId === ex.id &&
										gzclpDropExerciseTarget.valid
									}
									class:drop-slot-invalid={
										gzclpDropExerciseTarget?.dayId === day.id &&
										gzclpDropExerciseTarget.exerciseId === ex.id &&
										!gzclpDropExerciseTarget.valid
									}
									class:drop-before={
										gzclpDropExerciseTarget?.dayId === day.id &&
										gzclpDropExerciseTarget.exerciseId === ex.id &&
										gzclpDropExerciseTarget.position === 'before'
									}
									class:drop-after={
										gzclpDropExerciseTarget?.dayId === day.id &&
										gzclpDropExerciseTarget.exerciseId === ex.id &&
										gzclpDropExerciseTarget.position === 'after'
									}
									ondragover={(e) => onGzclpRowDragOver(day.id, ex.id, e)}
									ondrop={(e) => onGzclpRowDrop(day.id, ex.id, e)}
								>
									<div class="exercise-row-main">
										<button
											type="button"
											class="drag-handle"
											draggable="true"
											ondragstart={(e) => onGzclpDragStart(day.id, ex.id, e)}
											ondragend={onGzclpDragEnd}
											aria-label="Drag exercise"
											title="Drag to move exercise"
										>
											⋮⋮
										</button>
										<div class="row-grid">
										<label>
											Exercise
											<input
												bind:value={gzclpDays[dayIndex].exercises[exIndex].name}
												oninput={(e) => setGzclpExerciseName(day.id, ex.id, e.currentTarget.value)}
											/>
										</label>
										<label>
											Tier
											<select
												bind:value={gzclpDays[dayIndex].exercises[exIndex].tier}
												onchange={(e) =>
													setGzclpExerciseTier(
														day.id,
														ex.id,
														e.currentTarget.value as Tier
													)}
											>
												<option value="T1">Tier 1</option>
												<option value="T2">Tier 2</option>
												<option value="T3">Tier 3</option>
											</select>
										</label>
										{#if ex.tier !== 'T3'}
											<label>
												Baseline 1RM ({weightUnitLabel(weightUnit)})
												<input
													type="number"
													step="0.1"
													min="0"
													bind:value={gzclpDays[dayIndex].exercises[exIndex].baseline1rm}
													oninput={(e) => setGzclpBaseline(day.id, ex.id, e.currentTarget.value)}
												/>
											</label>
										{/if}
										{#if ex.tier === 'T3'}
											<label>
												Start weight ({weightUnitLabel(weightUnit)})
												<input
													type="number"
													step="0.1"
													min="0"
													bind:value={gzclpDays[dayIndex].exercises[exIndex].startWeight}
												/>
											</label>
										{:else}
											<label>
												Start weight ({weightUnitLabel(weightUnit)})
												<input
													type="number"
													step="0.1"
													min="0"
													value={displayedGzclpStartWeight(ex)}
													onfocus={() => onGzclpStartWeightFocus(ex)}
													oninput={(e) => onGzclpStartWeightInput(day.id, ex.id, e.currentTarget.value)}
													onblur={() => onGzclpStartWeightBlur(day.id, ex.id)}
												/>
											</label>
										{/if}
										<label>
											Progression step ({weightUnitLabel(weightUnit)})
											<input
												type="number"
												step="0.1"
												min="0"
												bind:value={gzclpDays[dayIndex].exercises[exIndex].progression}
											/>
										</label>
										</div>
										<button
											type="button"
											class="icon-danger"
											onclick={() => removeGzclpExercise(day.id, ex.id)}
											aria-label="Remove exercise"
											title="Remove exercise"
										>
											🗑
										</button>
									</div>
								</div>
							{/each}
						</article>
					{/each}
				</div>

				<button class="primary" onclick={createGzclpPlan} disabled={loading}>Create GZCLP Plan</button>
			</div>
		{:else}
			<div class="stack">
				<label>
					Plan name
					<input bind:value={customPlanName} />
				</label>
				<p class="subtle">Add/remove days and move exercises between days.</p>
				<div class="inline-actions">
					<button onclick={addCustomDay}>Add day</button>
				</div>

				<div class="day-grid">
					{#each customDays as day, dayIndex}
						<article
							class="day-card"
							class:drop-target-valid={customDropTarget?.dayId === day.id && customDropTarget.valid}
							class:drop-target-invalid={customDropTarget?.dayId === day.id && !customDropTarget.valid}
							ondragover={(e) => onCustomDragOver(day.id, e)}
							ondrop={(e) => onCustomDrop(day.id, e)}
						>
							<div class="day-header">
								<label>
									Day name
									<input bind:value={customDays[dayIndex].name} />
								</label>
								<button onclick={() => removeCustomDay(day.id)} disabled={customDays.length <= 1}>
									Remove day
								</button>
							</div>

							<div class="inline-actions">
								<button onclick={() => addCustomExercise(day.id)}>Add exercise</button>
							</div>

							{#each day.exercises as row, i}
								<div
									class="exercise-row"
									role="listitem"
									class:drop-slot-valid={
										customDropExerciseTarget?.dayId === day.id &&
										customDropExerciseTarget.exerciseId === row.id &&
										customDropExerciseTarget.valid
									}
									class:drop-slot-invalid={
										customDropExerciseTarget?.dayId === day.id &&
										customDropExerciseTarget.exerciseId === row.id &&
										!customDropExerciseTarget.valid
									}
									class:drop-before={
										customDropExerciseTarget?.dayId === day.id &&
										customDropExerciseTarget.exerciseId === row.id &&
										customDropExerciseTarget.position === 'before'
									}
									class:drop-after={
										customDropExerciseTarget?.dayId === day.id &&
										customDropExerciseTarget.exerciseId === row.id &&
										customDropExerciseTarget.position === 'after'
									}
									ondragover={(e) => onCustomRowDragOver(day.id, row.id, e)}
									ondrop={(e) => onCustomRowDrop(day.id, row.id, e)}
								>
									<div class="exercise-row-main">
										<button
											type="button"
											class="drag-handle"
											draggable="true"
											ondragstart={(e) => onCustomDragStart(day.id, row.id, e)}
											ondragend={onCustomDragEnd}
											aria-label="Drag exercise"
											title="Drag to move exercise"
										>
											⋮⋮
										</button>
										<div class="row-grid">
										<label>
											Exercise
											<input bind:value={customDays[dayIndex].exercises[i].name} />
										</label>
										<label>
											Baseline 1RM ({weightUnitLabel(weightUnit)})
											<input
												type="number"
												min="0"
												step="0.1"
												bind:value={customDays[dayIndex].exercises[i].baseline}
											/>
										</label>
										<label>
											Tier / protocol
											<select
												bind:value={customDays[dayIndex].exercises[i].protocol}
												onchange={(event) =>
													setCustomProtocol(day.id, row.id, event.currentTarget.value as Protocol)}
											>
												<option value="GZCLP_T1">Tier 1 (GZCLP T1)</option>
												<option value="GZCLP_T2">Tier 2 (GZCLP T2)</option>
												<option value="GZCLP_T3">Tier 3 (GZCLP T3)</option>
												<option value="BASIC">Basic</option>
											</select>
										</label>
										<label>
											Sets
											<input
												type="number"
												min="1"
												step="1"
												bind:value={customDays[dayIndex].exercises[i].sets}
											/>
										</label>
										<label>
											Reps
											<input
												type="number"
												min="1"
												step="1"
												bind:value={customDays[dayIndex].exercises[i].reps}
											/>
										</label>
										<label>
											Start weight ({weightUnitLabel(weightUnit)})
											<input
												type="number"
												min="0"
												step="0.1"
												bind:value={customDays[dayIndex].exercises[i].weight}
											/>
										</label>
										<label>
											Progression step ({weightUnitLabel(weightUnit)})
											<input
												type="number"
												min="0"
												step="0.1"
												bind:value={customDays[dayIndex].exercises[i].progressionValue}
											/>
										</label>
										</div>
										<button
											type="button"
											class="icon-danger"
											onclick={() => removeCustomExercise(day.id, row.id)}
											disabled={day.exercises.length <= 1}
											aria-label="Remove exercise"
											title="Remove exercise"
										>
											🗑
										</button>
									</div>
								</div>
							{/each}
						</article>
					{/each}
				</div>
				<div class="inline-actions">
					<button class="primary" onclick={createCustomPlan} disabled={loading}>Create Custom Plan</button>
				</div>
			</div>
		{/if}
	</section>
{:else}
	<section class="card">
		<h2>Edit Active Plan Days</h2>
		<p class="subtle">Add or remove plan days. Remove only works if the day has no exercises.</p>
		<div class="inline-actions">
			<input placeholder="Optional day name" bind:value={newDayName} />
			<button onclick={addDayToExistingPlan} disabled={loading}>Add day</button>
		</div>
	</section>

	<section class="card">
		<h2>Add exercise to existing plan</h2>
		<div class="form-grid">
			<label>
				Target day
				<select bind:value={addExerciseTargetDay}>
					{#each activePlan.workouts as workout}
						<option value={String(workout.sequenceIndex)}>{workout.name}</option>
					{/each}
				</select>
			</label>
			<label>
				Exercise name
				<input bind:value={addExerciseName} />
			</label>
			<label>
				Tier / protocol
				<select bind:value={addExerciseProtocol} onchange={(e) => setAddProtocol(e.currentTarget.value as Protocol)}>
					<option value="GZCLP_T1">Tier 1 (GZCLP T1)</option>
					<option value="GZCLP_T2">Tier 2 (GZCLP T2)</option>
					<option value="GZCLP_T3">Tier 3 (GZCLP T3)</option>
					<option value="BASIC">Basic</option>
				</select>
			</label>
			{#if addProtocolRequiresBaseline(addExerciseProtocol)}
				<label>
					Baseline 1RM ({weightUnitLabel(weightUnit)})
					<input type="number" min="0" step="0.1" bind:value={addExerciseBaseline} />
				</label>
			{:else}
				<label>
					Start weight ({weightUnitLabel(weightUnit)})
					<input type="number" min="0" step="0.1" bind:value={addExerciseWeight} />
				</label>
			{/if}
			<label>
				Sets
				<input type="number" min="1" step="1" bind:value={addExerciseSets} />
			</label>
			<label>
				Reps
				<input type="number" min="1" step="1" bind:value={addExerciseReps} />
			</label>
			<label>
				Progression step ({weightUnitLabel(weightUnit)})
				<input type="number" min="0" step="0.1" bind:value={addExerciseProgression} />
			</label>
		</div>
		<button class="primary" onclick={addExerciseToExistingPlan} disabled={loading}>Add Exercise</button>
	</section>

	<section class="card">
		<h2>Current day layout</h2>
		<p class="subtle">Drag exercises between days. Use the trash icon to remove an exercise.</p>
		<div class="day-grid">
			{#each activePlan.workouts as workout}
				<article
					class="day-card"
					class:drop-target-valid={
						activeDropTarget?.dayIndex === workout.sequenceIndex && activeDropTarget.valid
					}
					class:drop-target-invalid={
						activeDropTarget?.dayIndex === workout.sequenceIndex && !activeDropTarget.valid
					}
					ondragover={(e) => onActiveDragOver(workout.sequenceIndex, e)}
					ondrop={(e) => onActiveDrop(workout.sequenceIndex, e)}
				>
					<div class="day-header">
						<h3>{workout.name}</h3>
						<button
							onclick={() => removeDayFromExistingPlan(workout.sequenceIndex)}
							disabled={loading || activePlan.workouts.length <= 1}
						>
							Remove day
						</button>
					</div>
					<p class="subtle">Day {workout.sequenceIndex + 1}</p>

					{#if workout.exercises.length === 0}
						<p class="subtle">No exercises on this day.</p>
					{/if}

					{#each workout.exercises as ex}
						<div
							class="exercise-row"
							role="listitem"
							class:drop-slot-valid={
								activeDropExerciseTarget?.dayIndex === workout.sequenceIndex &&
								activeDropExerciseTarget.exerciseId === ex.id &&
								activeDropExerciseTarget.valid
							}
							class:drop-slot-invalid={
								activeDropExerciseTarget?.dayIndex === workout.sequenceIndex &&
								activeDropExerciseTarget.exerciseId === ex.id &&
								!activeDropExerciseTarget.valid
							}
							class:drop-before={
								activeDropExerciseTarget?.dayIndex === workout.sequenceIndex &&
								activeDropExerciseTarget.exerciseId === ex.id &&
								activeDropExerciseTarget.position === 'before'
							}
							class:drop-after={
								activeDropExerciseTarget?.dayIndex === workout.sequenceIndex &&
								activeDropExerciseTarget.exerciseId === ex.id &&
								activeDropExerciseTarget.position === 'after'
							}
							ondragover={(e) => onActiveRowDragOver(workout.sequenceIndex, ex.id, e)}
							ondrop={(e) => onActiveRowDrop(workout.sequenceIndex, ex.id, e)}
						>
							<div class="exercise-row-main">
								<button
									type="button"
									class="drag-handle"
									draggable="true"
									ondragstart={(e) => onActiveDragStart(workout.sequenceIndex, ex.id, e)}
									ondragend={onActiveDragEnd}
									disabled={loading}
									aria-label="Drag exercise"
									title="Drag to move exercise"
								>
									⋮⋮
								</button>
								<div class="row-grid">
									<label>
										Exercise
										<input value={ex.exerciseName} readonly />
									</label>
									<label>
										Tier / protocol
										<input value={activeTierProtocolLabel(ex.tier, ex.progressionProtocol)} readonly />
									</label>
									<label>
										Sets
										<input value={String(ex.sets)} readonly />
									</label>
									<label>
										Reps
										<input value={String(ex.reps)} readonly />
									</label>
									<label>
										Start weight ({weightUnitLabel(weightUnit)})
										<input value={displayFromKg(ex.targetWeightKg)} readonly />
									</label>
									<label>
										Progression
										<input
											value={
												ex.progressionType === 'PERCENT_1RM'
													? `${Number((ex.progressionValue * 100).toFixed(1))}%`
													: `${displayFromKg(ex.progressionValue)} ${weightUnitLabel(weightUnit)}`
											}
											readonly
										/>
									</label>
								</div>
								<button
									type="button"
									class="icon-danger"
									onclick={() => removeExerciseFromExistingDay(ex.id)}
									disabled={loading}
									aria-label="Remove exercise"
									title="Remove exercise"
								>
									🗑
								</button>
							</div>
						</div>
					{/each}
				</article>
			{/each}
		</div>
	</section>
{/if}

<style>
	.mode-toggle {
		display: inline-flex;
		gap: 0.5rem;
		margin-bottom: 0.8rem;
	}

	.stack {
		display: grid;
		gap: 0.8rem;
	}

	.inline-actions {
		display: flex;
		gap: 0.5rem;
		flex-wrap: wrap;
	}

	.form-grid {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
		gap: 0.7rem;
	}

	.day-grid {
		display: flex;
		flex-direction: column;
		gap: 0.8rem;
	}

	.day-card {
		border: 1px solid #1f2937;
		border-radius: 10px;
		padding: 0.8rem;
		display: grid;
		gap: 0.7rem;
	}

	.day-header {
		display: flex;
		justify-content: space-between;
		gap: 0.8rem;
		align-items: center;
	}

	.exercise-row {
		position: relative;
		border: 1px solid #1f2937;
		border-radius: 10px;
		padding: 0.7rem;
		display: grid;
		gap: 0.6rem;
	}

	.exercise-row::before,
	.exercise-row::after {
		content: '';
		position: absolute;
		left: 0.45rem;
		right: 0.45rem;
		height: 2px;
		border-radius: 999px;
		opacity: 0;
	}

	.exercise-row.drop-before::before,
	.exercise-row.drop-after::after {
		opacity: 1;
	}

	.exercise-row.drop-before::before {
		top: -2px;
	}

	.exercise-row.drop-after::after {
		bottom: -2px;
	}

	.exercise-row.drop-slot-valid.drop-before::before,
	.exercise-row.drop-slot-valid.drop-after::after {
		background: #3b82f6;
	}

	.exercise-row.drop-slot-invalid.drop-before::before,
	.exercise-row.drop-slot-invalid.drop-after::after {
		background: #9ca3af;
	}

	.exercise-row-main {
		display: grid;
		grid-template-columns: auto minmax(0, 1fr) auto;
		gap: 0.6rem;
		align-items: start;
	}

	.drag-handle {
		width: 2rem;
		height: 2rem;
		padding: 0;
		margin-top: 1.45rem;
		border-radius: 8px;
		background: #0b1220;
		border: 1px solid #334155;
		color: #94a3b8;
		cursor: grab;
		line-height: 1;
		font-size: 1.05rem;
	}

	.drag-handle:active {
		cursor: grabbing;
	}

	.icon-danger {
		width: 2rem;
		height: 2rem;
		padding: 0;
		margin-top: 1.45rem;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		font-size: 1rem;
		background: transparent;
		border: 1px solid #7f1d1d;
		color: #f87171;
	}

	.icon-danger:hover {
		background: rgba(127, 29, 29, 0.2);
	}

	.row-grid {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
		gap: 0.6rem;
	}

	.day-card.drop-target-valid {
		border-color: #2563eb;
		box-shadow: 0 0 0 2px rgba(37, 99, 235, 0.35);
	}

	.day-card.drop-target-invalid {
		border-color: #6b7280;
		box-shadow: 0 0 0 2px rgba(107, 114, 128, 0.35);
	}

</style>
