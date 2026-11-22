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
            List {
                if model.loading { ProgressView() }

                if !model.errorMessage.isEmpty {
                    Text(model.errorMessage).foregroundStyle(.red)
                }
                if !model.infoMessage.isEmpty {
                    Text(model.infoMessage).foregroundStyle(.green)
                }

                let pendingWorkouts = store.outbox.filter {
                    if case .logWorkout = $0.kind { return true } else { return false }
                }
                if !pendingWorkouts.isEmpty {
                    Section("Waiting to upload") {
                        ForEach(pendingWorkouts) { item in
                            Label(item.title, systemImage: "icloud.and.arrow.up")
                        }
                    }
                }

                if !model.loading && model.history.isEmpty {
                    Section {
                        Text("No completed workouts to show")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(model.history) { item in
                    Section("#\(item.sessionId) • \(item.planWorkoutName)") {
                        Text("Finished: \(Formatters.dateTime(item.finishedAt))")
                        Text("Sets: \(item.completedSets)/\(item.totalSets)")
                        Text("Volume: \(WeightMath.displayWeightFromKg(item.totalVolumeKg, unit: settings.weightUnit)) \(settings.weightUnit.label)-reps")
                        Text("Duration: \(Formatters.duration(item.totalDurationSeconds))")

                        if item.heartRateSampleCount > 1,
                           let samples = model.heartRateBySession[item.sessionId], !samples.isEmpty {
                            Chart(samples) { sample in
                                LineMark(
                                    x: .value("Time", sample.recordedAt),
                                    y: .value("BPM", sample.bpm)
                                )
                                .foregroundStyle(.pink)
                            }
                            .frame(height: 160)
                        }

                        if item.stravaExportStatus == .sent, let url = item.stravaActivityUrl, let link = URL(string: url) {
                            Link("View on Strava", destination: link)
                        } else if model.stravaConnection?.connected == true {
                            Button(item.stravaExportStatus == .failed ? "Retry Strava" : "Send to Strava") {
                                Task { await model.sendToStrava(item: item, api: api) }
                            }
                        }

                        ForEach(item.personalRecords) { pr in
                            Text("🏆 \(pr.describe(unit: settings.weightUnit))")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }

                        ForEach(item.exercises) { exercise in
                            HStack {
                                Text(exercise.exerciseName)
                                Spacer()
                                Text("\(exercise.completedSets)x\(exercise.totalReps) • \(WeightMath.displayWeightFromKg(exercise.topWeightKg, unit: settings.weightUnit))")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            Button("Edit") { editingSessionId = item.sessionId }
                            Spacer()
                            Button("Delete", role: .destructive) { deleting = item }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("History")
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
            }
            .confirmationDialog(
                "Delete this workout?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible,
                presenting: deleting
            ) { item in
                Button("Delete \(item.planWorkoutName)", role: .destructive) {
                    Task { await model.delete(item: item, api: api) }
                }
            } message: { _ in
                Text("If it's your most recent workout, its progression is undone too. This can't be undone.")
            }
            .onChange(of: store.outbox.count) { _ in
                Task { await model.load(using: api) }
            }
        }
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
                if loading { ProgressView() }
                if !errorMessage.isEmpty {
                    Text(errorMessage).foregroundStyle(.red)
                }
                ForEach(groupedNames, id: \.self) { name in
                    Section(name) {
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
                                Text(unit.label).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(loading)
                }
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
