import Foundation

struct WorkoutAPI {
    private let client: GraphQLClient

    init(endpoint: String, token: String? = nil, onUnauthorized: (@Sendable () -> Void)? = nil) {
        self.client = GraphQLClient(endpoint: endpoint, token: token, onUnauthorized: onUnauthorized)
    }

    struct AuthStatus: Decodable {
        let authRequired: Bool
        let signedIn: Bool
        let username: String?
    }

    struct SessionToken {
        let token: String
        let username: String
    }

    func fetchAuthStatus() async throws -> AuthStatus {
        struct Data: Decodable { let authStatus: AuthStatus }
        return try await client.execute("query { authStatus { authRequired signedIn username } }", dataType: Data.self).authStatus
    }

    func login(username: String, password: String) async throws -> SessionToken {
        struct Result: Decodable { let ok: Bool; let message: String; let token: String?; let username: String? }
        struct Data: Decodable { let login: Result }
        let result = try await client.execute(
            "mutation($u: String!, $p: String!) { login(username: $u, password: $p) { ok message token username } }",
            variables: ["u": username, "p": password],
            dataType: Data.self
        ).login
        guard result.ok, let token = result.token else {
            throw NSError(domain: "WorkoutAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: result.message])
        }
        return SessionToken(token: token, username: result.username ?? username)
    }

    func logout() async throws {
        struct Data: Decodable { let logout: MutationResult }
        _ = try await client.execute("mutation { logout { ok message } }", dataType: Data.self)
    }

    func fetchWorkoutPrescription() async throws -> WorkoutPrescription? {
        struct Data: Decodable { let workoutPrescription: WorkoutPrescription? }
        return try await client.execute(Self.prescriptionQuery, dataType: Data.self).workoutPrescription
    }

    /// Upload a whole workout recorded on-device. Idempotent on the workout's clientId.
    func logWorkout(_ workout: LocalWorkout) async throws -> WorkoutSession {
        struct Data: Decodable { let logWorkout: WorkoutSession }
        return try await client.execute(
            Self.logWorkoutMutation,
            variables: ["input": workout.logWorkoutInput()],
            dataType: Data.self
        ).logWorkout
    }

    func fetchExerciseNames() async throws -> [String] {
        struct Exercise: Decodable { let name: String }
        struct Data: Decodable { let exercises: [Exercise] }
        return try await client.execute("query { exercises { name } }", dataType: Data.self).exercises.map(\.name)
    }

    func fetchWorkoutSession(id: Int) async throws -> WorkoutSession? {
        struct Data: Decodable { let workoutSession: WorkoutSession? }
        let query = Self.activeSessionQuery
            .replacingOccurrences(of: "query ActiveSession {", with: "query WorkoutSession($id: Int!) {")
            .replacingOccurrences(of: "activeWorkoutSession {", with: "workoutSession(sessionId: $id) {")
        return try await client.execute(query, variables: ["id": id], dataType: Data.self).workoutSession
    }

    func updateWorkout(sessionId: Int, sets: [[String: Any]]) async throws -> WorkoutEditResult {
        struct Data: Decodable { let updateWorkout: WorkoutEditResult }
        let result = try await client.execute(
            "mutation($s: Int!, $sets: [SetEditInput!]!) { updateWorkout(sessionId: $s, sets: $sets) { ok message progressionRecalculated } }",
            variables: ["s": sessionId, "sets": sets],
            dataType: Data.self
        ).updateWorkout
        guard result.ok else { throw NSError(domain: "WorkoutAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: result.message]) }
        return result
    }

    func deleteWorkout(sessionId: Int) async throws -> WorkoutEditResult {
        struct Data: Decodable { let deleteWorkout: WorkoutEditResult }
        let result = try await client.execute(
            "mutation($s: Int!) { deleteWorkout(sessionId: $s) { ok message progressionRecalculated } }",
            variables: ["s": sessionId],
            dataType: Data.self
        ).deleteWorkout
        guard result.ok else { throw NSError(domain: "WorkoutAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: result.message]) }
        return result
    }

    func cancelWorkout(sessionId: Int) async throws {
        struct Data: Decodable { let cancelWorkout: MutationResult }
        // ok=false here only means there was nothing left to cancel; either way we're done.
        _ = try await client.execute(Self.cancelWorkoutMutation, variables: ["sessionId": sessionId], dataType: Data.self)
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

    static let prescriptionQuery = """
    query WorkoutPrescription {
        workoutPrescription {
            planId
            planName
            planWorkoutId
            workoutName
            sequenceIndex
            week
            blockedReason
            entries {
                planWorkoutExerciseId
                exerciseId
                exerciseName
                plannedSets
                plannedReps
                plannedWeightKg
                progressionProtocol
                tier
                equipmentType
                expectedRestSeconds
                sets { setIndex targetReps isAmrap weightKg }
            }
        }
    }
    """

    static let logWorkoutMutation = """
    mutation LogWorkout($input: LogWorkoutInput!) {
        logWorkout(input: $input) {
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
            planWorkoutId
            planWorkoutName
            personalRecords { exerciseName kind valueKg reps previousKg }
            entries {
                id
                planWorkoutExerciseId
                equipmentType
                exerciseId
                exerciseName
                plannedSets
                plannedReps
                plannedWeightKg
                progressionProtocol
                tier
                expectedRestSeconds
                sets { id setIndex targetReps isAmrap repsCompleted weightKg durationSeconds completed completedAt skipped }
            }
        }
    }
    """

    static let cancelWorkoutMutation = """
    mutation CancelWorkout($sessionId: Int!) {
        cancelWorkout(sessionId: $sessionId) {
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
            planWorkoutId
            planWorkoutName
            personalRecords { exerciseName kind valueKg reps previousKg }
            entries {
                id
                planWorkoutExerciseId
                equipmentType
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
                    skipped
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
            personalRecords { exerciseName kind valueKg reps previousKg }
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
