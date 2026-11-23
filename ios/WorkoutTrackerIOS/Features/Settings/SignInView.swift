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
        ZStack {
            NeonBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    VStack(alignment: .leading, spacing: 16) {
                        field(label: "Username", field: .username) {
                            TextField("", text: $username, prompt: prompt("USERNAME"))
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                        }
                        field(label: "Password", field: .password) {
                            SecureField("", text: $password, prompt: prompt("••••••••"))
                                .textContentType(.password)
                                .submitLabel(.go)
                                .onSubmit { Task { await signIn() } }
                        }

                        if !errorMessage.isEmpty {
                            Text(errorMessage)
                                .font(Neon.mono(13, relativeTo: .footnote))
                                .foregroundStyle(Neon.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .overlay(Rectangle().strokeBorder(Neon.red.opacity(0.6), lineWidth: 1))
                        }

                        Button {
                            Task { await signIn() }
                        } label: {
                            if working {
                                ProgressView().tint(.black)
                            } else {
                                Text("Sign in")
                            }
                        }
                        .buttonStyle(NeonButtonStyle(kind: .primary))
                        .disabled(working || username.isEmpty || password.isEmpty)
                        .padding(.top, 4)
                    }
                    .neonPanel(edge: Neon.heroEdge, padding: 18)

                    if store.pendingUploadCount > 0 {
                        HStack(alignment: .top, spacing: 8) {
                            NeonTag(text: "\(store.pendingUploadCount) queued", style: .cyan)
                            NeonFootnote(text: "Workouts saved on this phone will upload once you're signed in.")
                        }
                    }

                    Button("Not now") {
                        settings.snoozeSignIn()
                        dismiss()
                    }
                    .buttonStyle(NeonLinkStyle(color: Neon.muted))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 48)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .tint(Neon.yellow)
        .onAppear {
            username = settings.signedInUsername ?? ""
            focusedField = username.isEmpty ? .username : .password
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker(text: "// Authenticate", color: Neon.pink)
            Text("SIGN IN")
                .font(Neon.head(40, .bold, relativeTo: .largeTitle))
                .foregroundStyle(Neon.white)
                .glitch()
            Text("Connect to your workout server to sync.")
                .font(Neon.mono(13, relativeTo: .footnote))
                .foregroundStyle(Neon.muted)
        }
    }

    private func prompt(_ text: String) -> Text {
        Text(text).foregroundColor(Neon.muted.opacity(0.6))
    }

    private func field<Content: View>(label: String, field: Field, @ViewBuilder content: () -> Content) -> some View {
        let focused = focusedField == field
        let shape = CutCornerShape(cut: 10)
        return VStack(alignment: .leading, spacing: 6) {
            Kicker(text: label, color: focused ? Neon.yellow : Neon.muted)
            content()
                .focused($focusedField, equals: field)
                .font(Neon.mono(17))
                .foregroundStyle(Neon.white)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(Neon.ink2, in: shape)
                .overlay(shape.strokeBorder(focused ? Neon.yellow : Neon.line, lineWidth: 1))
                .shadow(color: focused ? Neon.yellow.opacity(0.25) : .clear, radius: 8)
                .contentShape(shape)
                .onTapGesture { focusedField = field }
        }
        .animation(.easeOut(duration: 0.15), value: focused)
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
