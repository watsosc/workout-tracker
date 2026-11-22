import Foundation

struct WorkoutAPI {
    private let client: GraphQLClient

    init(endpoint: String) {
        self.client = GraphQLClient(endpoint: endpoint)
    }

    func fetchDashboard() async throws -> Dashboard {
        struct Data: Decodable { let dashboard: Dashboard }
        return try await client.execute(Self.dashboardQuery, dataType: Data.self).dashboard
    }

    func fetchActivePlan() async throws -> ActivePlan? {
        struct Data: Decodable { let activePlan: ActivePlan? }
        return try await client.execute(Self.activePlanQuery, dataType: Data.self).activePlan
    }

    func fetchPlans() async throws -> [PlanSummary] {
        struct Data: Decodable { let plans: [PlanSummary] }
        return try await client.execute(Self.plansQuery, dataType: Data.self).plans
    }

    @discardableResult
    func setActivePlan(planId: Int) async throws -> String {
        struct Data: Decodable { let setActivePlan: MutationResult }
        let result = try await client.execute(Self.setActivePlanMutation, variables: ["planId": planId], dataType: Data.self).setActivePlan
        guard result.ok else { throw NSError(domain: "WorkoutAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: result.message]) }
        return result.message
    }

    @discardableResult
    func deactivatePlan(planId: Int) async throws -> String {
        struct Data: Decodable { let deactivatePlan: MutationResult }
        let result = try await client.execute(Self.deactivatePlanMutation, variables: ["planId": planId], dataType: Data.self).deactivatePlan
        guard result.ok else { throw NSError(domain: "WorkoutAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: result.message]) }
        return result.message
    }

    func fetchActiveSession() async throws -> WorkoutSession? {
        struct Data: Decodable { let activeWorkoutSession: WorkoutSession? }
        return try await client.execute(Self.activeSessionQuery, dataType: Data.self).activeWorkoutSession
    }

    func fetchWorkoutHistory(limit: Int = 120) async throws -> [WorkoutHistoryItem] {
        struct Data: Decodable { let workoutHistory: [WorkoutHistoryItem] }
        return try await client.execute(Self.historyQuery, variables: ["limit": limit], dataType: Data.self).workoutHistory
    }

    func fetchExerciseProgress(exerciseId: Int, limit: Int = 120) async throws -> [ExerciseProgressPoint] {
        struct Data: Decodable { let exerciseProgress: [ExerciseProgressPoint] }
        return try await client.execute(Self.progressQuery, variables: ["exerciseId": exerciseId, "limit": limit], dataType: Data.self).exerciseProgress
    }

    func fetchSessionHeartRateSamples(sessionId: Int, limit: Int = 360) async throws -> [HeartRateSample] {
        struct Data: Decodable { let sessionHeartRateSamples: [HeartRateSample] }
        return try await client.execute(Self.heartRateSamplesQuery, variables: ["sessionId": sessionId, "limit": limit], dataType: Data.self).sessionHeartRateSamples
    }

    func fetchStravaConnection() async throws -> StravaConnection {
        struct Data: Decodable { let stravaConnection: StravaConnection }
        return try await client.execute(Self.stravaConnectionQuery, dataType: Data.self).stravaConnection
    }

    func appendHeartRateSamples(sessionId: Int, samples: [[String: Any]]) async throws -> Int {
        struct Data: Decodable { let appendHeartRateSamples: HeartRateIngestResult }
        let result = try await client.execute(
            Self.appendHeartRateSamplesMutation,
            variables: ["sessionId": sessionId, "samples": samples],
            dataType: Data.self
        ).appendHeartRateSamples
        guard result.ok else {
            throw NSError(domain: "WorkoutAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: result.message])
        }
        return result.insertedCount
    }

    func startWorkout() async throws {
        struct Data: Decodable { let startWorkout: IdOnly }
        _ = try await client.execute(Self.startWorkoutMutation, dataType: Data.self)
    }

    func completeSet(sessionSetId: Int, repsCompleted: Int, weightKg: Double?, durationSeconds: Int?) async throws {
        struct Data: Decodable { let completeSet: CompleteSetResult }
        var vars: [String: Any] = [
            "sessionSetId": sessionSetId,
            "repsCompleted": repsCompleted
        ]
        if let weightKg { vars["weightKg"] = weightKg }
        if let durationSeconds { vars["durationSeconds"] = durationSeconds }

        _ = try await client.execute(Self.completeSetMutation, variables: vars, dataType: Data.self)
    }

    func finishWorkout(sessionId: Int) async throws -> WorkoutSession {
        struct Data: Decodable { let finishWorkout: WorkoutSession }
        return try await client.execute(Self.finishWorkoutMutation, variables: ["sessionId": sessionId], dataType: Data.self).finishWorkout
    }

    func setExerciseOneRepMax(exerciseId: Int, oneRepMaxKg: Double) async throws {
        struct Data: Decodable { let setExerciseOneRepMax: MutationResult }
        let result = try await client.execute(Self.setOneRepMaxMutation, variables: ["exerciseId": exerciseId, "oneRepMaxKg": oneRepMaxKg], dataType: Data.self).setExerciseOneRepMax
        guard result.ok else { throw NSError(domain: "WorkoutAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: result.message]) }
    }

    func resetToBaseline(baselineOverrides: [[String: Any]]) async throws {
        struct Data: Decodable { let resetToBaseline: MutationResult }
        let result = try await client.execute(Self.resetMutation, variables: ["baselineOverrides": baselineOverrides], dataType: Data.self).resetToBaseline
        guard result.ok else { throw NSError(domain: "WorkoutAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: result.message]) }
    }

    func sendWorkoutToStrava(sessionId: Int) async throws -> StravaSendResult {
        struct Data: Decodable { let sendWorkoutToStrava: StravaSendResult }
        return try await client.execute(Self.sendWorkoutToStravaMutation, variables: ["sessionId": sessionId], dataType: Data.self).sendWorkoutToStrava
    }

    func setStravaAutoSendOnFinish(enabled: Bool) async throws {
        struct Data: Decodable { let setStravaAutoSendOnFinish: MutationResult }
        let result = try await client.execute(Self.setStravaAutoSendOnFinishMutation, variables: ["enabled": enabled], dataType: Data.self).setStravaAutoSendOnFinish
        guard result.ok else { throw NSError(domain: "WorkoutAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: result.message]) }
    }

    func disconnectStrava() async throws {
        struct Data: Decodable { let disconnectStrava: MutationResult }
        let result = try await client.execute(Self.disconnectStravaMutation, dataType: Data.self).disconnectStrava
        guard result.ok else { throw NSError(domain: "WorkoutAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: result.message]) }
    }

    func startStravaAuth() async throws -> StravaAuthStart {
        struct Data: Decodable { let startStravaAuth: StravaAuthStart }
        return try await client.execute(Self.startStravaAuthMutation, dataType: Data.self).startStravaAuth
    }

    private struct MutationResult: Decodable {
        let ok: Bool
        let message: String
    }

    private struct HeartRateIngestResult: Decodable {
        let ok: Bool
        let message: String
        let insertedCount: Int
    }

    private struct IdOnly: Decodable {
        let id: Int
    }

    private struct CompleteSetResult: Decodable {
        let id: Int
        let completed: Bool
    }
}

private extension WorkoutAPI {
    static let dashboardQuery = """
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
    """

    static let activePlanQuery = """
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
                    progressionProtocol
                    tier
                    progressionValue
                    trainingMaxRatio
                    amrapLastSet
                }
            }
        }
    }
    """

    static let plansQuery = """
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
    """

    static let setActivePlanMutation = """
    mutation SetActivePlan($planId: Int!) {
        setActivePlan(planId: $planId) {
            ok
            message
        }
    }
    """

    static let deactivatePlanMutation = """
    mutation DeactivatePlan($planId: Int!) {
        deactivatePlan(planId: $planId) {
            ok
            message
        }
    }
    """

    static let activeSessionQuery = """
    query ActiveSession {
        activeWorkoutSession {
            id
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
                exerciseId
                exerciseName
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
                }
            }
        }
    }
    """

    static let historyQuery = """
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
        }
    }
    """

    static let progressQuery = """
    query ExerciseProgress($exerciseId: Int!, $limit: Int!) {
        exerciseProgress(exerciseId: $exerciseId, limit: $limit) {
            date
            topWeightKg
            estimated1rmKg
        }
    }
    """

    static let heartRateSamplesQuery = """
    query SessionHeartRateSamples($sessionId: Int!, $limit: Int!) {
        sessionHeartRateSamples(sessionId: $sessionId, limit: $limit) {
            id
            sessionId
            recordedAt
            bpm
            source
        }
    }
    """

    static let stravaConnectionQuery = """
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
    """

    static let appendHeartRateSamplesMutation = """
    mutation AppendHeartRateSamples($sessionId: Int!, $samples: [HeartRateSampleInput!]!) {
        appendHeartRateSamples(sessionId: $sessionId, samples: $samples) {
            ok
            message
            insertedCount
        }
    }
    """

    static let startWorkoutMutation = """
    mutation StartWorkout {
        startWorkout { id }
    }
    """

    static let completeSetMutation = """
    mutation CompleteSet($sessionSetId: Int!, $repsCompleted: Int!, $weightKg: Float, $durationSeconds: Int) {
        completeSet(sessionSetId: $sessionSetId, repsCompleted: $repsCompleted, weightKg: $weightKg, durationSeconds: $durationSeconds) {
            id
            completed
        }
    }
    """

    static let finishWorkoutMutation = """
    mutation FinishWorkout($sessionId: Int!) {
        finishWorkout(sessionId: $sessionId) {
            id
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
                exerciseId
                exerciseName
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
                }
            }
        }
    }
    """

    static let setOneRepMaxMutation = """
    mutation SetOneRepMax($exerciseId: Int!, $oneRepMaxKg: Float!) {
        setExerciseOneRepMax(exerciseId: $exerciseId, oneRepMaxKg: $oneRepMaxKg) {
            ok
            message
        }
    }
    """

    static let resetMutation = """
    mutation Reset($baselineOverrides: [BaselineInput!]) {
        resetToBaseline(baselineOverrides: $baselineOverrides) {
            ok
            message
        }
    }
    """

    static let sendWorkoutToStravaMutation = """
    mutation SendWorkoutToStrava($sessionId: Int!) {
        sendWorkoutToStrava(sessionId: $sessionId) {
            ok
            message
            activityId
            activityUrl
        }
    }
    """

    static let setStravaAutoSendOnFinishMutation = """
    mutation SetStravaAutoSendOnFinish($enabled: Boolean!) {
        setStravaAutoSendOnFinish(enabled: $enabled) {
            ok
            message
        }
    }
    """

    static let disconnectStravaMutation = """
    mutation DisconnectStrava {
        disconnectStrava {
            ok
            message
        }
    }
    """

    static let startStravaAuthMutation = """
    mutation StartStravaAuth {
        startStravaAuth {
            ok
            authUrl
            message
        }
    }
    """
}
