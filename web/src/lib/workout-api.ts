import { gql } from '$lib/graphql';
import type {
	ActivePlan,
	AddExerciseToPlanInput,
	BaselineOverrideInput,
	Dashboard,
	ExerciseProgressPoint,
	SeedExerciseInput,
	SeedWorkoutInput,
	WorkoutHistoryItem,
	WorkoutSession
} from '$lib/types';

const dashboardQuery = `
	query Dashboard {
		dashboard {
			status {
				planRunId
				planName
				week
				workoutIndex
				lastWorkoutAt
				daysSinceLastWorkout
				needsNew1rmExercises
			}
			baselines {
				exerciseId
				exerciseName
				baseline1rmKg
			}
			resetBaselines {
				exerciseId
				exerciseName
				baseline1rmKg
			}
		}
	}
`;

const activePlanQuery = `
	query ActivePlan {
		activePlan {
			id
			name
			totalWeeks
			daysPerWeek
			currentWeek
			currentWorkoutIndex
			workouts {
				id
				name
				sequenceIndex
				exercises {
					id
					exerciseId
					exerciseName
					sets
					reps
					targetWeightKg
					progressionType
					progressionProtocol
					tier
					progressionValue
					trainingMaxRatio
					amrapLastSet
				}
			}
		}
	}
`;

const activeSessionQuery = `
	query ActiveSession {
		activeWorkoutSession {
			id
			status
			startedAt
			finishedAt
			entries {
				id
				exerciseId
				exerciseName
				plannedSets
				plannedReps
				plannedWeightKg
				sets {
					id
					setIndex
					targetReps
					isAmrap
					repsCompleted
					weightKg
					completed
					completedAt
				}
			}
		}
	}
`;

const historyQuery = `
	query History($limit: Int!) {
		workoutHistory(limit: $limit) {
			sessionId
			planRunId
			finishedAt
			planWorkoutName
			workoutSequenceIndex
			totalSets
			completedSets
			totalVolumeKg
			exercises {
				exerciseId
				exerciseName
				completedSets
				totalReps
				topWeightKg
			}
		}
	}
`;

const progressQuery = `
	query ExerciseProgress($exerciseId: Int!, $limit: Int!) {
		exerciseProgress(exerciseId: $exerciseId, limit: $limit) {
			date
			topWeightKg
			estimated1rmKg
		}
	}
`;

const seedPlanMutation = `
	mutation SeedPlan(
		$planName: String!
		$totalWeeks: Int
		$workouts: [SeedPlanWorkoutInput!]!
		$exercises: [SeedExerciseInput!]!
		$daysPerWeek: Int
	) {
		seedPlan(
			planName: $planName
			totalWeeks: $totalWeeks
			workouts: $workouts
			exercises: $exercises
			daysPerWeek: $daysPerWeek
		) {
			ok
			planId
			planRunId
		}
	}
`;

const startWorkoutMutation = `
	mutation StartWorkout {
		startWorkout {
			id
		}
	}
`;

const completeSetMutation = `
	mutation CompleteSet($sessionSetId: Int!, $repsCompleted: Int!, $weightKg: Float) {
		completeSet(sessionSetId: $sessionSetId, repsCompleted: $repsCompleted, weightKg: $weightKg) {
			id
			completed
		}
	}
`;

const finishWorkoutMutation = `
	mutation FinishWorkout($sessionId: Int!) {
		finishWorkout(sessionId: $sessionId) {
			id
			status
		}
	}
`;

const setOneRepMaxMutation = `
	mutation SetOneRepMax($exerciseId: Int!, $oneRepMaxKg: Float!) {
		setExerciseOneRepMax(exerciseId: $exerciseId, oneRepMaxKg: $oneRepMaxKg) {
			ok
			message
		}
	}
`;

const addExerciseMutation = `
	mutation AddExercise($input: AddExerciseToActivePlanInput!) {
		addExerciseToActivePlan(input: $input) {
			ok
			message
		}
	}
`;

const addDayMutation = `
	mutation AddDay($dayName: String) {
		addDayToActivePlan(dayName: $dayName) {
			ok
			message
		}
	}
`;

const removeDayMutation = `
	mutation RemoveDay($sequenceIndex: Int!) {
		removeDayFromActivePlan(sequenceIndex: $sequenceIndex) {
			ok
			message
		}
	}
`;

const moveExerciseMutation = `
	mutation MoveExercise($planExerciseId: Int!, $targetWorkoutSequenceIndex: Int!) {
		moveExerciseToDay(
			planExerciseId: $planExerciseId
			targetWorkoutSequenceIndex: $targetWorkoutSequenceIndex
		) {
			ok
			message
		}
	}
`;

const removeExerciseMutation = `
	mutation RemoveExercise($planExerciseId: Int!) {
		removeExerciseFromActivePlan(planExerciseId: $planExerciseId) {
			ok
			message
		}
	}
`;

const deletePlanMutation = `
	mutation DeletePlan {
		deleteActivePlan {
			ok
			message
		}
	}
`;

const resetMutation = `
	mutation Reset($baselineOverrides: [BaselineInput!]) {
		resetToBaseline(baselineOverrides: $baselineOverrides) {
			ok
			message
			updatedExerciseCount
		}
	}
`;

export async function fetchDashboard(): Promise<Dashboard> {
	const data = await gql<{ dashboard: Dashboard }>(dashboardQuery);
	return data.dashboard;
}

export async function fetchActivePlan(): Promise<ActivePlan | null> {
	const data = await gql<{ activePlan: ActivePlan | null }>(activePlanQuery);
	return data.activePlan;
}

export async function fetchActiveSession(): Promise<WorkoutSession | null> {
	const data = await gql<{ activeWorkoutSession: WorkoutSession | null }>(activeSessionQuery);
	return data.activeWorkoutSession;
}

export async function fetchWorkoutHistory(limit = 20): Promise<WorkoutHistoryItem[]> {
	const data = await gql<{ workoutHistory: WorkoutHistoryItem[] }>(historyQuery, { limit });
	return data.workoutHistory;
}

export async function fetchExerciseProgress(
	exerciseId: number,
	limit = 60
): Promise<ExerciseProgressPoint[]> {
	const data = await gql<{ exerciseProgress: ExerciseProgressPoint[] }>(progressQuery, {
		exerciseId,
		limit
	});
	return data.exerciseProgress;
}

export async function seedPlan(input: {
	planName: string;
	totalWeeks: number | null;
	exercises: SeedExerciseInput[];
	workouts: SeedWorkoutInput[];
	daysPerWeek?: number;
}): Promise<void> {
	await gql(seedPlanMutation, input);
}

export async function startWorkout(): Promise<void> {
	await gql(startWorkoutMutation);
}

export async function completeSet(input: {
	sessionSetId: number;
	repsCompleted: number;
	weightKg?: number;
}): Promise<void> {
	await gql(completeSetMutation, input);
}

export async function finishWorkout(sessionId: number): Promise<void> {
	await gql(finishWorkoutMutation, { sessionId });
}

export async function setExerciseOneRepMax(exerciseId: number, oneRepMaxKg: number): Promise<void> {
	await gql(setOneRepMaxMutation, { exerciseId, oneRepMaxKg });
}

export async function addExerciseToActivePlan(input: AddExerciseToPlanInput): Promise<void> {
	await gql(addExerciseMutation, { input });
}

export async function addDayToActivePlan(dayName?: string): Promise<void> {
	await gql(addDayMutation, { dayName });
}

export async function removeDayFromActivePlan(sequenceIndex: number): Promise<void> {
	await gql(removeDayMutation, { sequenceIndex });
}

export async function moveExerciseToDay(
	planExerciseId: number,
	targetWorkoutSequenceIndex: number
): Promise<void> {
	await gql(moveExerciseMutation, { planExerciseId, targetWorkoutSequenceIndex });
}

export async function removeExerciseFromActivePlan(planExerciseId: number): Promise<void> {
	await gql(removeExerciseMutation, { planExerciseId });
}

export async function deleteActivePlan(): Promise<void> {
	await gql(deletePlanMutation);
}

export async function resetToBaseline(baselineOverrides: BaselineOverrideInput[] = []): Promise<void> {
	await gql(resetMutation, { baselineOverrides });
}
