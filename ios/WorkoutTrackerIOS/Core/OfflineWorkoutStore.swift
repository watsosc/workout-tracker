import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

// MARK: - On-device workout model

struct LocalSet: Codable, Identifiable, Hashable {
    var setIndex: Int
    var targetReps: Int?
    var isAmrap: Bool
    var weightKg: Double
    var repsCompleted: Int?
    var durationSeconds: Int?
    var completedAt: Date?

    var id: Int { setIndex }
    var completed: Bool { completedAt != nil }
}

struct LocalEntry: Codable, Identifiable, Hashable {
    var planWorkoutExerciseId: Int
    var exerciseId: Int
    var exerciseName: String
    var plannedSets: Int
    var plannedReps: Int
    var plannedWeightKg: Double
    var progressionProtocol: ProtocolType
    var tier: String?
    var equipmentType: String?
    var expectedRestSeconds: Int
    var sets: [LocalSet]

    var id: Int { planWorkoutExerciseId }

    /// Rest target, never shorter than the protocol's usual rest.
    var restTargetSeconds: Int {
        let fromProtocol: Int
        switch progressionProtocol {
        case .gzclpT1: fromProtocol = 180
        case .gzclpT2: fromProtocol = 120
        case .gzclpT3, .basic: fromProtocol = 90
        }
        return max(expectedRestSeconds, fromProtocol)
    }
}

struct LocalHeartRateSample: Codable, Hashable {
    var recordedAt: Date
    var bpm: Int
}

/// A workout recorded entirely on the phone and uploaded in one go (`logWorkout`) when finished.
struct LocalWorkout: Codable, Identifiable, Hashable {
    var clientId: String
    /// Set when this workout was started on the server (e.g. on web) and resumed on the phone.
    var serverSessionId: Int?
    var planWorkoutId: Int
    var planName: String
    var workoutName: String
    var startedAt: Date
    var finishedAt: Date?
    var entries: [LocalEntry]
    var heartRateSamples: [LocalHeartRateSample] = []
    var lastSetCompletedAt: Date?

    var id: String { clientId }

    struct SetPosition: Hashable {
        let entryIndex: Int
        let setIndex: Int
    }

    func pendingSetPosition() -> SetPosition? {
        for (e, entry) in entries.enumerated() {
            if let s = entry.sets.firstIndex(where: { !$0.completed }) {
                return SetPosition(entryIndex: e, setIndex: s)
            }
        }
        return nil
    }

    func lastCompletedPosition() -> SetPosition? {
        var latest: (SetPosition, Date)?
        for (e, entry) in entries.enumerated() {
            for (s, set) in entry.sets.enumerated() {
                guard let at = set.completedAt else { continue }
                if latest == nil || at >= latest!.1 { latest = (SetPosition(entryIndex: e, setIndex: s), at) }
            }
        }
        return latest?.0
    }

    var completedSetCount: Int { entries.reduce(0) { $0 + $1.sets.filter(\.completed).count } }
    var totalSetCount: Int { entries.reduce(0) { $0 + $1.sets.count } }
}

extension LocalWorkout {
    init(prescription rx: WorkoutPrescription, now: Date = Date()) {
        self.init(
            clientId: UUID().uuidString,
            serverSessionId: nil,
            planWorkoutId: rx.planWorkoutId,
            planName: rx.planName,
            workoutName: rx.workoutName,
            startedAt: now,
            entries: rx.entries.map { e in
                LocalEntry(
                    planWorkoutExerciseId: e.planWorkoutExerciseId,
                    exerciseId: e.exerciseId,
                    exerciseName: e.exerciseName,
                    plannedSets: e.plannedSets,
                    plannedReps: e.plannedReps,
                    plannedWeightKg: e.plannedWeightKg,
                    progressionProtocol: e.progressionProtocol,
                    tier: e.tier,
                    equipmentType: e.equipmentType,
                    expectedRestSeconds: e.expectedRestSeconds,
                    sets: e.sets.map {
                        LocalSet(setIndex: $0.setIndex, targetReps: $0.targetReps, isAmrap: $0.isAmrap, weightKg: $0.weightKg)
                    }
                )
            }
        )
    }

    /// Resume a workout that was started on the server, keeping any sets already logged there.
    init(serverSession s: WorkoutSession, planName: String) {
        let completedTimes = s.entries.flatMap(\.sets).compactMap { ISO8601.parse($0.completedAt) }
        self.init(
            clientId: UUID().uuidString,
            serverSessionId: s.id,
            planWorkoutId: s.planWorkoutId,
            planName: planName,
            workoutName: s.planWorkoutName,
            startedAt: ISO8601.parse(s.startedAt) ?? Date(),
            entries: s.entries.map { e in
                LocalEntry(
                    planWorkoutExerciseId: e.planWorkoutExerciseId,
                    exerciseId: e.exerciseId,
                    exerciseName: e.exerciseName,
                    plannedSets: e.plannedSets,
                    plannedReps: e.plannedReps,
                    plannedWeightKg: e.plannedWeightKg,
                    progressionProtocol: e.progressionProtocol,
                    tier: e.tier,
                    equipmentType: e.equipmentType,
                    expectedRestSeconds: e.expectedRestSeconds,
                    sets: e.sets.map { set in
                        LocalSet(
                            setIndex: set.setIndex,
                            targetReps: set.targetReps,
                            isAmrap: set.isAmrap,
                            weightKg: set.weightKg ?? e.plannedWeightKg,
                            repsCompleted: set.completed ? set.repsCompleted : nil,
                            durationSeconds: set.completed ? set.durationSeconds : nil,
                            completedAt: set.completed ? (ISO8601.parse(set.completedAt) ?? Date()) : nil
                        )
                    }
                )
            },
            lastSetCompletedAt: completedTimes.max()
        )
    }

    /// GraphQL `LogWorkoutInput` variables.
    func logWorkoutInput() -> [String: Any] {
        var input: [String: Any] = [
            "clientId": clientId,
            "planWorkoutId": planWorkoutId,
            "startedAt": ISO8601.string(startedAt),
            "finishedAt": ISO8601.string(finishedAt ?? Date()),
            "entries": entries.map { e -> [String: Any] in
                [
                    "planWorkoutExerciseId": e.planWorkoutExerciseId,
                    "plannedSets": e.plannedSets,
                    "plannedReps": e.plannedReps,
                    "plannedWeightKg": e.plannedWeightKg,
                    "sets": e.sets.map { s -> [String: Any] in
                        var row: [String: Any] = [
                            "setIndex": s.setIndex,
                            "isAmrap": s.isAmrap,
                            "weightKg": s.weightKg,
                            "completed": s.completed
                        ]
                        if let v = s.targetReps { row["targetReps"] = v }
                        if let v = s.repsCompleted { row["repsCompleted"] = v }
                        if let v = s.durationSeconds { row["durationSeconds"] = v }
                        if let v = s.completedAt { row["completedAt"] = ISO8601.string(v) }
                        return row
                    }
                ]
            },
            "heartRateSamples": heartRateSamples.map {
                ["recordedAt": ISO8601.string($0.recordedAt), "bpm": $0.bpm, "source": "GARMIN_BLE"]
            }
        ]
        if let serverSessionId { input["sessionId"] = serverSessionId }
        return input
    }
}

enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func string(_ date: Date) -> String { withFraction.string(from: date) }

    /// Parses server timestamps, which may lack a timezone (naive UTC) or fractional seconds.
    static func parse(_ value: String?) -> Date? {
        guard var value, !value.isEmpty else { return nil }
        let hasZone = value.hasSuffix("Z") || value.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        if !hasZone { value += "Z" }
        return withFraction.date(from: value) ?? plain.date(from: value)
    }
}

// MARK: - Upload queue

struct OutboxItem: Codable, Identifiable, Hashable {
    enum Kind: Codable, Hashable {
        case logWorkout(LocalWorkout)
        case cancelServerSession(Int)
    }

    var id = UUID()
    var kind: Kind
    var createdAt = Date()
    var attempts = 0
    var lastError: String?
    /// The server rejected this item outright; it waits for the user to retry or discard it.
    var needsAttention = false

    var title: String {
        switch kind {
        case .logWorkout(let w): return "\(w.workoutName) · \(w.completedSetCount)/\(w.totalSetCount) sets"
        case .cancelServerSession: return "Discard server workout"
        }
    }
}

struct UploadSummary: Hashable {
    let workoutName: String
    let personalRecords: [PersonalRecord]
    let stravaStatus: WorkoutExportStatus?
    let wasQueued: Bool
}

private struct PersistedState: Codable {
    var activeWorkout: LocalWorkout?
    var outbox: [OutboxItem] = []
    var cachedPrescription: WorkoutPrescription?
    var prescriptionFetchedAt: Date?
    /// True when the server said there is no active plan (as opposed to "never fetched").
    var noActivePlan = false
}

// MARK: - Store

/// Owns the in-progress workout and the upload queue, persisted to disk so nothing is lost if the
/// app is killed mid-workout or there's no signal. Workouts are uploaded with `logWorkout` once
/// finished, retrying automatically whenever connectivity returns.
@MainActor
final class OfflineWorkoutStore: ObservableObject {
    @Published private(set) var activeWorkout: LocalWorkout?
    @Published private(set) var outbox: [OutboxItem] = []
    @Published private(set) var cachedPrescription: WorkoutPrescription?
    @Published private(set) var prescriptionFetchedAt: Date?
    @Published private(set) var noActivePlan = false
    @Published private(set) var isOnline = true
    @Published private(set) var isSyncing = false
    @Published var lastUpload: UploadSummary?

    /// Supplies an API client built from current settings (endpoint/token can change at runtime).
    var apiProvider: (() -> WorkoutAPI)?

    private let fileURL: URL
    private let monitor = NWPathMonitor()
    private var retryTask: Task<Void, Never>?
    private var unsavedHeartRateSamples = 0

    init(fileURL: URL? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? dir.appendingPathComponent("offline-workouts.json")
        load()

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                let cameOnline = online && !self.isOnline
                self.isOnline = online
                if cameOnline { await self.syncNow() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "workout.network-monitor"))
    }

    var pendingUploadCount: Int { outbox.count }
    var hasPendingWorkoutUploads: Bool {
        outbox.contains { if case .logWorkout = $0.kind { return true } else { return false } }
    }

    // MARK: Prescription cache

    func cachePrescription(_ rx: WorkoutPrescription?) {
        cachedPrescription = rx
        noActivePlan = rx == nil
        prescriptionFetchedAt = Date()
        save()
    }

    // MARK: Workout lifecycle

    func startWorkout(from rx: WorkoutPrescription) {
        guard activeWorkout == nil else { return }
        activeWorkout = LocalWorkout(prescription: rx)
        save()
    }

    func resumeServerWorkout(_ session: WorkoutSession, planName: String) {
        guard activeWorkout == nil else { return }
        activeWorkout = LocalWorkout(serverSession: session, planName: planName)
        save()
    }

    func completeSet(at position: LocalWorkout.SetPosition, reps: Int, now: Date = Date()) {
        guard var workout = activeWorkout else { return }
        let restStart = workout.lastSetCompletedAt ?? workout.startedAt
        workout.entries[position.entryIndex].sets[position.setIndex].repsCompleted = max(0, reps)
        workout.entries[position.entryIndex].sets[position.setIndex].durationSeconds = max(0, Int(now.timeIntervalSince(restStart)))
        workout.entries[position.entryIndex].sets[position.setIndex].completedAt = now
        workout.lastSetCompletedAt = now
        activeWorkout = workout
        save()
    }

    func undoLastSet() {
        guard var workout = activeWorkout, let position = workout.lastCompletedPosition() else { return }
        workout.entries[position.entryIndex].sets[position.setIndex].repsCompleted = nil
        workout.entries[position.entryIndex].sets[position.setIndex].durationSeconds = nil
        workout.entries[position.entryIndex].sets[position.setIndex].completedAt = nil
        workout.lastSetCompletedAt = workout.entries.flatMap(\.sets).compactMap(\.completedAt).max()
        activeWorkout = workout
        save()
    }

    func appendHeartRate(bpm: Int, at date: Date) {
        guard activeWorkout != nil else { return }
        activeWorkout?.heartRateSamples.append(LocalHeartRateSample(recordedAt: date, bpm: bpm))
        unsavedHeartRateSamples += 1
        // Samples arrive ~1/s; don't rewrite the file every time.
        if unsavedHeartRateSamples >= 15 { save() }
    }

    /// Finish locally and queue the upload. The next workout's prescription is unknown until the
    /// server has processed this one, so the cached prescription is dropped.
    func finishActiveWorkout() {
        guard var workout = activeWorkout else { return }
        workout.finishedAt = Date()
        outbox.append(OutboxItem(kind: .logWorkout(workout)))
        activeWorkout = nil
        cachedPrescription = nil
        prescriptionFetchedAt = nil
        save()
        Task { await syncNow(immediate: true) }
    }

    func discardActiveWorkout() {
        guard let workout = activeWorkout else { return }
        if let serverId = workout.serverSessionId {
            outbox.append(OutboxItem(kind: .cancelServerSession(serverId)))
        }
        activeWorkout = nil
        save()
        Task { await syncNow() }
    }

    // MARK: Outbox management

    func retry(_ item: OutboxItem) {
        guard let index = outbox.firstIndex(where: { $0.id == item.id }) else { return }
        outbox[index].needsAttention = false
        outbox[index].lastError = nil
        save()
        Task { await syncNow() }
    }

    func discard(_ item: OutboxItem) {
        outbox.removeAll { $0.id == item.id }
        save()
    }

    // MARK: Sync

    /// Upload queued items in order. Stops at the first connectivity failure and retries later.
    func syncNow(immediate: Bool = false) async {
        guard !isSyncing, let api = apiProvider?() else { return }
        guard outbox.contains(where: { !$0.needsAttention }) else { return }

        isSyncing = true
        #if canImport(UIKit)
        // Let an upload that's underway finish if the app is backgrounded mid-request.
        let background = UIApplication.shared.beginBackgroundTask(withName: "workout-upload")
        #endif
        defer {
            isSyncing = false
            #if canImport(UIKit)
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            #endif
        }

        while let item = outbox.first(where: { !$0.needsAttention }) {
            do {
                switch item.kind {
                case .logWorkout(let workout):
                    let session = try await api.logWorkout(workout)
                    lastUpload = UploadSummary(
                        workoutName: workout.workoutName,
                        personalRecords: session.personalRecords ?? [],
                        stravaStatus: session.stravaExportStatus,
                        wasQueued: !immediate || item.attempts > 0
                    )
                case .cancelServerSession(let sessionId):
                    try await api.cancelWorkout(sessionId: sessionId)
                }
                outbox.removeAll { $0.id == item.id }
                save()
            } catch {
                guard let index = outbox.firstIndex(where: { $0.id == item.id }) else { break }
                outbox[index].attempts += 1
                outbox[index].lastError = error.localizedDescription
                if Self.isTransient(error) {
                    save()
                    scheduleRetry(attempt: outbox[index].attempts)
                    return
                }
                outbox[index].needsAttention = true
                save()
            }
        }
    }

    private func scheduleRetry(attempt: Int) {
        retryTask?.cancel()
        let delay = min(300.0, 10.0 * pow(2.0, Double(max(0, attempt - 1))))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let gql = error as? GraphQLClientError { return gql.isTransient }
        return (error as NSError).domain == NSURLErrorDomain
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        activeWorkout = state.activeWorkout
        outbox = state.outbox
        cachedPrescription = state.cachedPrescription
        prescriptionFetchedAt = state.prescriptionFetchedAt
        noActivePlan = state.noActivePlan
    }

    func save() {
        unsavedHeartRateSamples = 0
        let state = PersistedState(
            activeWorkout: activeWorkout,
            outbox: outbox,
            cachedPrescription: cachedPrescription,
            prescriptionFetchedAt: prescriptionFetchedAt,
            noActivePlan: noActivePlan
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
