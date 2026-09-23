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

    func submitCurrentSet(using api: WorkoutAPI, mode: SetOutcome, repsOverride: Int?) async {
        guard let pending = pendingSet() else { return }
        var reps = pending.targetReps

        if let repsOverride {
            reps = repsOverride
        } else if pending.setItem.isAmrap {
            return
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
    @State private var showingRepsEntry = false
    @State private var repsEntryValue = ""
    @State private var repsEntryMode: SetOutcome = .success
    @State private var repsEntryTarget = 0
    @State private var repsEntryIsAmrap = false
    @StateObject private var heartRate = HeartRateBluetoothManager()

    private var api: WorkoutAPI { WorkoutAPI(endpoint: settings.graphqlEndpoint) }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Color(red: 11 / 255, green: 18 / 255, blue: 32 / 255)
                    .ignoresSafeArea()

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
            .sheet(isPresented: $showingRepsEntry) {
                RepsEntrySheet(
                    value: $repsEntryValue,
                    mode: repsEntryMode,
                    target: repsEntryTarget,
                    isAmrap: repsEntryIsAmrap,
                    onCancel: {
                        showingRepsEntry = false
                    },
                    onSubmit: {
                        guard let reps = Int(repsEntryValue) else { return }
                        if reps < 0 { return }
                        if repsEntryMode == .success && repsEntryIsAmrap && reps < repsEntryTarget { return }
                        if repsEntryMode == .failed && reps >= repsEntryTarget { return }
                        showingRepsEntry = false
                        Task {
                            await model.submitCurrentSet(using: api, mode: repsEntryMode, repsOverride: reps)
                        }
                    }
                )
                .presentationDetents([.height(230)])
            }
        }
    }

    @ViewBuilder
    private func activeSessionPanel(_ session: WorkoutSession) -> some View {
        let pending = model.pendingSet()

        if let pending {
            VStack(alignment: .leading, spacing: 14) {
                timerPanel(for: pending)

                VStack(alignment: .leading, spacing: 3) {
                    Text(pending.entry.exerciseName)
                        .font(.title2)
                        .bold()
                    Text("\(pending.targetReps)\(pending.setItem.isAmrap ? "+" : "") reps @ \(WeightMath.displayWeightFromKg(pending.weightKg, unit: settings.weightUnit)) \(settings.weightUnit.label)")
                        .foregroundStyle(.secondary)
                }

                heartRatePanel

                outcomeSelector(for: pending)
            }
            .padding(12)
            .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 14))
        } else {
            Text("All sets complete. Finishing workout…")
        }

        Divider()
        ForEach(session.entries) { entry in
            HStack(alignment: .center, spacing: 10) {
                Text(entry.exerciseName)
                    .bold()
                Spacer()
                Text("\(entry.plannedSets)x\(entry.plannedReps) @ \(WeightMath.displayWeightFromKg(entry.plannedWeightKg, unit: settings.weightUnit)) \(settings.weightUnit.label)")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }

        if pending != nil {
            Button("End workout") {
                Task { await model.endWorkout(using: api) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(.red)
            .buttonStyle(.bordered)
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
                if recentHeartRateSamples.count >= 2 {
                    Chart(recentHeartRateSamples) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("BPM", sample.bpm)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: 70...145)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.08))
                        .overlay(
                            Text("Waiting for heart-rate stream…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)

            VStack(alignment: .trailing, spacing: 4) {
                Text(heartRate.latestBpm.map { "\($0)" } ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(10)
        .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green.opacity(0.15), lineWidth: 1)
        )
    }

    private var recentHeartRateSamples: [LiveHeartRateSample] {
        guard let latest = heartRate.samples.last?.timestamp else { return [] }
        let cutoff = latest.addingTimeInterval(-10)
        return heartRate.samples.filter { $0.timestamp >= cutoff }
    }

    private func restTargetSeconds(for pending: WorkoutViewModel.PendingSet) -> Int {
        let fromProtocol: Int
        switch pending.entry.progressionProtocol {
        case .gzclpT1: fromProtocol = 180
        case .gzclpT2: fromProtocol = 120
        case .gzclpT3, .basic: fromProtocol = 90
        }
        let backendValue = pending.entry.expectedRestSeconds
        return max(backendValue, fromProtocol)
    }

    private func restState(for pending: WorkoutViewModel.PendingSet) -> String {
        let expected = restTargetSeconds(for: pending)
        if model.timerSeconds > expected { return "over" }
        if model.timerSeconds >= max(0, expected - 15) { return "warn" }
        return "ok"
    }

    private func timerColor(for pending: WorkoutViewModel.PendingSet) -> Color {
        switch restState(for: pending) {
        case "over": return .red
        case "warn": return .orange
        default: return .green
        }
    }

    private func timerPanel(for pending: WorkoutViewModel.PendingSet) -> some View {
        let expected = restTargetSeconds(for: pending)
        let mins = expected / 60
        let secs = expected % 60
        let target = "\(String(format: "%02d", mins)):\(String(format: "%02d", secs))"

        return VStack(spacing: 6) {
            SegmentedDigitalClock(text: formatTimer(model.timerSeconds), color: timerColor(for: pending))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(timerColor(for: pending).opacity(0.55), lineWidth: 2)
                )
            Text("Rest target \(target)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func outcomeSelector(for pending: WorkoutViewModel.PendingSet) -> some View {
        HStack(spacing: 10) {
            Button("Complete") {
                if pending.setItem.isAmrap {
                    repsEntryMode = .success
                    repsEntryTarget = pending.targetReps
                    repsEntryIsAmrap = true
                    repsEntryValue = "\(pending.targetReps)"
                    showingRepsEntry = true
                } else {
                    Task {
                        await model.submitCurrentSet(using: api, mode: .success, repsOverride: nil)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)

            Button("Fail") {
                repsEntryMode = .failed
                repsEntryTarget = pending.targetReps
                repsEntryIsAmrap = pending.setItem.isAmrap
                repsEntryValue = "\(max(0, pending.targetReps - 1))"
                showingRepsEntry = true
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    private var bluetoothIndicator: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.55))
                .overlay(
                    Circle().stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
                .frame(width: 44, height: 44)

            Text("ᛒ")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(heartRate.isReceivingData ? .blue : .gray)

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

private struct SegmentedDigitalClock: View {
    let text: String
    let color: Color

    var body: some View {
        let glyphs = Array(text)
        HStack(spacing: 8) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                if glyph == ":" {
                    VStack(spacing: 12) {
                        Circle().fill(color).frame(width: 9, height: 9)
                        Circle().fill(color).frame(width: 9, height: 9)
                    }
                    .frame(width: 16)
                } else {
                    SegmentedDigit(glyph: glyph, color: color)
                        .frame(width: 52, height: 96)
                }
            }
        }
    }
}

private struct SegmentedDigit: View {
    let glyph: Character
    let color: Color

    private var segments: Set<Character> {
        switch glyph {
        case "0": return ["a", "b", "c", "d", "e", "f"]
        case "1": return ["b", "c"]
        case "2": return ["a", "b", "g", "e", "d"]
        case "3": return ["a", "b", "c", "d", "g"]
        case "4": return ["f", "g", "b", "c"]
        case "5": return ["a", "f", "g", "c", "d"]
        case "6": return ["a", "f", "e", "d", "c", "g"]
        case "7": return ["a", "b", "c"]
        case "8": return ["a", "b", "c", "d", "e", "f", "g"]
        case "9": return ["a", "b", "c", "d", "f", "g"]
        default: return []
        }
    }

    var body: some View {
        ZStack {
            segmentHorizontal(on: segments.contains("a"))
                .offset(y: -40)
            segmentHorizontal(on: segments.contains("g"))
            segmentHorizontal(on: segments.contains("d"))
                .offset(y: 40)

            segmentVertical(on: segments.contains("f"))
                .offset(x: -21, y: -20)
            segmentVertical(on: segments.contains("b"))
                .offset(x: 21, y: -20)
            segmentVertical(on: segments.contains("e"))
                .offset(x: -21, y: 20)
            segmentVertical(on: segments.contains("c"))
                .offset(x: 21, y: 20)
        }
    }

    private func segmentHorizontal(on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(on ? color : Color.white.opacity(0.12))
            .frame(width: 34, height: 8)
    }

    private func segmentVertical(on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(on ? color : Color.white.opacity(0.12))
            .frame(width: 8, height: 28)
    }
}

private struct RepsEntrySheet: View {
    @Binding var value: String
    let mode: SetOutcome
    let target: Int
    let isAmrap: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter number of completed reps")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("Reps", text: $value)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("Reps")
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
