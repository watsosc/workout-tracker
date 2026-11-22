import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var graphqlEndpoint: String {
        didSet { UserDefaults.standard.set(graphqlEndpoint, forKey: Self.endpointKey) }
    }

    @Published var weightUnit: WeightUnit {
        didSet { UserDefaults.standard.set(weightUnit.rawValue, forKey: Self.weightUnitKey) }
    }

    /// Session token from the `login` mutation, kept in the Keychain.
    @Published private(set) var sessionToken: String?
    @Published private(set) var signedInUsername: String?
    /// Set when the server says sign-in is required; the root view shows the sign-in screen.
    @Published var needsSignIn = false
    private var signInSnoozedUntil: Date?

    private static let endpointKey = "workout.ios.graphql-endpoint"
    private static let weightUnitKey = "workout.weight-unit"
    private static let usernameKey = "workout.ios.signed-in-username"
    private static let tokenAccount = "session-token"

    init() {
        let envEndpoint = ProcessInfo.processInfo.environment["WORKOUT_GRAPHQL_ENDPOINT"]
        graphqlEndpoint = envEndpoint ?? UserDefaults.standard.string(forKey: Self.endpointKey) ?? "https://watsoworkout.duckdns.org/graphql"

        if let raw = UserDefaults.standard.string(forKey: Self.weightUnitKey), let saved = WeightUnit(rawValue: raw) {
            weightUnit = saved
        } else {
            weightUnit = .lb
        }

        sessionToken = KeychainStore.string(for: Self.tokenAccount)
        signedInUsername = UserDefaults.standard.string(forKey: Self.usernameKey)
    }

    var api: WorkoutAPI {
        WorkoutAPI(endpoint: graphqlEndpoint, token: sessionToken) { [weak self] in
            Task { @MainActor in self?.requestSignIn() }
        }
    }

    /// Show the sign-in screen, unless the user just chose "Not now".
    func requestSignIn() {
        if let until = signInSnoozedUntil, until > Date() { return }
        needsSignIn = true
    }

    func snoozeSignIn() {
        signInSnoozedUntil = Date().addingTimeInterval(10 * 60)
        needsSignIn = false
    }

    func signIn(username: String, password: String) async throws {
        let token = try await WorkoutAPI(endpoint: graphqlEndpoint).login(username: username, password: password)
        KeychainStore.set(token.token, for: Self.tokenAccount)
        UserDefaults.standard.set(token.username, forKey: Self.usernameKey)
        sessionToken = token.token
        signedInUsername = token.username
        signInSnoozedUntil = nil
        needsSignIn = false
    }

    func signOut() async {
        try? await api.logout()
        KeychainStore.set(nil, for: Self.tokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.usernameKey)
        sessionToken = nil
        signedInUsername = nil
    }

    /// Ask the server whether we need to sign in (ignored when offline).
    func checkAuthStatus() async {
        guard let status = try? await api.fetchAuthStatus() else { return }
        if status.authRequired && !status.signedIn { requestSignIn() }
    }
}
