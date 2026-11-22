import Foundation

enum ProtocolType: String, Codable {
    case basic = "BASIC"
    case gzclpT1 = "GZCLP_T1"
    case gzclpT2 = "GZCLP_T2"
    case gzclpT3 = "GZCLP_T3"
}

struct Baseline: Codable, Identifiable {
    let exerciseId: Int
    let exerciseName: String
    let baseline1rmKg: Double

    var id: Int { exerciseId }
}

struct DashboardStatus: Codable {
    let planRunId: Int
    let planName: String
    let week: Int
    let workoutIndex: Int
    let lastWorkoutAt: String?
    let daysSinceLastWorkout: Int?
    let needsNew1rmExercises: [String]
}

struct Dashboard: Codable {
    let status: DashboardStatus?
    let baselines: [Baseline]
    let resetBaselines: [Baseline]
}

struct ActivePlanExercise: Codable, Identifiable {
    let id: Int
    let exerciseId: Int
    let exerciseName: String
    let sets: Int
    let reps: Int
    let targetWeightKg: Double
    let progressionProtocol: ProtocolType
    let tier: String?
    let progressionValue: Double
    let trainingMaxRatio: Double
    let amrapLastSet: Bool
}

struct ActivePlanWorkout: Codable, Identifiable {
    let id: Int
    let name: String
    let sequenceIndex: Int
    let exercises: [ActivePlanExercise]
}

struct ActivePlan: Codable, Identifiable {
    let id: Int
    let name: String
    let totalWeeks: Int?
    let daysPerWeek: Int
    let currentWeek: Int
    let currentWorkoutIndex: Int
    let workouts: [ActivePlanWorkout]
}

struct PlanSummary: Codable, Identifiable {
    let id: Int
    let name: String
    let isActive: Bool
    let isCompleted: Bool
    let totalWeeks: Int?
    let daysPerWeek: Int
    let exerciseCount: Int
    let currentWeek: Int?
    let currentWorkoutIndex: Int?
    let completedWorkoutCount: Int
    let lastWorkoutAt: String?
    let createdAt: String

    /// Active and still running (a completed plan can remain flagged active until restarted).
    var isRunning: Bool { isActive && !isCompleted }
}

struct SessionSet: Codable, Identifiable {
    let id: Int
    let setIndex: Int
    let targetReps: Int?
    let isAmrap: Bool
    let repsCompleted: Int?
    let weightKg: Double?
    let durationSeconds: Int?
    let completed: Bool
    let completedAt: String?
}

struct SessionEntry: Codable, Identifiable {
    let id: Int
    let exerciseId: Int
    let exerciseName: String
    let plannedSets: Int
    let plannedReps: Int
    let plannedWeightKg: Double
    let progressionProtocol: ProtocolType
    let tier: String?
    let expectedRestSeconds: Int
    let sets: [SessionSet]
}

enum WorkoutExportStatus: String, Codable {
    case pending = "PENDING"
    case sent = "SENT"
    case failed = "FAILED"
}

struct WorkoutSession: Codable, Identifiable {
    let id: Int
    let status: String
    let startedAt: String
    let finishedAt: String?
    let heartRateSampleCount: Int
    let avgHeartRateBpm: Double?
    let maxHeartRateBpm: Double?
    let stravaExportStatus: WorkoutExportStatus?
    let stravaActivityId: String?
    let stravaActivityUrl: String?
    let stravaLastError: String?
    let entries: [SessionEntry]
}

struct WorkoutHistoryExercise: Codable, Identifiable {
    let exerciseId: Int
    let exerciseName: String
    let completedSets: Int
    let totalReps: Int
    let topWeightKg: Double

    var id: Int { exerciseId }
}

struct WorkoutHistoryItem: Codable, Identifiable {
    let sessionId: Int
    let planRunId: Int
    let finishedAt: String?
    let planWorkoutName: String
    let workoutSequenceIndex: Int?
    let totalSets: Int
    let completedSets: Int
    let totalVolumeKg: Double
    let totalDurationSeconds: Int?
    let totalSetDurationSeconds: Int
    let heartRateSampleCount: Int
    let avgHeartRateBpm: Double?
    let maxHeartRateBpm: Double?
    let stravaExportStatus: WorkoutExportStatus?
    let stravaActivityId: String?
    let stravaActivityUrl: String?
    let exercises: [WorkoutHistoryExercise]

    var id: Int { sessionId }
}

struct ExerciseProgressPoint: Codable, Identifiable {
    let date: String
    let topWeightKg: Double
    let estimated1rmKg: Double

    var id: String { date + "-\(topWeightKg)-\(estimated1rmKg)" }
}

struct HeartRateSample: Codable, Identifiable {
    let id: Int
    let sessionId: Int
    let recordedAt: String
    let bpm: Int
    let source: String?
}

struct StravaConnection: Codable {
    let configured: Bool
    let connected: Bool
    let athleteId: String?
    let athleteUsername: String?
    let scope: String?
    let expiresAt: String?
    let autoSendOnFinish: Bool
}

struct StravaAuthStart: Codable {
    let ok: Bool
    let authUrl: String
    let message: String
}

struct StravaSendResult: Codable {
    let ok: Bool
    let message: String
    let activityId: String?
    let activityUrl: String?
}
