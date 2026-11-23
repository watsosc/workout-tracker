import SwiftUI

@MainActor
final class PlansViewModel: ObservableObject {
    @Published var loading = false
    @Published var errorMessage = ""
    @Published var infoMessage = ""
    @Published var plans: [PlanSummary] = []

    var activePlans: [PlanSummary] { plans.filter(\.isRunning) }
    var otherPlans: [PlanSummary] { plans.filter { !$0.isRunning } }

    func load(using api: WorkoutAPI) async {
        loading = true
        errorMessage = ""
        do {
            plans = try await api.fetchPlans()
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func activate(_ plan: PlanSummary, using api: WorkoutAPI) async {
        await perform(api: api) { try await api.setActivePlan(planId: plan.id) }
    }

    func deactivate(_ plan: PlanSummary, using api: WorkoutAPI) async {
        await perform(api: api) { try await api.deactivatePlan(planId: plan.id) }
    }

    private func perform(api: WorkoutAPI, action: () async throws -> String) async {
        loading = true
        errorMessage = ""
        infoMessage = ""
        do {
            infoMessage = try await action()
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
        await load(using: api)
    }
}

struct PlansView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: OfflineWorkoutStore
    @StateObject private var model = PlansViewModel()
    @State private var planPendingRestart: PlanSummary?

    private var api: WorkoutAPI { settings.api }

    var body: some View {
        List {
            if !model.errorMessage.isEmpty {
                Section { Text(model.errorMessage).font(Neon.mono(13)).foregroundStyle(Neon.red) }
                .neonRows()
            }
            if !model.infoMessage.isEmpty {
                Section { Text(model.infoMessage).font(Neon.mono(13)).foregroundStyle(Neon.cyan) }
                .neonRows()
            }
            if store.activeWorkout != nil {
                Section {
                    Text("Finish or discard the workout in progress before switching plans.")
                        .foregroundStyle(.orange)
                }
                .neonRows()
            }

            Section {
                if model.activePlans.isEmpty {
                    Text("No active plan. Activate one below.")
                        .foregroundStyle(Neon.muted)
                }
                ForEach(model.activePlans) { plan in
                    row(plan)
                }
            } header: { NeonSectionHeader(text: "Active") } footer: {
                NeonFootnote(text: "Only one plan can be active. Switching plans keeps each plan's progress, so you can switch back and resume.")
            }
            .neonRows()

            if !model.otherPlans.isEmpty {
                Section {
                    ForEach(model.otherPlans) { plan in
                        row(plan)
                    }
                } header: {
                    NeonSectionHeader(text: "Inactive")
                }
                .neonRows()
            }

            if model.plans.isEmpty && !model.loading && model.errorMessage.isEmpty {
                Section {
                    Text("No plans yet. Create plans in the web app.")
                        .foregroundStyle(Neon.muted)
                }
                .neonRows()
            }
        }
        .neonForm()
        .neonTabBarClearance()
        .navigationTitle("PLANS")
        .overlay {
            if model.loading && model.plans.isEmpty { ProgressView().tint(Neon.yellow) }
        }
        .refreshable { await model.load(using: api) }
        .task { await model.load(using: api) }
        .neonDialog(
            item: $planPendingRestart,
            title: { _ in "Restart plan?" },
            message: { plan in "\"\(plan.name)\" was completed. It will restart from week 1." },
            buttons: { plan in
                [
                    NeonDialogButton(title: "Restart & activate", kind: .primary) {
                        Task { await model.activate(plan, using: api) }
                    },
                    .cancel()
                ]
            }
        )
    }

    @ViewBuilder
    private func row(_ plan: PlanSummary) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(plan.name.uppercased())
                        .font(Neon.head(16, .bold, relativeTo: .headline))
                        .tracking(0.8)
                        .foregroundStyle(Neon.white)
                    statusBadge(plan)
                }
                Text(details(plan).uppercased())
                    .font(Neon.mono(11, relativeTo: .caption))
                    .foregroundStyle(Neon.muted)
            }

            Spacer()

            if plan.isRunning {
                Button("Deactivate") {
                    Task { await model.deactivate(plan, using: api) }
                }
                .buttonStyle(NeonButtonStyle(kind: .ghost, height: 34, fontSize: 12))
                .fixedSize()
            } else {
                Button(plan.isCompleted ? "Restart" : "Activate") {
                    if plan.isCompleted {
                        planPendingRestart = plan
                    } else {
                        Task { await model.activate(plan, using: api) }
                    }
                }
                .buttonStyle(NeonButtonStyle(kind: .primary, height: 34, fontSize: 12))
                .fixedSize()
            }
        }
        .disabled(model.loading || store.activeWorkout != nil)
        .padding(.vertical, 2)
    }

    private func statusBadge(_ plan: PlanSummary) -> some View {
        plan.isRunning
            ? NeonTag(text: "Active", style: .yellow)
            : plan.isCompleted ? NeonTag(text: "Completed", style: .cyan) : NeonTag(text: "Inactive")
    }

    private func details(_ plan: PlanSummary) -> String {
        var parts: [String] = []
        parts.append("\(plan.daysPerWeek) day\(plan.daysPerWeek == 1 ? "" : "s")")
        parts.append("\(plan.exerciseCount) exercise\(plan.exerciseCount == 1 ? "" : "s")")
        if plan.isCompleted {
            parts.append("Completed")
        } else if let week = plan.currentWeek {
            let day = min((plan.currentWorkoutIndex ?? 0) + 1, max(plan.daysPerWeek, 1))
            parts.append("Week \(week) · next day \(day)")
        }
        parts.append("\(plan.completedWorkoutCount) logged")
        return parts.joined(separator: " · ")
    }
}
