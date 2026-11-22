import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var loading = false
    @Published var errorMessage = ""
    @Published var infoMessage = ""
    @Published var activePlan: ActivePlan?
    @Published var baselines: [Baseline] = []
    @Published var resetBaselines: [Baseline] = []
    @Published var oneRepMaxInputs: [Int: String] = [:]
    @Published var resetInputs: [Int: String] = [:]
    @Published var stravaConnection: StravaConnection?

    func load(using api: WorkoutAPI, unit: WeightUnit) async {
        loading = true
        errorMessage = ""

        do {
            async let plan = api.fetchActivePlan()
            async let dash = api.fetchDashboard()
            async let strava = api.fetchStravaConnection()

            activePlan = try await plan
            let dashboard = try await dash
            baselines = dashboard.baselines
            resetBaselines = dashboard.resetBaselines.isEmpty ? dashboard.baselines : dashboard.resetBaselines
            stravaConnection = try await strava

            oneRepMaxInputs = Dictionary(uniqueKeysWithValues: baselines.map {
                ($0.exerciseId, WeightMath.displayWeightFromKg($0.baseline1rmKg, unit: unit))
            })
            resetInputs = Dictionary(uniqueKeysWithValues: resetBaselines.map {
                ($0.exerciseId, WeightMath.displayWeightFromKg($0.baseline1rmKg, unit: unit))
            })
        } catch {
            errorMessage = error.localizedDescription
        }

        loading = false
    }

    func saveOneRepMax(row: Baseline, unit: WeightUnit, api: WorkoutAPI) async {
        guard let text = oneRepMaxInputs[row.exerciseId], let value = Double(text), value > 0 else { return }
        do {
            try await api.setExerciseOneRepMax(exerciseId: row.exerciseId, oneRepMaxKg: WeightMath.convertUnitToKg(value, unit: unit))
            infoMessage = "Updated 1RM for \(row.exerciseName)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetProgress(unit: WeightUnit, api: WorkoutAPI) async {
        var overrides: [[String: Any]] = []
        for row in resetBaselines {
            guard let text = resetInputs[row.exerciseId], let value = Double(text), value > 0 else { continue }
            let converted = WeightMath.convertUnitToKg(value, unit: unit)
            if abs(converted - row.baseline1rmKg) > 0.0001 {
                overrides.append(["exerciseId": row.exerciseId, "baseline1rmKg": converted])
            }
        }

        do {
            try await api.resetToBaseline(baselineOverrides: overrides)
            infoMessage = "Progression reset to saved baseline"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleStravaAutoSend(api: WorkoutAPI) async {
        guard let stravaConnection else { return }
        do {
            try await api.setStravaAutoSendOnFinish(enabled: !stravaConnection.autoSendOnFinish)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnectStrava(api: WorkoutAPI) async {
        do {
            try await api.disconnectStrava()
            infoMessage = "Disconnected Strava"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: OfflineWorkoutStore
    @StateObject private var model = SettingsViewModel()

    private var api: WorkoutAPI { settings.api }

    var body: some View {
        NavigationStack {
            Form {
                Section("API") {
                    TextField("GraphQL endpoint", text: $settings.graphqlEndpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Use your hosted backend URL ending in /graphql.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Account") {
                    if let username = settings.signedInUsername, settings.sessionToken != nil {
                        HStack {
                            Text("Signed in as")
                            Spacer()
                            Text(username).foregroundStyle(.secondary)
                        }
                        Button("Sign out", role: .destructive) {
                            Task { await settings.signOut() }
                        }
                    } else {
                        Button("Sign in") { settings.needsSignIn = true }
                    }
                }

                Section {
                    if store.outbox.isEmpty {
                        Text("Everything is uploaded.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.outbox) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            Text("Saved \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if let error = item.lastError {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(item.needsAttention ? .red : .orange)
                            }
                            if item.needsAttention {
                                HStack {
                                    Button("Retry") { store.retry(item) }
                                    Spacer()
                                    Button("Discard", role: .destructive) { store.discard(item) }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    if !store.outbox.isEmpty {
                        Button(store.isSyncing ? "Uploading…" : "Sync now") {
                            Task { await store.syncNow() }
                        }
                        .disabled(store.isSyncing)
                    }
                } header: {
                    Text("Uploads")
                } footer: {
                    Text("Workouts are saved on this phone first and upload automatically when there's a connection.")
                }

                Section("Units") {
                    Picker("Weight unit", selection: $settings.weightUnit) {
                        ForEach(WeightUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Plans") {
                    NavigationLink {
                        PlansView()
                    } label: {
                        HStack {
                            Text("Active plan")
                            Spacer()
                            Text(model.activePlan?.name ?? "None")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Strava") {
                    if let strava = model.stravaConnection {
                        if !strava.configured {
                            Text("Strava is not configured on the backend.")
                        } else if strava.connected {
                            Toggle("Auto-send on finish", isOn: Binding(
                                get: { strava.autoSendOnFinish },
                                set: { _ in Task { await model.toggleStravaAutoSend(api: api); await model.load(using: api, unit: settings.weightUnit) } }
                            ))
                            Button("Disconnect") { Task { await model.disconnectStrava(api: api); await model.load(using: api, unit: settings.weightUnit) } }
                        } else {
                            Text("Connect Strava from the web app for now.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Training actions") {
                    ForEach(model.baselines) { row in
                        VStack(alignment: .leading) {
                            Text(row.exerciseName).font(.headline)
                            HStack {
                                TextField("Current 1RM", text: Binding(
                                    get: { model.oneRepMaxInputs[row.exerciseId] ?? "" },
                                    set: { model.oneRepMaxInputs[row.exerciseId] = $0 }
                                ))
                                .keyboardType(.decimalPad)

                                Button("Save") {
                                    Task { await model.saveOneRepMax(row: row, unit: settings.weightUnit, api: api) }
                                }
                            }

                            TextField("Reset value", text: Binding(
                                get: { model.resetInputs[row.exerciseId] ?? "" },
                                set: { model.resetInputs[row.exerciseId] = $0 }
                            ))
                            .keyboardType(.decimalPad)
                        }
                    }

                    Button("Reset progression") {
                        Task { await model.resetProgress(unit: settings.weightUnit, api: api); await model.load(using: api, unit: settings.weightUnit) }
                    }
                }

                if !model.errorMessage.isEmpty {
                    Text(model.errorMessage).foregroundStyle(.red)
                }
                if !model.infoMessage.isEmpty {
                    Text(model.infoMessage).foregroundStyle(.green)
                }
            }
            .navigationTitle("Settings")
            .task { await model.load(using: api, unit: settings.weightUnit) }
            .onChange(of: settings.weightUnit) { _ in
                Task { await model.load(using: api, unit: settings.weightUnit) }
            }
        }
    }
}
