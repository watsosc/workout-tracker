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
    @State private var choosingExercise = false

    private var api: WorkoutAPI { settings.api }

    var body: some View {
        NavigationStack {
            List {
                if model.loading {
                    ProgressView().tint(Neon.yellow)
                }

                if !model.errorMessage.isEmpty {
                    Text(model.errorMessage).font(Neon.mono(13)).foregroundStyle(Neon.red)
                }

                Section {
                    if model.history.isEmpty {
                        Text("No completed workouts yet.")
                            .foregroundStyle(Neon.muted)
                    } else {
                        Chart(model.history) { item in
                            LineMark(
                                x: .value("Date", Formatters.shortDate(item.finishedAt)),
                                y: .value("Volume", WeightMath.convertKgToUnit(item.totalVolumeKg, unit: settings.weightUnit))
                            )
                            .foregroundStyle(Neon.cyan)

                            PointMark(
                                x: .value("Date", Formatters.shortDate(item.finishedAt)),
                                y: .value("Volume", WeightMath.convertKgToUnit(item.totalVolumeKg, unit: settings.weightUnit))
                            )
                            .foregroundStyle(Neon.cyan)
                        }
                        .frame(height: 220)
                    }
                } header: {
                    NeonSectionHeader(text: "Total volume")
                }
                .neonRows()

                Section {
                    Button {
                        choosingExercise = true
                    } label: {
                        HStack {
                            Text("EXERCISE")
                                .font(Neon.mono(13, relativeTo: .footnote))
                                .tracking(1.2)
                                .foregroundStyle(Neon.muted)
                            Spacer()
                            Text((model.baselines.first { $0.exerciseId == model.selectedExerciseId }?.exerciseName ?? "Choose").uppercased())
                                .font(Neon.head(16, .bold))
                                .foregroundStyle(Neon.yellow)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Neon.cyan)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.baselines.isEmpty)
                    .onChange(of: model.selectedExerciseId) {
                        Task { await model.loadProgress(using: api) }
                    }

                    if model.progress.isEmpty {
                        Text("No progress points yet.")
                            .foregroundStyle(Neon.muted)
                    } else {
                        Chart(model.progress) { point in
                            LineMark(
                                x: .value("Date", Formatters.shortDate(point.date)),
                                y: .value("Top Set", WeightMath.convertKgToUnit(point.topWeightKg, unit: settings.weightUnit))
                            )
                            .foregroundStyle(Neon.yellow)

                            LineMark(
                                x: .value("Date", Formatters.shortDate(point.date)),
                                y: .value("Estimated 1RM", WeightMath.convertKgToUnit(point.estimated1rmKg, unit: settings.weightUnit))
                            )
                            .foregroundStyle(Neon.pink)
                        }
                        .frame(height: 220)
                    }
                } header: {
                    NeonSectionHeader(text: "Exercise trends")
                }
                .neonRows()
            }
            .neonForm()
            .neonTabBarClearance()
            .navigationTitle("ANALYTICS")
            .neonDialog(
                "Exercise",
                isPresented: $choosingExercise,
                kicker: "Select",
                buttons: model.baselines.map { baseline in
                    NeonDialogButton(
                        title: baseline.exerciseName,
                        kind: baseline.exerciseId == model.selectedExerciseId ? .primary : .ghost
                    ) { model.selectedExerciseId = baseline.exerciseId }
                } + [.cancel()]
            )
            .task { await model.load(using: api) }
        }
    }
}
