import SwiftUI
import Charts

@MainActor
final class AnalyticsViewModel: ObservableObject {
    @Published var loading = false
    @Published var errorMessage = ""
    @Published var baselines: [Baseline] = []
    @Published var selectedExerciseId: Int?
    @Published var progress: [ExerciseProgressPoint] = []
    @Published var history: [WorkoutHistoryItem] = []

    func load(using api: WorkoutAPI) async {
        loading = true
        errorMessage = ""
        do {
            async let dashboard = api.fetchDashboard()
            async let historyData = api.fetchWorkoutHistory(limit: 300)
            let dash = try await dashboard
            baselines = dash.baselines
            history = try await historyData
            selectedExerciseId = baselines.first?.exerciseId
            await loadProgress(using: api)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func loadProgress(using api: WorkoutAPI) async {
        guard let selectedExerciseId else {
            progress = []
            return
        }

        do {
            progress = try await api.fetchExerciseProgress(exerciseId: selectedExerciseId, limit: 120)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AnalyticsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = AnalyticsViewModel()

    private var api: WorkoutAPI { WorkoutAPI(endpoint: settings.graphqlEndpoint) }

    var body: some View {
        NavigationStack {
            List {
                if model.loading {
                    ProgressView()
                }

                if !model.errorMessage.isEmpty {
                    Text(model.errorMessage).foregroundStyle(.red)
                }

                Section("Total volume") {
                    if model.history.isEmpty {
                        Text("No completed workouts yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Chart(model.history) { item in
                            LineMark(
                                x: .value("Date", Formatters.shortDate(item.finishedAt)),
                                y: .value("Volume", WeightMath.convertKgToUnit(item.totalVolumeKg, unit: settings.weightUnit))
                            )
                            .foregroundStyle(.blue)

                            PointMark(
                                x: .value("Date", Formatters.shortDate(item.finishedAt)),
                                y: .value("Volume", WeightMath.convertKgToUnit(item.totalVolumeKg, unit: settings.weightUnit))
                            )
                            .foregroundStyle(.blue)
                        }
                        .frame(height: 220)
                    }
                }

                Section("Exercise trends") {
                    Picker("Exercise", selection: $model.selectedExerciseId) {
                        ForEach(model.baselines) { baseline in
                            Text(baseline.exerciseName).tag(Optional(baseline.exerciseId))
                        }
                    }
                    .onChange(of: model.selectedExerciseId) { _ in
                        Task { await model.loadProgress(using: api) }
                    }

                    if model.progress.isEmpty {
                        Text("No progress points yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Chart(model.progress) { point in
                            LineMark(
                                x: .value("Date", Formatters.shortDate(point.date)),
                                y: .value("Top Set", WeightMath.convertKgToUnit(point.topWeightKg, unit: settings.weightUnit))
                            )
                            .foregroundStyle(.green)

                            LineMark(
                                x: .value("Date", Formatters.shortDate(point.date)),
                                y: .value("Estimated 1RM", WeightMath.convertKgToUnit(point.estimated1rmKg, unit: settings.weightUnit))
                            )
                            .foregroundStyle(.orange)
                        }
                        .frame(height: 220)
                    }
                }
            }
            .navigationTitle("Analytics")
            .task { await model.load(using: api) }
        }
    }
}
