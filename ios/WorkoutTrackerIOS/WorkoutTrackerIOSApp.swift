import SwiftUI
import UIKit

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
        Self.applyNeonAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(settings)
                .environmentObject(workoutStore)
                .preferredColorScheme(.dark)
                .tint(Neon.yellow)
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
                .onChange(of: settings.weightUnit) { _, unit in
                    LiveActivityController.shared.sync(workout: workoutStore.activeWorkout, unit: unit)
                }
        }
        .onChange(of: scenePhase) { _, phase in
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

    /// Navigation bar titles in the theme fonts (screens that keep a system nav bar: Settings, Plans,
    /// Analytics and sheets).
    private static func applyNeonAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        if let large = UIFont(name: "ChakraPetch-Bold", size: 36) {
            appearance.largeTitleTextAttributes = [
                .font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large),
                .foregroundColor: UIColor(Neon.yellow),
                .kern: 2
            ]
        }
        if let title = UIFont(name: "ShareTechMono-Regular", size: 17) {
            appearance.titleTextAttributes = [
                .font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: title),
                .foregroundColor: UIColor(Neon.white),
                .kern: 1.5
            ]
        }
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }
}

enum AppTab: String, CaseIterable, Hashable {
    case workout, analytics, history, settings

    var title: String {
        switch self {
        case .workout: return "WORKOUT"
        case .analytics: return "ANALYTICS"
        case .history: return "HISTORY"
        case .settings: return "SETTINGS"
        }
    }

    var symbol: String {
        switch self {
        case .workout: return "figure.strengthtraining.traditional"
        case .analytics: return "chart.xyaxis.line"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

private struct RootTabView: View {
    // WORKOUT_INITIAL_TAB (dev/screenshot launches only) picks the starting tab.
    @State private var selection: AppTab = ProcessInfo.processInfo.environment["WORKOUT_INITIAL_TAB"]
        .flatMap(AppTab.init(rawValue:)) ?? .workout

    var body: some View {
        // A real TabView keeps each tab's navigation state and appear/disappear behaviour; its
        // system bar is hidden in favour of the themed one.
        TabView(selection: $selection) {
            WorkoutView().neonTabChrome(selection: $selection).tag(AppTab.workout)
            AnalyticsView().neonTabChrome(selection: $selection).tag(AppTab.analytics)
            HistoryView().neonTabChrome(selection: $selection).tag(AppTab.history)
            SettingsView().neonTabChrome(selection: $selection).tag(AppTab.settings)
        }
    }
}

private extension View {
    func neonTabChrome(selection: Binding<AppTab>) -> some View {
        toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                NeonTabBar(selection: selection)
                    // Fade content out under the bar, down to the screen edge.
                    .background(alignment: .bottom) {
                        LinearGradient(colors: [Neon.ink.opacity(0), Neon.ink], startPoint: .top, endPoint: .center)
                            .padding(.top, -28)
                            .ignoresSafeArea(edges: .bottom)
                            .allowsHitTesting(false)
                    }
            }
    }
}

private struct NeonTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let active = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 19, weight: .semibold))
                        Text(tab.title)
                            .font(Neon.mono(10, relativeTo: .caption2))
                            .tracking(1.4)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(active ? Neon.yellow : Neon.muted)
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .overlay(alignment: .top) {
                        if active {
                            Rectangle()
                                .fill(Neon.yellow)
                                .frame(height: 3)
                                .padding(.horizontal, 20)
                                .shadow(color: Neon.yellow, radius: 6)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title.capitalized)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .background(Color(hex: 0x07070B), in: CutCornerShape(cut: 16))
        .overlay(CutCornerShape(cut: 16).strokeBorder(Neon.line, lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
    }
}
