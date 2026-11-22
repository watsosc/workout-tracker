import SwiftUI
import Charts

/// Drives the Workout tab. The workout itself lives in `OfflineWorkoutStore` (on-device, persisted)
/// and is uploaded in one go when finished, so logging works with no signal.
@MainActor
final class WorkoutViewModel: ObservableObject {
    @Published var loading = false
    @Published var errorMessage = ""
    @Published var infoMessage = ""
    @Published var now = Date()

    private var tickTask: Task<Void, Never>?

    deinit { tickTask?.cancel() }

    func load(api: WorkoutAPI, store: OfflineWorkoutStore) async {
        loading = true
        errorMessage = ""
        defer { loading = false }

        await store.syncNow()
        // The server can't know what's next until every finished workout has been uploaded.
        guard !store.hasPendingWorkoutUploads else { return }

        do {
            async let rx = api.fetchWorkoutPrescription()
            async let serverSession = api.fetchActiveSession()
            let (prescription, session) = try await (rx, serverSession)
            store.cachePrescription(prescription)
            if let names = try? await api.fetchExerciseNames() { store.cacheExerciseNames(names) }
            if store.activeWorkout == nil, let session {
                store.resumeServerWorkout(session, planName: prescription?.planName ?? "")
                infoMessage = "Resumed the workout that was started on another device"
            }
        } catch GraphQLClientError.unauthorized {
            errorMessage = GraphQLClientError.unauthorized.localizedDescription
        } catch {
            // Offline or flaky signal: carry on with the cached plan.
            if !OfflineWorkoutStore.isTransient(error) { errorMessage = error.localizedDescription }
        }
    }

    func startWorkout(api: WorkoutAPI, store: OfflineWorkoutStore) async {
        errorMessage = ""
        infoMessage = ""
        // Prefer the prescription cached when the tab loaded: starting must not wait on a weak signal.
        if store.cachedPrescription == nil, !store.hasPendingWorkoutUploads {
            loading = true
            if let fresh = try? await api.fetchWorkoutPrescription() { store.cachePrescription(fresh) }
            loading = false
        }

        guard let rx = store.cachedPrescription else {
            if store.hasPendingWorkoutUploads {
                errorMessage = "Your last workout is still waiting to upload. The next one will be ready once it syncs."
            } else if store.noActivePlan {
                errorMessage = "No active plan. Pick one in Settings → Plans."
            } else {
                errorMessage = "Connect to the internet once to download your plan."
            }
            return
        }
        if let reason = rx.blockedReason {
            errorMessage = reason
            return
        }
        RestTimerNotifier.shared.requestAuthorizationIfNeeded()
        store.startWorkout(from: rx)
    }

    func submitCurrentSet(store: OfflineWorkoutStore, mode: SetOutcome, repsOverride: Int?) {
        guard let workout = store.activeWorkout, let position = workout.pendingSetPosition() else { return }
        let entry = workout.entries[position.entryIndex]
        let set = entry.sets[position.setIndex]
        let target = set.targetReps ?? entry.plannedReps

        var reps = target
        if let repsOverride {
            reps = repsOverride
        } else if set.isAmrap {
            return
        } else if mode == .failed {
            reps = max(0, target - 1)
        }

        store.completeSet(at: position, reps: reps)
        now = Date()
        scheduleRestNotification(store: store)
    }

    func undoLastSet(store: OfflineWorkoutStore) {
        store.undoLastSet()
        RestTimerNotifier.shared.cancel()
        now = Date()
    }

    func finishWorkout(store: OfflineWorkoutStore) {
        RestTimerNotifier.shared.cancel()
        store.finishActiveWorkout()
        infoMessage = store.isOnline ? "Workout saved · uploading…" : "Workout saved on this phone · it will upload when you're back online"
    }

    func discardWorkout(store: OfflineWorkoutStore) {
        RestTimerNotifier.shared.cancel()
        store.discardActiveWorkout()
        infoMessage = "Workout discarded"
    }

    func restSeconds(store: OfflineWorkoutStore) -> Int {
        guard let workout = store.activeWorkout else { return 0 }
        return max(0, Int(now.timeIntervalSince(workout.lastSetCompletedAt ?? workout.startedAt)))
    }

    func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func scheduleRestNotification(store: OfflineWorkoutStore) {
        guard let workout = store.activeWorkout, let next = workout.pendingSetPosition() else {
            RestTimerNotifier.shared.cancel()
            return
        }
        let entry = workout.entries[next.entryIndex]
        let set = entry.sets[next.setIndex]
        let reps = "\(set.targetReps ?? entry.plannedReps)\(set.isAmrap ? "+" : "")"
        RestTimerNotifier.shared.scheduleRestEnd(
            after: entry.restTargetSeconds,
            nextSet: "\(entry.exerciseName) · set \(set.setIndex) · \(reps) reps"
        )
    }
}

enum SetOutcome {
    case success
    case failed
}

struct WorkoutView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: OfflineWorkoutStore
    @StateObject private var model = WorkoutViewModel()
    @StateObject private var heartRate = HeartRateBluetoothManager()
    @State private var showingRepsEntry = false
    @State private var repsEntryValue = ""
    @State private var repsEntryMode: SetOutcome = .success
    @State private var repsEntryTarget = 0
    @State private var repsEntryIsAmrap = false
    @State private var confirmingDiscard = false
    @State private var weightEntry: WeightEntry?
    @State private var showingAddExercise = false
    @State private var swapEntryIndex: Int?
    @State private var swapName = ""
    @State private var showingEmptyWorkoutName = false
    @State private var emptyWorkoutName = "Workout"

    private struct WeightEntry: Identifiable {
        let entryIndex: Int
        let exerciseName: String
        var value: String
        var id: Int { entryIndex }
    }

    private var api: WorkoutAPI { settings.api }
    private var unit: WeightUnit { settings.weightUnit }

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

                        statusBanners

                        if !model.errorMessage.isEmpty {
                            Text(model.errorMessage)
                                .foregroundStyle(.red)
                        }

                        if !model.infoMessage.isEmpty {
                            Text(model.infoMessage)
                                .foregroundStyle(.green)
                        }

                        if let workout = store.activeWorkout {
                            activeWorkoutPanel(workout)
                        } else {
                            startPanel
                        }
                    }
                    .padding()
                }

                if store.activeWorkout != nil {
                    bluetoothIndicator
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                }
            }
            .navigationTitle("Workout")
            .task {
                await model.load(api: api, store: store)
                syncHeartRateAndTicker()
            }
            .onChange(of: store.activeWorkout?.clientId) { _ in
                syncHeartRateAndTicker()
            }
            .confirmationDialog("Discard this workout?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard workout", role: .destructive) { model.discardWorkout(store: store) }
                Button("Keep going", role: .cancel) {}
            } message: {
                Text("Logged sets are thrown away and the plan does not advance.")
            }
            .sheet(item: $weightEntry) { entry in
                WeightEntrySheet(
                    title: entry.exerciseName,
                    unit: unit,
                    initial: entry.value,
                    onCancel: { weightEntry = nil },
                    onSave: { value in
                        store.changeWeight(entryIndex: entry.entryIndex, weightKg: WeightMath.convertUnitToKg(value, unit: unit))
                        weightEntry = nil
                    }
                )
                .presentationDetents([.height(260)])
            }
            .sheet(isPresented: $showingAddExercise) {
                AddExerciseSheet(unit: unit, suggestions: store.exerciseNames) { name, sets, reps, weight in
                    store.addExercise(name: name, sets: sets, reps: reps, weightKg: WeightMath.convertUnitToKg(weight, unit: unit))
                    showingAddExercise = false
                } onCancel: {
                    showingAddExercise = false
                }
            }
            .alert("Swap exercise", isPresented: Binding(
                get: { swapEntryIndex != nil },
                set: { if !$0 { swapEntryIndex = nil } }
            )) {
                TextField("Exercise name", text: $swapName)
                Button("Swap") {
                    if let index = swapEntryIndex { store.swapExercise(entryIndex: index, to: swapName) }
                    swapEntryIndex = nil
                }
                Button("Cancel", role: .cancel) { swapEntryIndex = nil }
            } message: {
                Text("Swapped exercises are logged but don't change the plan's progression.")
            }
            .alert("Empty workout", isPresented: $showingEmptyWorkoutName) {
                TextField("Name", text: $emptyWorkoutName)
                Button("Start") {
                    RestTimerNotifier.shared.requestAuthorizationIfNeeded()
                    store.startEmptyWorkout(name: emptyWorkoutName)
                    showingAddExercise = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Not part of your plan. Add exercises as you go.")
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
                        model.submitCurrentSet(store: store, mode: repsEntryMode, repsOverride: reps)
                    }
                )
                .presentationDetents([.height(230)])
            }
        }
    }

    private func syncHeartRateAndTicker() {
        if store.activeWorkout != nil {
            let workoutStore = store
            heartRate.start { [weak workoutStore] bpm, date in
                workoutStore?.appendHeartRate(bpm: bpm, at: date)
            }
            model.startTicking()
        } else {
            heartRate.stop()
            model.stopTicking()
        }
    }

    // MARK: Banners

    @ViewBuilder
    private var statusBanners: some View {
        if !store.isOnline {
            Label(
                store.activeWorkout != nil
                    ? "Offline — this workout is saved on your phone and uploads when you're back online."
                    : "Offline — using your plan as of \(cachedAgeText).",
                systemImage: "wifi.slash"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
        }

        if store.pendingUploadCount > 0 {
            HStack {
                Label(
                    store.outbox.contains(where: \.needsAttention)
                        ? "An upload needs attention (Settings → Uploads)"
                        : "\(store.pendingUploadCount) waiting to upload",
                    systemImage: "icloud.and.arrow.up"
                )
                .font(.footnote)
                Spacer()
                if store.isSyncing {
                    ProgressView()
                } else {
                    Button("Sync now") { Task { await store.syncNow() } }
                        .font(.footnote)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }

        if let upload = store.lastUpload {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(upload.wasQueued ? "Uploaded \(upload.workoutName)" : "\(upload.workoutName) saved")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Button {
                        store.lastUpload = nil
                    } label: {
                        Image(systemName: "xmark").font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(upload.personalRecords) { pr in
                    Text("🏆 New PR · \(pr.describe(unit: unit))")
                        .font(.footnote)
                }
                if upload.stravaStatus == .sent {
                    Text("Sent to Strava").font(.footnote).foregroundStyle(.secondary)
                } else if upload.stravaStatus == .failed {
                    Text("Strava upload failed — retry from History").font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(10)
            .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var cachedAgeText: String {
        guard let at = store.prescriptionFetchedAt else { return "the last sync" }
        return at.formatted(.relative(presentation: .named))
    }

    // MARK: Active workout

    @ViewBuilder
    private func activeWorkoutPanel(_ workout: LocalWorkout) -> some View {
        let pending = workout.pendingSetPosition()

        HStack {
            Text(workout.workoutName).font(.headline)
            Spacer()
            if workout.lastCompletedPosition() != nil {
                Button {
                    model.undoLastSet(store: store)
                } label: {
                    Label("Undo set", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
            }
        }

        if workout.entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add an exercise to get started.")
                    .foregroundStyle(.secondary)
                Button("Add exercise") { showingAddExercise = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if let pending {
            let entry = workout.entries[pending.entryIndex]
            let set = entry.sets[pending.setIndex]
            let targetReps = set.targetReps ?? entry.plannedReps
            let isBarbell = BarbellMath.usesBarbell(equipment: entry.equipmentType, tier: entry.tier)
            let displayWeight = Double(WeightMath.displayWeightFromKg(set.weightKg, unit: unit)) ?? 0

            VStack(alignment: .leading, spacing: 14) {
                timerPanel(restTarget: entry.restTargetSeconds)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.exerciseName)
                        .font(.title2)
                        .bold()
                    Text("Set \(set.setIndex) of \(entry.sets.count) · \(targetReps)\(set.isAmrap ? "+" : "") reps @ \(WeightMath.displayWeightFromKg(set.weightKg, unit: unit)) \(unit.label)")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("Change weight") {
                            weightEntry = WeightEntry(
                                entryIndex: pending.entryIndex,
                                exerciseName: entry.exerciseName,
                                value: WeightMath.displayWeightFromKg(set.weightKg, unit: unit)
                            )
                        }
                        .font(.footnote)
                        if isBarbell {
                            Text(BarbellMath.formatPlates(total: displayWeight, unit: unit))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if isBarbell, !entry.sets.contains(where: \.completed) {
                    warmupPanel(BarbellMath.warmupSets(working: displayWeight, unit: unit))
                }

                heartRatePanel

                outcomeSelector(targetReps: targetReps, isAmrap: set.isAmrap)
            }
            .padding(12)
            .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("All sets complete 🎉").font(.title3.bold())
                Text("Logged one wrong? Undo it before finishing. Need more? Add a set or exercise below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Finish workout") { model.finishWorkout(store: store) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            .padding(12)
            .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 14))
        }

        Divider()
        ForEach(Array(workout.entries.enumerated()), id: \.element.id) { index, entry in
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.exerciseName)
                        .bold()
                        .strikethrough(entry.isSkipped)
                    Text(entryStatusText(entry))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    if entry.isSkipped {
                        Button("Unskip") { store.unskipExercise(entryIndex: index) }
                    } else if !entry.isDone {
                        Button("Skip exercise") { store.skipExercise(entryIndex: index) }
                    }
                    Button("Swap exercise…") {
                        swapName = ""
                        swapEntryIndex = index
                    }
                    Button("Add a set") { store.addSet(entryIndex: index) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .accessibilityLabel("Options for \(entry.exerciseName)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }

        Button {
            showingAddExercise = true
        } label: {
            Label("Add exercise", systemImage: "plus")
        }

        HStack(spacing: 10) {
            if pending != nil {
                Button("Finish now") { model.finishWorkout(store: store) }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            Button("Discard", role: .destructive) { confirmingDiscard = true }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
    }

    private func entryStatusText(_ entry: LocalEntry) -> String {
        let done = entry.sets.filter(\.completed).count
        var text = "\(done)/\(entry.sets.count) sets · \(entry.plannedReps) @ \(WeightMath.displayWeightFromKg(entry.sets.first(where: \.isOpen)?.weightKg ?? entry.plannedWeightKg, unit: unit)) \(unit.label)"
        if entry.isSkipped { text += " · skipped" }
        if entry.isAdded { text += " · added" }
        return text
    }

    private func warmupPanel(_ sets: [WarmupSet]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WARM-UP")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(sets, id: \.self) { warmup in
                HStack {
                    Text("\(BarbellMath.format(warmup.weight)) \(unit.label) × \(warmup.reps)").bold()
                    Spacer()
                    Text(BarbellMath.formatPlates(total: warmup.weight, unit: unit))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Start panel

    private var startPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let rx = store.cachedPrescription {
                Text("Next workout: \(rx.workoutName)")
                    .font(.headline)
                Text("\(rx.planName) · week \(rx.week)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(rx.entries) { entry in
                    HStack {
                        Text(entry.exerciseName)
                        Spacer()
                        Text("\(entry.plannedSets)x\(entry.plannedReps) @ \(WeightMath.displayWeightFromKg(entry.plannedWeightKg, unit: unit))")
                            .foregroundStyle(.secondary)
                    }
                }

                if let reason = rx.blockedReason {
                    Text(reason).foregroundStyle(.orange)
                }
            } else if store.hasPendingWorkoutUploads {
                Text("Your next workout will appear once the last one has uploaded.")
                    .foregroundStyle(.secondary)
            } else if store.noActivePlan {
                Text("No active plan. Pick one in Settings → Plans, or build one on web.")
                    .foregroundStyle(.secondary)
            }

            Button("Start workout") {
                Task { await model.startWorkout(api: api, store: store) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.loading || store.cachedPrescription?.blockedReason != nil)

            Button("Start empty workout") {
                emptyWorkoutName = "Workout"
                showingEmptyWorkoutName = true
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Heart rate

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

    // MARK: Timer

    private func timerColor(restTarget: Int) -> Color {
        let elapsed = model.restSeconds(store: store)
        if elapsed > restTarget { return .red }
        if elapsed >= max(0, restTarget - 15) { return .orange }
        return .green
    }

    private func timerPanel(restTarget: Int) -> some View {
        let color = timerColor(restTarget: restTarget)
        return VStack(spacing: 6) {
            SegmentedDigitalClock(text: formatTimer(model.restSeconds(store: store)), color: color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(color.opacity(0.55), lineWidth: 2)
                )
            Text("Rest target \(formatTimer(restTarget))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func outcomeSelector(targetReps: Int, isAmrap: Bool) -> some View {
        HStack(spacing: 10) {
            Button("Complete") {
                if isAmrap {
                    repsEntryMode = .success
                    repsEntryTarget = targetReps
                    repsEntryIsAmrap = true
                    repsEntryValue = "\(targetReps)"
                    showingRepsEntry = true
                } else {
                    model.submitCurrentSet(store: store, mode: .success, repsOverride: nil)
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)

            Button("Fail") {
                repsEntryMode = .failed
                repsEntryTarget = targetReps
                repsEntryIsAmrap = isAmrap
                repsEntryValue = "\(max(0, targetReps - 1))"
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

private struct WeightEntrySheet: View {
    let title: String
    let unit: WeightUnit
    let onCancel: () -> Void
    let onSave: (Double) -> Void
    @State private var value: String

    init(title: String, unit: WeightUnit, initial: String, onCancel: @escaping () -> Void, onSave: @escaping (Double) -> Void) {
        self.title = title
        self.unit = unit
        self.onCancel = onCancel
        self.onSave = onSave
        _value = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Weight (\(unit.label))", text: $value)
                        .keyboardType(.decimalPad)
                } footer: {
                    Text("Applies to the remaining sets of \(title).")
                }
            }
            .navigationTitle("Weight (\(unit.label))")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let weight = Double(value.replacingOccurrences(of: ",", with: ".")), weight >= 0 { onSave(weight) }
                    }
                }
            }
        }
    }
}

private struct AddExerciseSheet: View {
    let unit: WeightUnit
    let suggestions: [String]
    let onAdd: (String, Int, Int, Double) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @State private var sets = 3
    @State private var reps = 10
    @State private var weight = "0"

    private var matches: [String] {
        let query = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return Array(suggestions.filter { $0.lowercased().contains(query) && $0.lowercased() != query }.prefix(5))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                    ForEach(matches, id: \.self) { match in
                        Button(match) { name = match }
                    }
                }
                Section {
                    Stepper("Sets: \(sets)", value: $sets, in: 1...20)
                    Stepper("Reps: \(reps)", value: $reps, in: 1...100)
                    TextField("Weight (\(unit.label))", text: $weight)
                        .keyboardType(.decimalPad)
                } footer: {
                    Text("Added exercises are logged but aren't part of the plan's progression.")
                }
            }
            .navigationTitle("Add exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let value = Double(weight.replacingOccurrences(of: ",", with: ".")) ?? 0
                        onAdd(name, sets, reps, max(0, value))
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
