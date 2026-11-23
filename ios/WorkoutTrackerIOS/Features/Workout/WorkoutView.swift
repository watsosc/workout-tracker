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
        guard let start = workout.restStart else { return 0 }
        return max(0, Int(now.timeIntervalSince(start)))
    }

    func startTicking() {
        guard tickTask == nil else { return }
        now = Date()
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
    @State private var optionsEntryIndex: Int?
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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    if model.loading {
                        ProgressView().tint(Neon.yellow)
                    }

                    statusBanners

                    if !model.errorMessage.isEmpty {
                        Text(model.errorMessage.uppercased())
                            .font(Neon.mono(13, relativeTo: .footnote))
                            .foregroundStyle(Neon.red)
                    }

                    if !model.infoMessage.isEmpty {
                        Text(model.infoMessage.uppercased())
                            .font(Neon.mono(13, relativeTo: .footnote))
                            .foregroundStyle(Neon.cyan)
                    }

                    if let workout = store.activeWorkout {
                        activeWorkoutPanel(workout)
                    } else {
                        startPanel
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .neonTabBarClearance()
            .background(NeonBackground())
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await model.load(api: api, store: store)
                syncHeartRateAndTicker()
            }
            .onChange(of: store.activeWorkout?.clientId) {
                syncHeartRateAndTicker()
            }
            .neonDialog(
                "Discard this workout?",
                isPresented: $confirmingDiscard,
                message: "Logged sets are thrown away and the plan does not advance.",
                buttons: [
                    NeonDialogButton(title: "Discard workout", kind: .danger) { model.discardWorkout(store: store) },
                    .cancel("Keep going")
                ]
            )
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
                .neonSheet()
            }
            .sheet(isPresented: $showingAddExercise) {
                AddExerciseSheet(unit: unit, suggestions: store.exerciseNames) { name, sets, reps, weight in
                    store.addExercise(name: name, sets: sets, reps: reps, weightKg: WeightMath.convertUnitToKg(weight, unit: unit))
                    showingAddExercise = false
                } onCancel: {
                    showingAddExercise = false
                }
                .neonSheet()
            }
            .neonDialog(
                item: $optionsEntryIndex,
                title: { index in store.activeWorkout?.entries[safe: index]?.exerciseName ?? "Exercise" },
                buttons: { index in exerciseOptions(index) }
            )
            .neonDialog(
                item: $swapEntryIndex,
                title: { _ in "Swap exercise" },
                message: { _ in "Swapped exercises are logged but don't change the plan's progression." },
                text: $swapName,
                placeholder: "Exercise name",
                buttons: { index in
                    [
                        NeonDialogButton(title: "Swap", kind: .primary) {
                            let name = swapName.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty { store.swapExercise(entryIndex: index, to: name) }
                        },
                        .cancel()
                    ]
                }
            )
            .neonDialog(
                "Empty workout",
                isPresented: $showingEmptyWorkoutName,
                message: "Not part of your plan. Add exercises as you go.",
                text: $emptyWorkoutName,
                placeholder: "Name",
                buttons: [
                    NeonDialogButton(title: "Start", kind: .primary) {
                        RestTimerNotifier.shared.requestAuthorizationIfNeeded()
                        store.startEmptyWorkout(name: emptyWorkoutName)
                        showingAddExercise = true
                    },
                    .cancel()
                ]
            )
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
                .neonSheet()
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if let workout = store.activeWorkout {
            VStack(alignment: .leading, spacing: 2) {
                Kicker(text: workout.planWorkoutId == nil ? "OFF-PLAN // FREESTYLE" : "\(workout.planName) // IN PROGRESS", color: Neon.pink)
                HStack(alignment: .center) {
                    Text(workout.workoutName.uppercased())
                        .font(Neon.head(30, .bold, relativeTo: .largeTitle))
                        .tracking(1.5)
                        .foregroundStyle(Neon.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer()
                    if workout.lastCompletedPosition() != nil {
                        Button {
                            model.undoLastSet(store: store)
                        } label: {
                            Text("↶ UNDO SET")
                                .font(Neon.mono(12, relativeTo: .caption))
                                .tracking(1)
                                .foregroundStyle(Neon.cyan)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Neon.cyan.opacity(0.06), in: CutCornerShape(cut: 8))
                                .overlay(CutCornerShape(cut: 8).strokeBorder(Neon.cyan.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 8)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Kicker(text: "NIGHT CITY BARBELL CLUB", color: Neon.pink)
                Text("WORKOUT")
                    .font(Neon.head(44, .bold, relativeTo: .largeTitle))
                    .tracking(2)
                    .foregroundStyle(Neon.yellow)
                    .glitch(2)
            }
            .padding(.top, 8)
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
            Text(
                store.activeWorkout != nil
                    ? "⚠ OFFLINE // SAVED ON THIS PHONE, UPLOADS WHEN BACK ONLINE"
                    : "⚠ OFFLINE // PLAN CACHED \(cachedAgeText.uppercased())"
            )
            .font(Neon.mono(12, relativeTo: .footnote))
            .tracking(0.8)
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Neon.yellow)
        }

        if store.pendingUploadCount > 0 {
            HStack {
                Text(
                    store.outbox.contains(where: \.needsAttention)
                        ? "⇡ UPLOAD NEEDS ATTENTION // SETTINGS"
                        : "⇡ \(store.pendingUploadCount) WAITING TO UPLOAD"
                )
                .font(Neon.mono(12, relativeTo: .footnote))
                .tracking(0.8)
                Spacer()
                if store.isSyncing {
                    ProgressView().tint(Neon.cyan)
                } else {
                    Button("Sync now") { Task { await store.syncNow() } }
                        .buttonStyle(NeonLinkStyle(color: Neon.cyan))
                }
            }
            .foregroundStyle(Neon.cyan)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Neon.cyan.opacity(0.05))
            .overlay(Rectangle().strokeBorder(Neon.cyan.opacity(0.45), lineWidth: 1))
        }

        if let upload = store.lastUpload {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Kicker(text: upload.wasQueued ? "// UPLOADED \(upload.workoutName)" : "// \(upload.workoutName) SAVED", color: Neon.pink)
                    Spacer()
                    Button {
                        store.lastUpload = nil
                    } label: {
                        Text("✕").font(Neon.mono(14)).foregroundStyle(Neon.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                if !upload.personalRecords.isEmpty {
                    Text("NEW PERSONAL RECORDS")
                        .font(Neon.head(18, .bold, relativeTo: .headline))
                        .tracking(1)
                        .foregroundStyle(Neon.white)
                }
                ForEach(upload.personalRecords) { pr in
                    HStack {
                        Text(pr.exerciseName.uppercased())
                            .font(Neon.head(15, .semibold))
                        Spacer()
                        Text(prValue(pr))
                            .font(Neon.mono(15))
                            .foregroundStyle(Neon.pink)
                    }
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) { Rectangle().fill(Neon.pink.opacity(0.2)).frame(height: 1) }
                }
                if upload.stravaStatus == .sent {
                    Text("↗ SENT TO STRAVA").font(Neon.mono(12)).foregroundStyle(Neon.cyan)
                } else if upload.stravaStatus == .failed {
                    Text("STRAVA UPLOAD FAILED // RETRY FROM HISTORY").font(Neon.mono(12)).foregroundStyle(Neon.red)
                }
            }
            .neonPanel(
                edge: Neon.pink,
                fill: Neon.panel
            )
            .background(
                LinearGradient(colors: [Neon.pink.opacity(0.18), .clear], startPoint: .topLeading, endPoint: .center)
                    .clipShape(CutCornerShape())
            )
        }
    }

    private func prValue(_ pr: PersonalRecord) -> String {
        let value = "\(WeightMath.displayWeightFromKg(pr.valueKg, unit: unit)) \(unit.label.uppercased())"
        return pr.kind == "WEIGHT" ? "\(value) × \(pr.reps)" : "EST. 1RM \(value)"
    }

    private var cachedAgeText: String {
        guard let at = store.prescriptionFetchedAt else { return "at the last sync" }
        return at.formatted(.relative(presentation: .named))
    }

    // MARK: Active workout

    @ViewBuilder
    private func activeWorkoutPanel(_ workout: LocalWorkout) -> some View {
        let pending = workout.pendingSetPosition()

        if workout.entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Kicker(text: "// EMPTY WORKOUT", color: Neon.cyan)
                Text("ADD AN EXERCISE TO GET STARTED")
                    .font(Neon.head(20, .bold, relativeTo: .title3))
                    .foregroundStyle(Neon.white)
                Button("+ Add exercise") { showingAddExercise = true }
                    .buttonStyle(NeonButtonStyle(kind: .primary))
            }
            .neonPanel(edge: Neon.heroEdge)
        } else if let pending {
            let entry = workout.entries[pending.entryIndex]
            let set = entry.sets[pending.setIndex]
            let targetReps = set.targetReps ?? entry.plannedReps
            let isBarbell = BarbellMath.usesBarbell(equipment: entry.equipmentType, tier: entry.tier)
            let displayWeight = Double(WeightMath.displayWeightFromKg(set.weightKg, unit: unit)) ?? 0

            VStack(alignment: .leading, spacing: 14) {
                timerPanel(restTarget: entry.restTargetSeconds)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if let tier = entry.tier { NeonTag(text: tier, style: tier == "T1" ? .yellow : tier == "T3" ? .pink : .plain) }
                        NeonTag(text: String(format: "SET %02d/%02d", set.setIndex, entry.sets.count))
                        if set.isAmrap { NeonTag(text: "AMRAP", style: .pink) }
                        if entry.isAdded { NeonTag(text: "ADDED", style: .cyan) }
                    }
                    Text(entry.exerciseName.uppercased())
                        .font(Neon.head(30, .bold, relativeTo: .title))
                        .tracking(1.2)
                        .foregroundStyle(Neon.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .glitch(1)
                    setLine(reps: targetReps, isAmrap: set.isAmrap, weightKg: set.weightKg)
                    HStack(spacing: 14) {
                        Button("Change weight") {
                            weightEntry = WeightEntry(
                                entryIndex: pending.entryIndex,
                                exerciseName: entry.exerciseName,
                                value: WeightMath.displayWeightFromKg(set.weightKg, unit: unit)
                            )
                        }
                        .buttonStyle(NeonLinkStyle())
                        if isBarbell {
                            Text(BarbellMath.formatPlates(total: displayWeight, unit: unit).uppercased())
                                .font(Neon.mono(12, relativeTo: .footnote))
                                .foregroundStyle(Neon.cyan)
                        }
                    }
                }

                if isBarbell, !entry.sets.contains(where: \.completed) {
                    warmupPanel(BarbellMath.warmupSets(working: displayWeight, unit: unit))
                }

                heartRatePanel

                outcomeSelector(targetReps: targetReps, isAmrap: set.isAmrap)
            }
            .neonPanel(edge: Neon.heroEdge)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Kicker(text: "ALL SETS LOGGED // \(workout.completedSetCount)/\(workout.totalSetCount)", color: Neon.cyan)
                Text("FLATLINED IT")
                    .font(Neon.head(36, .bold, relativeTo: .largeTitle))
                    .tracking(1.5)
                    .foregroundStyle(Neon.yellow)
                    .glitch(2)
                Text("Logged one wrong? Undo it before finishing. Need more? Add a set or exercise below.")
                    .font(Neon.mono(13, relativeTo: .footnote))
                    .foregroundStyle(Neon.muted)
                Button("Finish workout") { model.finishWorkout(store: store) }
                    .buttonStyle(NeonButtonStyle(kind: .hazard))
                    .padding(.top, 6)
            }
            .neonPanel(edge: Neon.yellow)
        }

        Kicker(text: "// QUEUE").padding(.top, 6)

        VStack(spacing: 6) {
            ForEach(Array(workout.entries.enumerated()), id: \.element.id) { index, entry in
                queueRow(entry, index: index)
            }
        }

        Button {
            showingAddExercise = true
        } label: {
            Text("+ ADD EXERCISE")
                .font(Neon.mono(14, relativeTo: .callout))
                .tracking(1.5)
                .foregroundStyle(Neon.yellow)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .overlay(Rectangle().strokeBorder(Neon.yellow.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .buttonStyle(.plain)

        HStack(spacing: 10) {
            if pending != nil {
                Button("Finish now") { model.finishWorkout(store: store) }
                    .buttonStyle(NeonButtonStyle(kind: .ghost, height: 46, fontSize: 14))
            }
            Button("Discard") { confirmingDiscard = true }
                .buttonStyle(NeonButtonStyle(kind: .danger, height: 46, fontSize: 14))
        }
        .padding(.top, 4)
    }

    private func setLine(reps: Int, isAmrap: Bool, weightKg: Double) -> some View {
        let repsText = Text(verbatim: "\(reps)\(isAmrap ? "+" : "")").foregroundStyle(Neon.white).font(Neon.mono(20, relativeTo: .title3))
        let at = Text(verbatim: "@").foregroundStyle(Neon.pink)
        let weight = Text(verbatim: WeightMath.displayWeightFromKg(weightKg, unit: unit)).foregroundStyle(Neon.white).font(Neon.mono(20, relativeTo: .title3))
        return Text("\(repsText) REPS \(at) \(weight) \(unit.label.uppercased())")
            .font(Neon.mono(17, relativeTo: .body))
            .foregroundStyle(Neon.muted)
    }

    private func queueRow(_ entry: LocalEntry, index: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.exerciseName.uppercased())
                    .font(Neon.head(15, .bold, relativeTo: .body))
                    .tracking(0.8)
                    .foregroundStyle(Neon.white)
                    .strikethrough(entry.isSkipped)
                Text(entryStatusText(entry))
                    .font(Neon.mono(12, relativeTo: .caption))
                    .foregroundStyle(Neon.muted)
            }
            Spacer()
            Button {
                optionsEntryIndex = index
            } label: {
                Text("•••")
                    .font(Neon.mono(16))
                    .foregroundStyle(Neon.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Options for \(entry.exerciseName)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(Neon.panel)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(entry.isDone ? Neon.yellow : entry.sets.contains(where: \.completed) ? Neon.cyan : Neon.line)
                .frame(width: 3)
        }
        .opacity(entry.isSkipped ? 0.5 : 1)
    }

    private func exerciseOptions(_ index: Int) -> [NeonDialogButton] {
        guard let entry = store.activeWorkout?.entries[safe: index] else { return [.cancel()] }
        var buttons: [NeonDialogButton] = []
        if entry.isSkipped {
            buttons.append(NeonDialogButton(title: "Unskip") { store.unskipExercise(entryIndex: index) })
        } else if !entry.isDone {
            buttons.append(NeonDialogButton(title: "Skip exercise", kind: .danger) { store.skipExercise(entryIndex: index) })
        }
        buttons.append(NeonDialogButton(title: "Swap exercise…") {
            swapName = ""
            swapEntryIndex = index
        })
        buttons.append(NeonDialogButton(title: "Add a set") { store.addSet(entryIndex: index) })
        buttons.append(.cancel())
        return buttons
    }

    private func entryStatusText(_ entry: LocalEntry) -> String {
        let done = entry.sets.filter(\.completed).count
        let weight = WeightMath.displayWeightFromKg(entry.sets.first(where: \.isOpen)?.weightKg ?? entry.plannedWeightKg, unit: unit)
        var text = "\(done)/\(entry.sets.count) · \(entry.plannedReps) @ \(weight) \(unit.label.uppercased())"
        if entry.isSkipped { text += " · SKIPPED" }
        if entry.isAdded { text += " · ADDED" }
        return text
    }

    private func warmupPanel(_ sets: [WarmupSet]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker(text: "// WARM-UP")
            ForEach(sets, id: \.self) { warmup in
                HStack {
                    Text("\(BarbellMath.format(warmup.weight)) \(unit.label.uppercased()) × \(warmup.reps)")
                        .foregroundStyle(Neon.white)
                    Spacer()
                    Text(BarbellMath.formatPlates(total: warmup.weight, unit: unit).uppercased())
                        .foregroundStyle(Neon.cyan)
                }
                .font(Neon.mono(14, relativeTo: .callout))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Neon.ink2)
        .overlay(Rectangle().strokeBorder(Neon.cyan.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    // MARK: Start panel

    private var startPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let rx = store.cachedPrescription {
                VStack(alignment: .leading, spacing: 10) {
                    Kicker(text: "NEXT UP // WEEK \(rx.week)", color: Neon.cyan)
                    Text(rx.workoutName.uppercased())
                        .font(Neon.head(44, .bold, relativeTo: .largeTitle))
                        .tracking(1.5)
                        .foregroundStyle(Neon.yellow)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(rx.planName.uppercased())
                        .font(Neon.mono(12, relativeTo: .caption))
                        .foregroundStyle(Neon.muted)

                    VStack(spacing: 0) {
                        ForEach(rx.entries) { entry in
                            HStack(spacing: 10) {
                                Text(entry.exerciseName.uppercased())
                                    .font(Neon.head(15, .semibold, relativeTo: .body))
                                    .foregroundStyle(Neon.white)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(Text(verbatim: "\(entry.plannedSets)×\(entry.plannedReps)").foregroundStyle(Neon.white)) @ \(WeightMath.displayWeightFromKg(entry.plannedWeightKg, unit: unit))")
                                    .font(Neon.mono(13, relativeTo: .footnote))
                                    .foregroundStyle(Neon.muted)
                                if let tier = entry.tier {
                                    NeonTag(text: tier, style: tier == "T1" ? .yellow : tier == "T3" ? .pink : .plain)
                                }
                            }
                            .padding(.vertical, 9)
                            .overlay(alignment: .bottom) { Rectangle().fill(Neon.line).frame(height: 1) }
                        }
                    }

                    if let reason = rx.blockedReason {
                        Text(reason.uppercased())
                            .font(Neon.mono(12, relativeTo: .footnote))
                            .foregroundStyle(Neon.pink)
                    }
                }
                .neonPanel(edge: Neon.coolEdge)
            } else if store.hasPendingWorkoutUploads {
                Text("YOUR NEXT WORKOUT APPEARS ONCE THE LAST ONE HAS UPLOADED.")
                    .font(Neon.mono(13, relativeTo: .footnote))
                    .foregroundStyle(Neon.muted)
                    .neonPanel()
            } else if store.noActivePlan {
                Text("NO ACTIVE PLAN // PICK ONE IN SETTINGS → PLANS, OR BUILD ONE ON WEB.")
                    .font(Neon.mono(13, relativeTo: .footnote))
                    .foregroundStyle(Neon.muted)
                    .neonPanel()
            }

            Button("▶ Jack in") {
                Task { await model.startWorkout(api: api, store: store) }
            }
            .buttonStyle(NeonButtonStyle(kind: .primary, height: 64, fontSize: 22))
            .disabled(model.loading || store.cachedPrescription?.blockedReason != nil)
            .accessibilityLabel("Start workout")

            Button("Start empty workout") {
                emptyWorkoutName = "Workout"
                showingEmptyWorkoutName = true
            }
            .buttonStyle(NeonButtonStyle(kind: .ghost, height: 46, fontSize: 14))
        }
    }

    // MARK: Heart rate

    private var heartRatePanel: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if recentHeartRateSamples.count >= 2 {
                    Chart(recentHeartRateSamples) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("BPM", sample.bpm)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Neon.pink)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: 70...145)
                    .shadow(color: Neon.pink.opacity(0.8), radius: 4)
                } else {
                    VStack(spacing: 4) {
                        Text(heartRate.statusText.uppercased())
                            .font(Neon.mono(11, relativeTo: .caption))
                            .foregroundStyle(Neon.muted)
                            .multilineTextAlignment(.center)
                        if heartRate.isHeartRateDeviceConnected {
                            Text("START AN ACTIVITY WITH HR BROADCAST ON THE WATCH")
                                .font(Neon.mono(10, relativeTo: .caption2))
                                .tracking(1)
                                .foregroundStyle(Neon.cyan)
                                .multilineTextAlignment(.center)
                        } else {
                            Text("TAP TO RETRY")
                                .font(Neon.mono(10, relativeTo: .caption2))
                                .tracking(1.2)
                                .foregroundStyle(Neon.cyan)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 76)

            VStack(alignment: .trailing, spacing: 2) {
                Kicker(text: "BPM")
                Text(heartRate.latestBpm.map { "\($0)" } ?? "—")
                    .font(Neon.head(38, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(heartRate.latestBpm == nil ? Neon.muted : Neon.pink)
                    .neonGlow(heartRate.latestBpm == nil ? .clear : Neon.pink, radius: 8)
                // Lives inside the panel (not floating over the page) so it can't cover other controls.
                heartRateConnectionDot
                    .padding(.top, 4)
            }
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black)
        .overlay(alignment: .leading) { Rectangle().fill(Neon.pink).frame(width: 3) }
        .contentShape(Rectangle())
        .onTapGesture {
            // Only when nothing is connected: a connected sensor that's quiet just needs broadcasting on.
            if !heartRate.isHeartRateDeviceConnected { heartRate.reconnect() }
        }
        .accessibilityHint(heartRate.isHeartRateDeviceConnected ? "" : "Retries connecting to the heart-rate monitor")
    }

    private var recentHeartRateSamples: [LiveHeartRateSample] {
        guard let latest = heartRate.samples.last?.timestamp else { return [] }
        let cutoff = latest.addingTimeInterval(-10)
        return heartRate.samples.filter { $0.timestamp >= cutoff }
    }

    // MARK: Timer (the clock itself is intentionally unthemed: retro system green / orange / red)

    private func timerColor(restTarget: Int) -> Color {
        let elapsed = model.restSeconds(store: store)
        if elapsed > restTarget { return .red }
        if elapsed >= max(0, restTarget - 15) { return .orange }
        return .green
    }

    private func timerPanel(restTarget: Int) -> some View {
        // Idle (dimmed, 00:00) until the first set is logged: there's no rest to time before that.
        let idle = store.activeWorkout?.restStart == nil
        let color = idle ? Color.green.opacity(0.35) : timerColor(restTarget: restTarget)
        return VStack(spacing: 6) {
            VHSGlitch(active: !idle) {
                SegmentedDigitalClock(text: formatTimer(model.restSeconds(store: store)), color: color)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.black)
            .overlay(VHSScanlines(tint: color))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(color.opacity(0.55), lineWidth: 2)
            )
            Group {
                if idle {
                    Text("REST CLOCK STARTS WHEN YOU COMPLETE A SET")
                } else {
                    Text("REST TARGET \(Text(verbatim: formatTimer(restTarget)).foregroundStyle(Neon.white))")
                }
            }
            .font(Neon.mono(12, relativeTo: .caption))
            .tracking(1.6)
            .foregroundStyle(Neon.muted)
        }
    }

    private func outcomeSelector(targetReps: Int, isAmrap: Bool) -> some View {
        HStack(spacing: 10) {
            Button("✓ Complete") {
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
            .buttonStyle(NeonButtonStyle(kind: .primary))

            Button("✕ Fail") {
                repsEntryMode = .failed
                repsEntryTarget = targetReps
                repsEntryIsAmrap = isAmrap
                repsEntryValue = "\(max(0, targetReps - 1))"
                showingRepsEntry = true
            }
            .buttonStyle(NeonButtonStyle(kind: .danger))
        }
    }

    /// Blue when a heart-rate device is connected, red when not.
    private var heartRateConnectionDot: some View {
        let connected = heartRate.isHeartRateDeviceConnected
        let color = connected ? Neon.blue : Neon.red
        return Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .shadow(color: color, radius: 6)
            .accessibilityElement()
            .accessibilityLabel(connected ? "Heart-rate monitor connected" : "No heart-rate monitor connected")
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

// MARK: VHS effect on the rest clock

/// Static scanlines plus a faint tracking band that slowly rolls down the screen.
private struct VHSScanlines: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Canvas { context, size in
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1.2)), with: .color(.black.opacity(0.45)))
                    y += 3
                }
            }

            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                    GeometryReader { geo in
                        let period = 5.5
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                        let bandHeight: CGFloat = 26
                        LinearGradient(
                            colors: [.clear, tint.opacity(0.10), .white.opacity(0.07), tint.opacity(0.10), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: bandHeight)
                        .offset(y: -bandHeight + (geo.size.height + bandHeight) * phase)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GlitchSlice {
    var y: CGFloat      // 0...1 of height
    var height: CGFloat // 0...1 of height
    var dx: CGFloat
}

private struct GlitchFrame {
    var split: CGFloat = 0
    var jitter: CGFloat = 0
    var slices: [GlitchSlice] = []
    static let none = GlitchFrame()
}

/// Wraps content and, at random intervals, hits it with a short glitch burst: RGB split,
/// horizontal tearing slices and jitter.
private struct VHSGlitch<Content: View>: View {
    var active = true
    @ViewBuilder let content: Content

    @State private var frame = GlitchFrame.none
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if frame.split != 0 {
                content
                    .colorMultiply(Neon.pink)
                    .offset(x: -frame.split)
                    .opacity(0.75)
                    .blendMode(.screen)
                content
                    .colorMultiply(Neon.cyan)
                    .offset(x: frame.split)
                    .opacity(0.75)
                    .blendMode(.screen)
            }

            content
                .offset(x: frame.jitter)
                .mask {
                    // Cut the torn slices out of the base copy...
                    GeometryReader { geo in
                        ZStack {
                            Rectangle()
                            ForEach(Array(frame.slices.enumerated()), id: \.offset) { _, slice in
                                Rectangle()
                                    .frame(height: geo.size.height * slice.height)
                                    .position(x: geo.size.width / 2, y: geo.size.height * (slice.y + slice.height / 2))
                                    .blendMode(.destinationOut)
                            }
                        }
                        .compositingGroup()
                    }
                }

            // ...and draw them shifted sideways.
            ForEach(Array(frame.slices.enumerated()), id: \.offset) { _, slice in
                content
                    .offset(x: frame.jitter + slice.dx)
                    .mask {
                        GeometryReader { geo in
                            Rectangle()
                                .frame(height: geo.size.height * slice.height)
                                .position(x: geo.size.width / 2, y: geo.size.height * (slice.y + slice.height / 2))
                        }
                    }
            }
        }
        .task(id: active && !reduceMotion) {
            guard active, !reduceMotion else {
                frame = .none
                return
            }
            await runGlitches()
        }
    }

    private func runGlitches() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.5...8)))
            guard !Task.isCancelled else { break }
            // A burst is a few quick random frames.
            for _ in 0..<Int.random(in: 2...5) {
                frame = Self.randomFrame()
                try? await Task.sleep(for: .milliseconds(Int.random(in: 35...90)))
            }
            frame = .none
        }
        frame = .none
    }

    private static func randomFrame() -> GlitchFrame {
        var frame = GlitchFrame()
        frame.split = CGFloat.random(in: 2...6) * (Bool.random() ? 1 : -1)
        frame.jitter = CGFloat.random(in: -3...3)
        frame.slices = (0..<Int.random(in: 1...3)).map { _ in
            GlitchSlice(
                y: CGFloat.random(in: 0...0.85),
                height: CGFloat.random(in: 0.04...0.16),
                dx: CGFloat.random(in: 6...18) * (Bool.random() ? 1 : -1)
            )
        }
        return frame
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
                    TextField("Reps", text: $value)
                        .keyboardType(.numberPad)
                        .font(Neon.head(40, .bold, relativeTo: .largeTitle))
                        .foregroundStyle(mode == .failed ? Neon.pink : Neon.yellow)
                } header: {
                    NeonSectionHeader(text: mode == .failed ? "Reps completed" : "Total reps")
                } footer: {
                    NeonFootnote(text: mode == .failed ? "TARGET WAS \(target). A FAILED SET IS FEWER." : "AT LEAST \(target)\(isAmrap ? " (AMRAP)" : "").")
                }
                .neonRows()
            }
            .neonForm()
            .navigationTitle(mode == .failed ? "FAILED SET" : "REPS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NeonToolbarButton(title: "Cancel", color: Neon.muted, action: onCancel)
                }
                .neonToolbarItem()
                ToolbarItem(placement: .confirmationAction) {
                    NeonToolbarButton(title: "Save", action: onSubmit)
                }
                .neonToolbarItem()
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
                    HStack(alignment: .firstTextBaseline) {
                        TextField("Weight", text: $value)
                            .keyboardType(.decimalPad)
                            .font(Neon.head(40, .bold, relativeTo: .largeTitle))
                            .foregroundStyle(Neon.yellow)
                        Text(unit.label.uppercased())
                            .font(Neon.mono(18))
                            .foregroundStyle(Neon.muted)
                    }
                } header: {
                    NeonSectionHeader(text: title)
                } footer: {
                    NeonFootnote(text: "APPLIES TO THE REMAINING SETS.")
                }
                .neonRows()
            }
            .neonForm()
            .navigationTitle("CHANGE WEIGHT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NeonToolbarButton(title: "Cancel", color: Neon.muted, action: onCancel)
                }
                .neonToolbarItem()
                ToolbarItem(placement: .confirmationAction) {
                    NeonToolbarButton(title: "Save") {
                        if let weight = Double(value.replacingOccurrences(of: ",", with: ".")), weight >= 0 { onSave(weight) }
                    }
                }
                .neonToolbarItem()
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
                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .font(Neon.head(20, .bold))
                    ForEach(matches, id: \.self) { match in
                        Button(match.uppercased()) { name = match }
                            .font(Neon.mono(14))
                            .foregroundStyle(Neon.cyan)
                    }
                } header: {
                    NeonSectionHeader(text: "Exercise")
                }
                .neonRows()

                Section {
                    Stepper(value: $sets, in: 1...20) {
                        Text("SETS  \(Text(verbatim: "\(sets)").foregroundStyle(Neon.yellow))").font(Neon.mono(16))
                    }
                    Stepper(value: $reps, in: 1...100) {
                        Text("REPS  \(Text(verbatim: "\(reps)").foregroundStyle(Neon.yellow))").font(Neon.mono(16))
                    }
                    HStack {
                        Text("WEIGHT").font(Neon.mono(16))
                        Spacer()
                        TextField("0", text: $weight)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(Neon.mono(18))
                            .foregroundStyle(Neon.yellow)
                            .frame(width: 90)
                        Text(unit.label.uppercased()).font(Neon.mono(14)).foregroundStyle(Neon.muted)
                    }
                } header: {
                    NeonSectionHeader(text: "Prescription")
                } footer: {
                    NeonFootnote(text: "ADDED EXERCISES ARE LOGGED BUT AREN'T PART OF THE PLAN'S PROGRESSION.")
                }
                .neonRows()
            }
            .neonForm()
            .navigationTitle("ADD EXERCISE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NeonToolbarButton(title: "Cancel", color: Neon.muted, action: onCancel)
                }
                .neonToolbarItem()
                ToolbarItem(placement: .confirmationAction) {
                    NeonToolbarButton(title: "Add") {
                        let value = Double(weight.replacingOccurrences(of: ",", with: ".")) ?? 0
                        onAdd(name, sets, reps, max(0, value))
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .neonToolbarItem()
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
