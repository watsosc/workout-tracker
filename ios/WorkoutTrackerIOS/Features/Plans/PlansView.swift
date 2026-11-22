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
    @StateObject private var model = PlansViewModel()
    @State private var planPendingRestart: PlanSummary?

    private var api: WorkoutAPI { WorkoutAPI(endpoint: settings.graphqlEndpoint) }

    var body: some View {
        List {
            if !model.errorMessage.isEmpty {
                Section { Text(model.errorMessage).foregroundStyle(.red) }
            }
            if !model.infoMessage.isEmpty {
                Section { Text(model.infoMessage).foregroundStyle(.green) }
            }

            Section {
                if model.activePlans.isEmpty {
                    Text("No active plan. Activate one below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.activePlans) { plan in
                    row(plan)
                }
            } header: {
                Text("Active")
            } footer: {
                Text("Only one plan can be active. Switching plans keeps each plan's progress, so you can switch back and resume.")
            }

            if !model.otherPlans.isEmpty {
                Section("Inactive") {
                    ForEach(model.otherPlans) { plan in
                        row(plan)
                    }
                }
            }

            if model.plans.isEmpty && !model.loading && model.errorMessage.isEmpty {
                Section {
                    Text("No plans yet. Create plans in the web app.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Plans")
        .overlay {
            if model.loading && model.plans.isEmpty { ProgressView() }
        }
        .refreshable { await model.load(using: api) }
        .task { await model.load(using: api) }
        .confirmationDialog(
            "Restart plan?",
            isPresented: Binding(
                get: { planPendingRestart != nil },
                set: { if !$0 { planPendingRestart = nil } }
            ),
            titleVisibility: .visible,
            presenting: planPendingRestart
        ) { plan in
            Button("Restart & activate") {
                Task { await model.activate(plan, using: api) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text("\"\(plan.name)\" was completed. It will restart from week 1.")
        }
    }

    @ViewBuilder
    private func row(_ plan: PlanSummary) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(plan.name).font(.headline)
                    statusBadge(plan)
                }
                Text(details(plan))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if plan.isRunning {
                Button("Deactivate") {
                    Task { await model.deactivate(plan, using: api) }
                }
                .buttonStyle(.bordered)
            } else {
                Button(plan.isCompleted ? "Restart" : "Activate") {
                    if plan.isCompleted {
                        planPendingRestart = plan
                    } else {
                        Task { await model.activate(plan, using: api) }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .disabled(model.loading)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusBadge(_ plan: PlanSummary) -> some View {
        let (label, color): (String, Color) = plan.isRunning
            ? ("Active", .green)
            : plan.isCompleted ? ("Completed", .blue) : ("Inactive", .gray)
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .overlay(Capsule().stroke(color, lineWidth: 1))
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
