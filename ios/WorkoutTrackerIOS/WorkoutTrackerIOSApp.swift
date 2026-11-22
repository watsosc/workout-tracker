import SwiftUI

@main
struct WorkoutTrackerIOSApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var workoutStore: OfflineWorkoutStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = AppSettings()
        let store = OfflineWorkoutStore()
        // Built on demand so endpoint/token changes in Settings apply to queued uploads.
        store.apiProvider = { settings.api }
        _settings = StateObject(wrappedValue: settings)
        _workoutStore = StateObject(wrappedValue: store)
        RestTimerNotifier.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(settings)
                .environmentObject(workoutStore)
                .preferredColorScheme(.dark)
                .sheet(isPresented: $settings.needsSignIn) {
                    SignInView()
                        .environmentObject(settings)
                        .environmentObject(workoutStore)
                        .interactiveDismissDisabled()
                }
                .task { await settings.checkAuthStatus() }
                // Mirror the workout onto the lock screen / Dynamic Island from any tab.
                .onReceive(workoutStore.$activeWorkout) { workout in
                    LiveActivityController.shared.sync(workout: workout, unit: settings.weightUnit)
                }
                .onChange(of: settings.weightUnit) { unit in
                    LiveActivityController.shared.sync(workout: workoutStore.activeWorkout, unit: unit)
                }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                Task {
                    await settings.checkAuthStatus()
                    await workoutStore.syncNow()
                }
            case .background:
                workoutStore.save()
            default:
                break
            }
        }
    }
}

private struct RootTabView: View {
    var body: some View {
        TabView {
            WorkoutView()
                .tabItem {
                    Label("Workout", systemImage: "figure.strengthtraining.traditional")
                }

            AnalyticsView()
                .tabItem {
                    Label("Analytics", systemImage: "chart.xyaxis.line")
                }

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}
