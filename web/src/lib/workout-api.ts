import { gql } from '$lib/graphql';
import type {
	ActivePlan,
	AddExerciseToPlanInput,
	BaselineOverrideInput,
	Dashboard,
	ExerciseCatalogMatch,
	PlanSummary,
	ExerciseProgressPoint,
	HeartRateSample,
	SeedExerciseInput,
	SeedWorkoutInput,
	StravaAuthStart,
	StravaConnection,
	StravaSendResult,
	WorkoutHistoryItem,
	WorkoutSession
} from '$lib/types';

type MutationResult = {
	ok: boolean;
	message: string;
};

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

const stravaConnectionQuery = `
	query StravaConnection {
		stravaConnection {
			configured
			connected
			athleteId
			athleteUsername
			scope
			expiresAt
			autoSendOnFinish
		}
	}
`;

const SESSION_FIELDS = `
			id
			planWorkoutId
			planWorkoutName
			status
			startedAt
			finishedAt
			heartRateSampleCount
			avgHeartRateBpm
			maxHeartRateBpm
			stravaExportStatus
			stravaActivityId
			stravaActivityUrl
			stravaLastError
			entries {
				id
				planWorkoutExerciseId
				exerciseId
				planWorkoutExerciseId
				exerciseName
				equipmentType
				plannedSets
				plannedReps
				plannedWeightKg
				progressionProtocol
				tier
				expectedRestSeconds
				sets {
					id
					setIndex
					targetReps
					isAmrap
					repsCompleted
					weightKg
					durationSeconds
					completed
					completedAt
					skipped
				}
			}
			personalRecords {
				exerciseName
				kind
				valueKg
				reps
				previousKg
			}
`;

const activeSessionQuery = `
	query ActiveSession {
		activeWorkoutSession { ${SESSION_FIELDS} }
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
			totalDurationSeconds
			totalSetDurationSeconds
			heartRateSampleCount
			avgHeartRateBpm
			maxHeartRateBpm
			stravaExportStatus
			stravaActivityId
			stravaActivityUrl
			exercises {
				exerciseId
				exerciseName
				completedSets
				totalReps
				topWeightKg
			}
			personalRecords {
				exerciseName
				kind
				valueKg
				reps
				previousKg
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

const sessionHeartRateSamplesQuery = `
	query SessionHeartRateSamples($sessionId: Int!, $limit: Int!) {
		sessionHeartRateSamples(sessionId: $sessionId, limit: $limit) {
			id
			sessionId
			recordedAt
			bpm
			source
		}
	}
`;

const exerciseCatalogSearchQuery = `
	query ExerciseCatalogSearch($query: String!, $limit: Int!) {
		exerciseCatalogSearch(query: $query, limit: $limit) {
			catalogItemId
			canonicalName
			equipmentType
			matchedAlias
			source
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
		$activate: Boolean! = true
	) {
		seedPlan(
			planName: $planName
			totalWeeks: $totalWeeks
			workouts: $workouts
			exercises: $exercises
			daysPerWeek: $daysPerWeek
			activate: $activate
		) {
			ok
			planId
			planRunId
		}
	}
`;

const plansQuery = `
	query Plans {
		plans {
			id
			name
			isActive
			isCompleted
			totalWeeks
			daysPerWeek
			exerciseCount
			currentWeek
			currentWorkoutIndex
			completedWorkoutCount
			lastWorkoutAt
			createdAt
		}
	}
`;

const setActivePlanMutation = `
	mutation SetActivePlan($planId: Int!) {
		setActivePlan(planId: $planId) {
			ok
			message
		}
	}
`;

const deactivatePlanMutation = `
	mutation DeactivatePlan($planId: Int!) {
		deactivatePlan(planId: $planId) {
			ok
			message
		}
	}
`;

const deletePlanByIdMutation = `
	mutation DeletePlanById($planId: Int!) {
		deletePlan(planId: $planId) {
			ok
			message
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
	mutation CompleteSet($sessionSetId: Int!, $repsCompleted: Int!, $weightKg: Float, $durationSeconds: Int) {
		completeSet(
			sessionSetId: $sessionSetId
			repsCompleted: $repsCompleted
			weightKg: $weightKg
			durationSeconds: $durationSeconds
		) {
			id
			completed
			durationSeconds
		}
	}
`;

const finishWorkoutMutation = `
	mutation FinishWorkout($sessionId: Int!) {
		finishWorkout(sessionId: $sessionId) {
			id
			status
			finishedAt
			stravaExportStatus
			stravaActivityId
			stravaActivityUrl
			stravaLastError
			personalRecords {
				exerciseName
				kind
				valueKg
				reps
				previousKg
			}
		}
	}
`;

const cancelWorkoutMutation = `
	mutation CancelWorkout($sessionId: Int!) {
		cancelWorkout(sessionId: $sessionId) {
			ok
			message
		}
	}
`;

const uncompleteSetMutation = `
	mutation UncompleteSet($sessionSetId: Int!) {
		uncompleteSet(sessionSetId: $sessionSetId) {
			id
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

const linkExerciseToCatalogMutation = `
	mutation LinkExerciseToCatalog($exerciseId: Int!, $catalogItemId: Int) {
		linkExerciseToCatalog(exerciseId: $exerciseId, catalogItemId: $catalogItemId) {
			ok
			message
		}
	}
`;

const startStravaAuthMutation = `
	mutation StartStravaAuth {
		startStravaAuth {
			ok
			authUrl
			message
		}
	}
`;

const connectStravaMutation = `
	mutation ConnectStrava($code: String!, $state: String!) {
		connectStrava(code: $code, state: $state) {
			ok
			message
		}
	}
`;

const disconnectStravaMutation = `
	mutation DisconnectStrava {
		disconnectStrava {
			ok
			message
		}
	}
`;

const sendWorkoutToStravaMutation = `
	mutation SendWorkoutToStrava($sessionId: Int!) {
		sendWorkoutToStrava(sessionId: $sessionId) {
			ok
			message
			activityId
			activityUrl
		}
	}
`;

const setStravaAutoSendOnFinishMutation = `
	mutation SetStravaAutoSendOnFinish($enabled: Boolean!) {
		setStravaAutoSendOnFinish(enabled: $enabled) {
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

export async function fetchStravaConnection(): Promise<StravaConnection> {
	const data = await gql<{ stravaConnection: StravaConnection }>(stravaConnectionQuery);
	return data.stravaConnection;
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

export async function fetchSessionHeartRateSamples(
	sessionId: number,
	limit = 360
): Promise<HeartRateSample[]> {
	const data = await gql<{ sessionHeartRateSamples: HeartRateSample[] }>(
		sessionHeartRateSamplesQuery,
		{ sessionId, limit }
	);
	return data.sessionHeartRateSamples;
}

export async function searchExerciseCatalog(
	query: string,
	limit = 12
): Promise<ExerciseCatalogMatch[]> {
	if (!query.trim()) return [];
	const data = await gql<{ exerciseCatalogSearch: ExerciseCatalogMatch[] }>(
		exerciseCatalogSearchQuery,
		{ query, limit }
	);
	return data.exerciseCatalogSearch;
}

export async function seedPlan(input: {
	planName: string;
	totalWeeks: number | null;
	exercises: SeedExerciseInput[];
	workouts: SeedWorkoutInput[];
	daysPerWeek?: number;
	activate?: boolean;
}): Promise<void> {
	await gql(seedPlanMutation, { ...input, activate: input.activate ?? true });
}

export type AuthStatus = { authRequired: boolean; signedIn: boolean; username: string | null };

export async function fetchAuthStatus(): Promise<AuthStatus> {
	const data = await gql<{ authStatus: AuthStatus }>(
		`query AuthStatus { authStatus { authRequired signedIn username } }`
	);
	return data.authStatus;
}

export async function login(username: string, password: string): Promise<void> {
	const data = await gql<{ login: MutationResult }>(
		`mutation Login($username: String!, $password: String!) {
			login(username: $username, password: $password) { ok message }
		}`,
		{ username, password }
	);
	ensureOk(data.login);
}

export async function logout(): Promise<void> {
	await gql(`mutation Logout { logout { ok message } }`);
}

export async function fetchPlans(): Promise<PlanSummary[]> {
	const data = await gql<{ plans: PlanSummary[] }>(plansQuery);
	return data.plans;
}

function ensureOk(result: MutationResult): string {
	if (!result.ok) throw new Error(result.message);
	return result.message;
}

export async function setActivePlan(planId: number): Promise<string> {
	const data = await gql<{ setActivePlan: MutationResult }>(setActivePlanMutation, { planId });
	return ensureOk(data.setActivePlan);
}

export async function deactivatePlan(planId: number): Promise<string> {
	const data = await gql<{ deactivatePlan: MutationResult }>(deactivatePlanMutation, { planId });
	return ensureOk(data.deactivatePlan);
}

export async function deletePlan(planId: number): Promise<string> {
	const data = await gql<{ deletePlan: MutationResult }>(deletePlanByIdMutation, { planId });
	return ensureOk(data.deletePlan);
}

export async function startWorkout(): Promise<void> {
	await gql(startWorkoutMutation);
}

export async function startStravaAuth(): Promise<StravaAuthStart> {
	const data = await gql<{ startStravaAuth: StravaAuthStart }>(startStravaAuthMutation);
	return data.startStravaAuth;
}

export async function connectStrava(code: string, state: string): Promise<void> {
	const data = await gql<{ connectStrava: MutationResult }>(connectStravaMutation, { code, state });
	if (!data.connectStrava.ok) throw new Error(data.connectStrava.message);
}

export async function disconnectStrava(): Promise<void> {
	const data = await gql<{ disconnectStrava: MutationResult }>(disconnectStravaMutation);
	if (!data.disconnectStrava.ok) throw new Error(data.disconnectStrava.message);
}

export async function sendWorkoutToStrava(sessionId: number): Promise<StravaSendResult> {
	const data = await gql<{ sendWorkoutToStrava: StravaSendResult }>(sendWorkoutToStravaMutation, {
		sessionId
	});
	return data.sendWorkoutToStrava;
}

export async function setStravaAutoSendOnFinish(enabled: boolean): Promise<void> {
	const data = await gql<{ setStravaAutoSendOnFinish: MutationResult }>(
		setStravaAutoSendOnFinishMutation,
		{ enabled }
	);
	if (!data.setStravaAutoSendOnFinish.ok) throw new Error(data.setStravaAutoSendOnFinish.message);
}

export async function completeSet(input: {
	sessionSetId: number;
	repsCompleted: number;
	weightKg?: number;
	durationSeconds?: number;
}): Promise<void> {
	await gql(completeSetMutation, input);
}

export async function finishWorkout(sessionId: number): Promise<WorkoutSession> {
	const data = await gql<{ finishWorkout: WorkoutSession }>(finishWorkoutMutation, { sessionId });
	return data.finishWorkout;
}

// ---------------------------------------------------------------- mid-workout changes

async function sessionMutation(name: string, signature: string, args: string, variables: Record<string, unknown>) {
	const data = await gql<Record<string, WorkoutSession>>(
		`mutation ${name[0].toUpperCase()}${name.slice(1)}${signature} { ${name}${args} { ${SESSION_FIELDS} } }`,
		variables
	);
	return data[name];
}

export function startEmptyWorkout(name?: string): Promise<WorkoutSession> {
	return sessionMutation('startEmptyWorkout', '($name: String)', '(name: $name)', { name: name ?? null });
}

export function addExerciseToWorkout(input: {
	sessionId: number;
	exerciseName: string;
	sets: number;
	reps: number;
	weightKg: number;
}): Promise<WorkoutSession> {
	return sessionMutation(
		'addExerciseToWorkout',
		'($sessionId: Int!, $exerciseName: String!, $sets: Int!, $reps: Int!, $weightKg: Float!)',
		'(sessionId: $sessionId, exerciseName: $exerciseName, sets: $sets, reps: $reps, weightKg: $weightKg)',
		input
	);
}

export function swapExercise(entryId: number, exerciseName: string): Promise<WorkoutSession> {
	return sessionMutation(
		'swapExercise',
		'($entryId: Int!, $exerciseName: String!)',
		'(entryId: $entryId, exerciseName: $exerciseName)',
		{ entryId, exerciseName }
	);
}

export function skipExercise(entryId: number): Promise<WorkoutSession> {
	return sessionMutation('skipExercise', '($entryId: Int!)', '(entryId: $entryId)', { entryId });
}

export function unskipExercise(entryId: number): Promise<WorkoutSession> {
	return sessionMutation('unskipExercise', '($entryId: Int!)', '(entryId: $entryId)', { entryId });
}

export function addSet(entryId: number): Promise<WorkoutSession> {
	return sessionMutation('addSet', '($entryId: Int!)', '(entryId: $entryId)', { entryId });
}

export async function fetchExerciseNames(): Promise<string[]> {
	const data = await gql<{ exercises: { name: string }[] }>(`query Exercises { exercises { name } }`);
	return data.exercises.map((e) => e.name);
}

// ---------------------------------------------------------------- editing history

export type WorkoutEditResult = { ok: boolean; message: string; progressionRecalculated: boolean };

export async function fetchWorkoutSession(sessionId: number): Promise<WorkoutSession | null> {
	const data = await gql<{ workoutSession: WorkoutSession | null }>(
		`query WorkoutSession($sessionId: Int!) { workoutSession(sessionId: $sessionId) { ${SESSION_FIELDS} } }`,
		{ sessionId }
	);
	return data.workoutSession;
}

export async function updateWorkout(
	sessionId: number,
	sets: { sessionSetId: number; repsCompleted: number | null; weightKg: number | null; completed: boolean }[]
): Promise<WorkoutEditResult> {
	const data = await gql<{ updateWorkout: WorkoutEditResult }>(
		`mutation UpdateWorkout($sessionId: Int!, $sets: [SetEditInput!]!) {
			updateWorkout(sessionId: $sessionId, sets: $sets) { ok message progressionRecalculated }
		}`,
		{ sessionId, sets }
	);
	if (!data.updateWorkout.ok) throw new Error(data.updateWorkout.message);
	return data.updateWorkout;
}

export async function deleteWorkout(sessionId: number): Promise<WorkoutEditResult> {
	const data = await gql<{ deleteWorkout: WorkoutEditResult }>(
		`mutation DeleteWorkout($sessionId: Int!) { deleteWorkout(sessionId: $sessionId) { ok message progressionRecalculated } }`,
		{ sessionId }
	);
	if (!data.deleteWorkout.ok) throw new Error(data.deleteWorkout.message);
	return data.deleteWorkout;
}

export async function cancelWorkout(sessionId: number): Promise<string> {
	const data = await gql<{ cancelWorkout: MutationResult }>(cancelWorkoutMutation, { sessionId });
	return ensureOk(data.cancelWorkout);
}

export async function uncompleteSet(sessionSetId: number): Promise<void> {
	await gql(uncompleteSetMutation, { sessionSetId });
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

export async function linkExerciseToCatalog(
	exerciseId: number,
	catalogItemId: number | null
): Promise<void> {
	await gql(linkExerciseToCatalogMutation, { exerciseId, catalogItemId });
}

export async function deleteActivePlan(): Promise<void> {
	await gql(deletePlanMutation);
}

export async function resetToBaseline(baselineOverrides: BaselineOverrideInput[] = []): Promise<void> {
	await gql(resetMutation, { baselineOverrides });
}
