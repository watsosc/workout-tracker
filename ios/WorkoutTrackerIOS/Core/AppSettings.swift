import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var graphqlEndpoint: String {
        didSet { UserDefaults.standard.set(graphqlEndpoint, forKey: Self.endpointKey) }
    }

    @Published var weightUnit: WeightUnit {
        didSet { UserDefaults.standard.set(weightUnit.rawValue, forKey: Self.weightUnitKey) }
    }

    private static let endpointKey = "workout.ios.graphql-endpoint"
    private static let weightUnitKey = "workout.weight-unit"

    init() {
        let envEndpoint = ProcessInfo.processInfo.environment["WORKOUT_GRAPHQL_ENDPOINT"]
        graphqlEndpoint = envEndpoint ?? UserDefaults.standard.string(forKey: Self.endpointKey) ?? "https://watsoworkout.duckdns.org/graphql"

        if let raw = UserDefaults.standard.string(forKey: Self.weightUnitKey), let saved = WeightUnit(rawValue: raw) {
            weightUnit = saved
        } else {
            weightUnit = .lb
        }
    }
}
