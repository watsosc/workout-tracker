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
                    }
                }
            }
            .navigationTitle("History")
            .task { await model.load(using: api) }
            .refreshable { await model.load(using: api) }
            .onChange(of: store.outbox.count) { _ in
                Task { await model.load(using: api) }
            }
        }
    }
}
