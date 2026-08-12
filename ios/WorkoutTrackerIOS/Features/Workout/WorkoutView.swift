import SwiftUI
import Charts

@MainActor
final class WorkoutViewModel: ObservableObject {
    struct PendingSet {
        let entry: SessionEntry
        let setItem: SessionSet
        let targetReps: Int
        let weightKg: Double
    }

    @Published var loading = false
    @Published var errorMessage = ""
    @Published var infoMessage = ""
    @Published var activePlan: ActivePlan?
    @Published var dashboard: Dashboard?
    @Published var activeSession: WorkoutSession?
    @Published var timerSeconds = 0

    private var timerTask: Task<Void, Never>?

    deinit { timerTask?.cancel() }

    func load(using api: WorkoutAPI) async {
        loading = true
        errorMessage = ""
        do {
            async let plan = api.fetchActivePlan()
            async let dash = api.fetchDashboard()
            async let session = api.fetchActiveSession()
            activePlan = try await plan
            dashboard = try await dash
            activeSession = try await session
            syncTimer()
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func startWorkout(using api: WorkoutAPI) async {
        await run(api: api, success: "Workout started") {
            try await api.startWorkout()
        }
        if activeSession != nil { startTimer() }
    }

    func endWorkout(using api: WorkoutAPI) async {
        guard let session = activeSession else { return }
        do {
            let finished = try await api.finishWorkout(sessionId: session.id)
            infoMessage = finished.stravaExportStatus == .sent ? "Workout finished and sent to Strava" : "Workout finished"
            await load(using: api)
            stopTimer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submitCurrentSet(using api: WorkoutAPI, mode: SetOutcome, amrapReps: Int?) async {
        guard let pending = pendingSet() else { return }
        var reps = pending.targetReps

        if pending.setItem.isAmrap {
            guard let amrapReps else { return }
            reps = amrapReps
        } else if mode == .failed {
            reps = max(0, pending.targetReps - 1)
        }

        do {
            try await api.completeSet(
                sessionSetId: pending.setItem.id,
                repsCompleted: reps,
                weightKg: pending.weightKg,
                durationSeconds: max(0, timerSeconds)
            )
            await load(using: api)
            if pendingSet() == nil, let session = activeSession {
                _ = try await api.finishWorkout(sessionId: session.id)
                await load(using: api)
                infoMessage = "Workout finished"
                stopTimer()
            } else {
                startTimer()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pendingSet() -> PendingSet? {
        guard let session = activeSession else { return nil }
        for entry in session.entries {
            for setItem in entry.sets where !setItem.completed {
                return PendingSet(
                    entry: entry,
                    setItem: setItem,
                    targetReps: setItem.targetReps ?? entry.plannedReps,
                    weightKg: setItem.weightKg ?? entry.plannedWeightKg
                )
            }
        }
        return nil
    }

    func upcomingWorkoutName() -> String? {
        guard let activePlan, !activePlan.workouts.isEmpty else { return nil }
        let index = min(max(activePlan.currentWorkoutIndex, 0), activePlan.workouts.count - 1)
        return activePlan.workouts[index].name
    }

    func workoutPreviewRows() -> [ActivePlanExercise] {
        guard let activePlan, !activePlan.workouts.isEmpty else { return [] }
        let index = min(max(activePlan.currentWorkoutIndex, 0), activePlan.workouts.count - 1)
        return activePlan.workouts[index].exercises
    }

    private func run(api: WorkoutAPI, success: String, action: () async throws -> Void) async {
        loading = true
        errorMessage = ""
        do {
            try await action()
            await load(using: api)
            infoMessage = success
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func syncTimer() {
        if activeSession == nil {
            stopTimer()
            timerSeconds = 0
        } else if timerTask == nil {
            startTimer()
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerSeconds = 0
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                timerSeconds += 1
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}

enum SetOutcome {
    case success
    case failed
}

struct WorkoutView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = WorkoutViewModel()
    @State private var showingAmrapEntry = false
    @State private var amrapValue = ""
    @State private var amrapMode: SetOutcome = .success
    @StateObject private var heartRate = HeartRateBluetoothManager()

    private var api: WorkoutAPI { WorkoutAPI(endpoint: settings.graphqlEndpoint) }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.loading {
                            ProgressView()
                        }

                        if !model.errorMessage.isEmpty {
                            Text(model.errorMessage)
                                .foregroundStyle(.red)
                        }

                        if !model.infoMessage.isEmpty {
                            Text(model.infoMessage)
                                .foregroundStyle(.green)
                        }

                        if let session = model.activeSession {
                            activeSessionPanel(session)
                        } else {
                            startPanel
                        }
                    }
                    .padding()
                }

                if model.activeSession != nil {
                    bluetoothIndicator
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                }
            }
            .navigationTitle("Workout")
            .task { await model.load(using: api) }
            .onChange(of: model.activeSession?.id) { sessionId in
                guard let sessionId else {
                    heartRate.stop()
                    return
                }
                heartRate.start(for: sessionId, api: api)
            }
            .onDisappear {
                heartRate.stop()
            }
            .sheet(isPresented: $showingAmrapEntry) {
                AmrapEntrySheet(
                    value: $amrapValue,
                    mode: amrapMode,
                    target: model.pendingSet()?.targetReps ?? 0,
                    onCancel: { showingAmrapEntry = false },
                    onSubmit: {
                        guard let reps = Int(amrapValue) else { return }
                        let target = model.pendingSet()?.targetReps ?? 0
                        if amrapMode == .success, reps < target { return }
                        if amrapMode == .failed, reps >= target { return }
                        showingAmrapEntry = false
                        Task { await model.submitCurrentSet(using: api, mode: amrapMode, amrapReps: reps) }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func activeSessionPanel(_ session: WorkoutSession) -> some View {
        heartRatePanel

        if let pending = model.pendingSet() {
            VStack(alignment: .leading, spacing: 12) {
                Text(pending.entry.exerciseName).font(.title2).bold()
                Text("\(pending.targetReps)\(pending.setItem.isAmrap ? "+" : "") reps @ \(WeightMath.displayWeightFromKg(pending.weightKg, unit: settings.weightUnit)) \(settings.weightUnit.label)")
                    .foregroundStyle(.secondary)

                Text("Rest timer: \(formatTimer(model.timerSeconds))")
                    .font(.system(.title3, design: .monospaced))

                HStack {
                    Button("Complete") {
                        if pending.setItem.isAmrap {
                            amrapMode = .success
                            amrapValue = "\(pending.targetReps)"
                            showingAmrapEntry = true
                        } else {
                            Task { await model.submitCurrentSet(using: api, mode: .success, amrapReps: nil) }
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Fail") {
                        if pending.setItem.isAmrap {
                            amrapMode = .failed
                            amrapValue = "\(max(0, pending.targetReps - 1))"
                            showingAmrapEntry = true
                        } else {
                            Task { await model.submitCurrentSet(using: api, mode: .failed, amrapReps: nil) }
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Button("End workout") {
                    Task { await model.endWorkout(using: api) }
                }
                .foregroundStyle(.red)
            }
        } else {
            Text("All sets complete. Finishing workout…")
        }

        Divider()
        ForEach(session.entries) { entry in
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.exerciseName).bold()
                Text("\(entry.plannedSets)x\(entry.plannedReps) @ \(WeightMath.displayWeightFromKg(entry.plannedWeightKg, unit: settings.weightUnit)) \(settings.weightUnit.label)")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var startPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let name = model.upcomingWorkoutName() {
                Text("Next workout: \(name)")
                    .font(.headline)
            }

            ForEach(model.workoutPreviewRows()) { exercise in
                HStack {
                    Text(exercise.exerciseName)
                    Spacer()
                    Text("\(exercise.sets)x\(exercise.reps) @ \(WeightMath.displayWeightFromKg(exercise.targetWeightKg, unit: settings.weightUnit))")
                        .foregroundStyle(.secondary)
                }
            }

            Button("Start workout") {
                Task { await model.startWorkout(using: api) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.loading || model.activePlan == nil)

            if model.activePlan == nil {
                Text("No active plan found. Build a plan on web first.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var heartRatePanel: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if heartRate.samples.count >= 2 {
                    Chart(heartRate.samples) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("BPM", sample.bpm)
                        )
                        .foregroundStyle(.pink)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Heart rate")
                            .font(.headline)
                        Text("Waiting for heart-rate stream…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)

            VStack(alignment: .trailing, spacing: 4) {
                Text("Latest")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(heartRate.latestBpm.map { "\($0) bpm" } ?? "—")
                    .font(.title3)
                    .bold()
                    .foregroundStyle(heartRate.isReceivingData ? .blue : .secondary)
                Text(heartRate.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .frame(width: 130, alignment: .trailing)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var bluetoothIndicator: some View {
        ZStack {
            Circle()
                .fill(Color(.systemBackground).opacity(0.85))
                .frame(width: 42, height: 42)

            Image(systemName: "bluetooth")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(heartRate.isReceivingData ? .blue : .gray)

            if !heartRate.isReceivingData {
                Rectangle()
                    .fill(Color.gray)
                    .frame(width: 24, height: 2)
                    .rotationEffect(.degrees(-35))
            }
        }
        .accessibilityLabel(heartRate.isReceivingData ? "Bluetooth heart-rate connected" : "Bluetooth heart-rate disconnected")
    }

    private func formatTimer(_ value: Int) -> String {
        let mins = value / 60
        let secs = value % 60
        return "\(String(format: "%02d", mins)):\(String(format: "%02d", secs))"
    }
}

private struct AmrapEntrySheet: View {
    @Binding var value: String
    let mode: SetOutcome
    let target: Int
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(mode == .success ? "AMRAP success" : "AMRAP failed") {
                    Text(mode == .success ? "Enter reps (must be ≥ \(target))" : "Enter reps (must be < \(target))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("Reps", text: $value)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("AMRAP")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSubmit)
                }
            }
        }
    }
}
