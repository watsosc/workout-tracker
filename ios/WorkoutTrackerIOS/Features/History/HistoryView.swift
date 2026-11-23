import SwiftUI
import Charts

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var loading = false
    @Published var errorMessage = ""
    @Published var infoMessage = ""
    @Published var history: [WorkoutHistoryItem] = []
    @Published var heartRateBySession: [Int: [HeartRateSample]] = [:]
    @Published var stravaConnection: StravaConnection?

    func load(using api: WorkoutAPI) async {
        loading = true
        errorMessage = ""
        infoMessage = ""

        do {
            async let items = api.fetchWorkoutHistory(limit: 120)
            async let strava = api.fetchStravaConnection()
            history = try await items
            stravaConnection = try await strava
            heartRateBySession = [:]

            for item in history where item.heartRateSampleCount > 0 {
                heartRateBySession[item.sessionId] = try? await api.fetchSessionHeartRateSamples(sessionId: item.sessionId, limit: 360)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        loading = false
    }

    func delete(item: WorkoutHistoryItem, api: WorkoutAPI) async {
        errorMessage = ""
        do {
            infoMessage = try await api.deleteWorkout(sessionId: item.sessionId).message
            await load(using: api)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendToStrava(item: WorkoutHistoryItem, api: WorkoutAPI) async {
        loading = true
        errorMessage = ""
        infoMessage = ""
        do {
            let result = try await api.sendWorkoutToStrava(sessionId: item.sessionId)
            if result.ok {
                infoMessage = result.activityUrl.map { "Sent to Strava: \($0)" } ?? result.message
                await load(using: api)
            } else {
                errorMessage = result.message
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}

struct HistoryView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: OfflineWorkoutStore
    @StateObject private var model = HistoryViewModel()
    @State private var editingSessionId: Int?
    @State private var deleting: WorkoutHistoryItem?

    private var api: WorkoutAPI { settings.api }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Kicker(text: "LOG // \(model.history.count) SESSIONS", color: Neon.pink)
                        Text("HISTORY")
                            .font(Neon.head(44, .bold, relativeTo: .largeTitle))
                            .tracking(2)
                            .foregroundStyle(Neon.yellow)
                    }
                    .padding(.top, 8)

                    if model.loading { ProgressView().tint(Neon.yellow) }

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

                    let pendingWorkouts = store.outbox.filter {
                        if case .logWorkout = $0.kind { return true } else { return false }
                    }
                    if !pendingWorkouts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Kicker(text: "// WAITING TO UPLOAD", color: Neon.cyan)
                            ForEach(pendingWorkouts) { item in
                                Text("⇡ \(item.title.uppercased())")
                                    .font(Neon.mono(13, relativeTo: .footnote))
                                    .foregroundStyle(Neon.cyan)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Neon.cyan.opacity(0.05))
                        .overlay(Rectangle().strokeBorder(Neon.cyan.opacity(0.45), lineWidth: 1))
                    }

                    if !model.loading && model.history.isEmpty {
                        Text("NO COMPLETED WORKOUTS YET.")
                            .font(Neon.mono(13, relativeTo: .footnote))
                            .foregroundStyle(Neon.muted)
                            .neonPanel()
                    }

                    ForEach(model.history) { item in
                        historyCard(item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .neonTabBarClearance()
            .background(NeonBackground())
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.load(using: api) }
            .refreshable { await model.load(using: api) }
            .sheet(item: Binding(
                get: { editingSessionId.map(EditTarget.init) },
                set: { editingSessionId = $0?.id }
            )) { target in
                EditWorkoutSheet(sessionId: target.id, unit: settings.weightUnit, api: api) { message in
                    editingSessionId = nil
                    model.infoMessage = message
                    Task { await model.load(using: api) }
                }
                .neonSheet()
            }
            .neonDialog(
                item: $deleting,
                title: { _ in "Delete this workout?" },
                message: { _ in "If it's your most recent workout, its progression is undone too. This can't be undone." },
                buttons: { item in
                    [
                        NeonDialogButton(title: "Delete \(item.planWorkoutName)", kind: .danger) {
                            Task { await model.delete(item: item, api: api) }
                        },
                        .cancel()
                    ]
                }
            )
            .onChange(of: store.outbox.count) {
                Task { await model.load(using: api) }
            }
        }
    }

    private var unit: WeightUnit { settings.weightUnit }

    private func historyCard(_ item: WorkoutHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.planWorkoutName.uppercased())
                        .font(Neon.head(22, .bold, relativeTo: .title2))
                        .tracking(1.2)
                        .foregroundStyle(Neon.white)
                    Text(subtitle(item))
                        .font(Neon.mono(11, relativeTo: .caption))
                        .tracking(1)
                        .foregroundStyle(Neon.muted)
                }
                Spacer()
                if !item.personalRecords.isEmpty {
                    NeonTag(text: "🏆 \(Set(item.personalRecords.map(\.exerciseName)).count) PR", style: .pink)
                }
            }

            if item.heartRateSampleCount > 1,
               let samples = model.heartRateBySession[item.sessionId], !samples.isEmpty {
                Chart(samples) { sample in
                    LineMark(
                        x: .value("Time", sample.recordedAt),
                        y: .value("BPM", sample.bpm)
                    )
                    .foregroundStyle(Neon.pink)
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 56)
                .padding(.vertical, 4)
                .background(Color.black)
            }

            VStack(spacing: 0) {
                ForEach(item.exercises) { exercise in
                    let isPR = item.personalRecords.contains { $0.exerciseName == exercise.exerciseName }
                    HStack {
                        Text(exercise.exerciseName.uppercased())
                            .font(Neon.head(14, .semibold, relativeTo: .body))
                            .foregroundStyle(Neon.white)
                        if isPR { Text("🏆").font(.caption) }
                        Spacer()
                        Text("\(exercise.completedSets) × \(exercise.totalReps) · \(WeightMath.displayWeightFromKg(exercise.topWeightKg, unit: unit))")
                            .font(Neon.mono(13, relativeTo: .footnote))
                            .foregroundStyle(isPR ? Neon.pink : Neon.muted)
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { Rectangle().fill(Neon.line).frame(height: 1) }
                }
            }

            ForEach(item.personalRecords) { pr in
                Text("🏆 \(pr.describe(unit: unit).uppercased())")
                    .font(Neon.mono(12, relativeTo: .caption))
                    .foregroundStyle(Neon.pink)
            }

            HStack(spacing: 18) {
                Button("Edit") { editingSessionId = item.sessionId }
                    .buttonStyle(NeonLinkStyle())
                if item.stravaExportStatus == .sent, let url = item.stravaActivityUrl, let link = URL(string: url) {
                    Link("↗ Strava", destination: link)
                        .font(Neon.mono(13, relativeTo: .footnote))
                        .tracking(1.2)
                        .underline()
                        .foregroundStyle(Neon.cyan)
                } else if model.stravaConnection?.connected == true {
                    Button(item.stravaExportStatus == .failed ? "Retry Strava" : "↗ Send to Strava") {
                        Task { await model.sendToStrava(item: item, api: api) }
                    }
                    .buttonStyle(NeonLinkStyle(color: Neon.cyan))
                }
                Spacer()
                Button("Delete") { deleting = item }
                    .buttonStyle(NeonLinkStyle(color: Neon.red))
            }
            .padding(.top, 2)
        }
        .neonPanel(edge: item.personalRecords.isEmpty ? AnyShapeStyle(Neon.line) : AnyShapeStyle(Neon.coolEdge))
        .opacity(item.planRunId == nil ? 0.85 : 1)
    }

    private func subtitle(_ item: WorkoutHistoryItem) -> String {
        var parts: [String] = []
        if let date = ISO8601.parse(item.finishedAt) {
            parts.append(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased())
        }
        if let seconds = item.totalDurationSeconds { parts.append("\(seconds / 60) MIN") }
        parts.append("\(item.completedSets)/\(item.totalSets) SETS")
        if item.planRunId == nil { parts.append("OFF-PLAN") }
        return parts.joined(separator: " · ")
    }
}

private struct EditTarget: Identifiable {
    let id: Int
}

/// Correct reps/weights of a finished workout. The latest workout's progression is recalculated.
private struct EditWorkoutSheet: View {
    struct Row: Identifiable {
        let id: Int
        let exerciseName: String
        let setIndex: Int
        var completed: Bool
        var reps: String
        var weight: String
        let originalWeight: String
        let originalWeightKg: Double?
    }

    let sessionId: Int
    let unit: WeightUnit
    let api: WorkoutAPI
    let onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var loading = true
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                if loading { ProgressView().tint(Neon.yellow).neonRows() }
                if !errorMessage.isEmpty {
                    Text(errorMessage.uppercased()).font(Neon.mono(13)).foregroundStyle(Neon.red).neonRows()
                }
                ForEach(groupedNames, id: \.self) { name in
                    Section {
                        ForEach($rows.filter { $0.wrappedValue.exerciseName == name }) { $row in
                            HStack {
                                Toggle("Set \(row.setIndex)", isOn: $row.completed)
                                    .fixedSize()
                                TextField("Reps", text: $row.reps)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .disabled(!row.completed)
                                    .frame(width: 50)
                                Text("×")
                                TextField(unit.label, text: $row.weight)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 70)
                                Text(unit.label.uppercased()).font(Neon.mono(13)).foregroundStyle(Neon.muted)
                            }
                            .font(Neon.mono(16))
                        }
                    } header: {
                        NeonSectionHeader(text: name)
                    }
                    .neonRows()
                }
            }
            .neonForm()
            .navigationTitle("EDIT WORKOUT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NeonToolbarButton(title: "Cancel", color: Neon.muted) { dismiss() }
                }
                .neonToolbarItem()
                ToolbarItem(placement: .confirmationAction) {
                    NeonToolbarButton(title: "Save") { Task { await save() } }.disabled(loading)
                }
                .neonToolbarItem()
            }
            .task { await load() }
        }
    }

    private var groupedNames: [String] {
        var seen: [String] = []
        for row in rows where !seen.contains(row.exerciseName) { seen.append(row.exerciseName) }
        return seen
    }

    private func load() async {
        loading = true
        do {
            guard let session = try await api.fetchWorkoutSession(id: sessionId) else { throw URLError(.fileDoesNotExist) }
            rows = session.entries.flatMap { entry in
                entry.sets.map { set in
                    let weight = WeightMath.displayWeightFromKg(set.weightKg ?? entry.plannedWeightKg, unit: unit)
                    return Row(
                        id: set.id,
                        exerciseName: entry.exerciseName,
                        setIndex: set.setIndex,
                        completed: set.completed,
                        reps: set.repsCompleted.map(String.init) ?? "",
                        weight: weight,
                        originalWeight: weight,
                        originalWeightKg: set.weightKg
                    )
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func save() async {
        var sets: [[String: Any]] = []
        for row in rows {
            var edit: [String: Any] = ["sessionSetId": row.id, "completed": row.completed]
            if row.completed {
                guard let reps = Int(row.reps), reps >= 0 else {
                    errorMessage = "\(row.exerciseName) set \(row.setIndex): enter reps or switch it off"
                    return
                }
                edit["repsCompleted"] = reps
            }
            if row.weight != row.originalWeight {
                guard let weight = Double(row.weight.replacingOccurrences(of: ",", with: ".")), weight >= 0 else {
                    errorMessage = "\(row.exerciseName) set \(row.setIndex): weight must be 0 or more"
                    return
                }
                edit["weightKg"] = WeightMath.convertUnitToKg(weight, unit: unit)
            } else if let kg = row.originalWeightKg {
                edit["weightKg"] = kg
            }
            sets.append(edit)
        }
        loading = true
        do {
            let result = try await api.updateWorkout(sessionId: sessionId, sets: sets)
            onSaved(result.message)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}
