import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: OfflineWorkoutStore
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage = ""
    @State private var working = false
    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await signIn() } }
                } footer: {
                    if store.pendingUploadCount > 0 {
                        Text("Workouts saved on this phone will upload once you're signed in.")
                    }
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage).foregroundStyle(.red)
                }

                Button {
                    Task { await signIn() }
                } label: {
                    if working { ProgressView() } else { Text("Sign in").bold() }
                }
                .disabled(working || username.isEmpty || password.isEmpty)
            }
            .navigationTitle("Sign in")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") {
                        settings.snoozeSignIn()
                        dismiss()
                    }
                }
            }
            .onAppear {
                username = settings.signedInUsername ?? ""
                focusedField = username.isEmpty ? .username : .password
            }
        }
    }

    private func signIn() async {
        guard !username.isEmpty, !password.isEmpty else { return }
        working = true
        errorMessage = ""
        do {
            try await settings.signIn(username: username.trimmingCharacters(in: .whitespaces), password: password)
            await store.syncNow()
        } catch {
            errorMessage = error.localizedDescription
            password = ""
        }
        working = false
    }
}
