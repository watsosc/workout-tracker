export type Protocol = 'BASIC' | 'GZCLP_T1' | 'GZCLP_T2' | 'GZCLP_T3';

export type Baseline = {
	exerciseId: number;
	exerciseName: string;
	baseline1rmKg: number;
};

export type DashboardStatus = {
	planRunId: number;
	planName: string;
	week: number;
	workoutIndex: number;
	lastWorkoutAt: string | null;
	daysSinceLastWorkout: number | null;
	needsNew1rmExercises: string[];
};

export type Dashboard = {
	status: DashboardStatus | null;
	baselines: Baseline[];
	resetBaselines: Baseline[];
};

export type ActivePlanExercise = {
	id: number;
	exerciseId: number;
	exerciseName: string;
	sets: number;
	reps: number;
	targetWeightKg: number;
	progressionType: 'NONE' | 'LINEAR_KG' | 'PERCENT_1RM';
	progressionProtocol: Protocol;
	tier: 'T1' | 'T2' | 'T3' | null;
	progressionValue: number;
	trainingMaxRatio: number;
	amrapLastSet: boolean;
};

export type ActivePlanWorkout = {
	id: number;
	name: string;
	sequenceIndex: number;
	exercises: ActivePlanExercise[];
};

export type ActivePlan = {
	id: number;
	name: string;
	totalWeeks: number | null;
	daysPerWeek: number;
	currentWeek: number;
	currentWorkoutIndex: number;
	workouts: ActivePlanWorkout[];
};

export type SessionSet = {
	id: number;
	setIndex: number;
	targetReps: number | null;
	isAmrap: boolean;
	repsCompleted: number | null;
	weightKg: number | null;
	durationSeconds: number | null;
	completed: boolean;
	completedAt: string | null;
};

export type SessionEntry = {
	id: number;
	exerciseId: number;
	exerciseName: string;
	plannedSets: number;
	plannedReps: number;
	plannedWeightKg: number;
	progressionProtocol: Protocol;
	tier: 'T1' | 'T2' | 'T3' | null;
	expectedRestSeconds: number;
	sets: SessionSet[];
};

export type WorkoutSession = {
	id: number;
	status: 'IN_PROGRESS' | 'COMPLETED' | 'CANCELLED';
	startedAt: string;
	finishedAt: string | null;
	entries: SessionEntry[];
};

export type WorkoutHistoryExercise = {
	exerciseId: number;
	exerciseName: string;
	completedSets: number;
	totalReps: number;
	topWeightKg: number;
};

export type WorkoutExportStatus = 'PENDING' | 'SENT' | 'FAILED';

export type WorkoutHistoryItem = {
	sessionId: number;
	planRunId: number;
	finishedAt: string | null;
	planWorkoutName: string;
	workoutSequenceIndex: number | null;
	totalSets: number;
	completedSets: number;
	totalVolumeKg: number;
	totalDurationSeconds: number | null;
	totalSetDurationSeconds: number;
	stravaExportStatus: WorkoutExportStatus | null;
	stravaActivityId: string | null;
	stravaActivityUrl: string | null;
	exercises: WorkoutHistoryExercise[];
};

export type ExerciseProgressPoint = {
	date: string;
	topWeightKg: number;
	estimated1rmKg: number;
};

export type SeedExerciseInput = {
	name: string;
	baseline1rmKg: number;
};

export type SeedWorkoutExerciseInput = {
	exerciseName: string;
	sets: number;
	reps: number;
	targetWeightKg: number;
	progressionType: 'NONE' | 'LINEAR_KG' | 'PERCENT_1RM';
	progressionProtocol: Protocol;
	tier?: 'T1' | 'T2' | 'T3' | null;
	progressionValue: number;
	weightIncrementKg?: number;
};

export type SeedWorkoutInput = {
	name: string;
	sequenceIndex: number;
	exercises: SeedWorkoutExerciseInput[];
};

export type AddExerciseToPlanInput = {
	workoutSequenceIndex: number;
	exerciseName: string;
	baseline1rmKg: number | null;
	sets: number;
	reps: number;
	targetWeightKg: number;
	progressionType: 'NONE' | 'LINEAR_KG' | 'PERCENT_1RM';
	progressionProtocol: Protocol;
	progressionValue: number;
	weightIncrementKg?: number;
};

export type BaselineOverrideInput = {
	exerciseId: number;
	baseline1rmKg: number;
};

export type ExerciseEquipmentType =
	| 'BARBELL'
	| 'DUMBBELL'
	| 'MACHINE'
	| 'CABLE'
	| 'BODYWEIGHT'
	| 'KETTLEBELL'
	| 'BAND'
	| 'OTHER';

export type ExerciseCatalogSource = 'WGER' | 'MANUAL';

export type ExerciseCatalogMatch = {
	catalogItemId: number;
	canonicalName: string;
	equipmentType: ExerciseEquipmentType;
	matchedAlias: string;
	source: ExerciseCatalogSource;
};

export type StravaConnection = {
	configured: boolean;
	connected: boolean;
	athleteId: string | null;
	athleteUsername: string | null;
	scope: string | null;
	expiresAt: string | null;
	autoSendOnFinish: boolean;
};

export type StravaAuthStart = {
	ok: boolean;
	authUrl: string;
	message: string;
};

export type StravaSendResult = {
	ok: boolean;
	message: string;
	activityId: string | null;
	activityUrl: string | null;
};
