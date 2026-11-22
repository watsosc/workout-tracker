import Foundation

struct GraphQLErrorItem: Codable {
    struct Extensions: Codable { let code: String? }
    let message: String
    let extensions: Extensions?
}

struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLErrorItem]?
}

enum GraphQLClientError: Error, LocalizedError {
    case invalidURL
    case missingData
    case graphql([GraphQLErrorItem])
    case httpStatus(Int)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid GraphQL URL"
        case .missingData:
            return "GraphQL response missing data"
        case .graphql(let errors):
            return errors.map(\.message).joined(separator: "; ")
        case .httpStatus(let code):
            return "GraphQL HTTP error: \(code)"
        case .unauthorized:
            return "Sign in required"
        }
    }

    /// Errors worth retrying later (connectivity, server hiccups, or a token the user can fix),
    /// as opposed to the server rejecting the request itself.
    var isTransient: Bool {
        switch self {
        case .httpStatus(let code): return code >= 500 || code == 408 || code == 429
        case .unauthorized: return true
        case .invalidURL, .missingData, .graphql: return false
        }
    }
}

struct GraphQLClient {
    let endpoint: String
    var token: String? = nil
    var timeout: TimeInterval = 30
    /// Called when the server says the session is missing/expired.
    var onUnauthorized: (@Sendable () -> Void)? = nil

    func execute<T: Decodable>(_ query: String, variables: [String: Any]? = nil, dataType: T.Type) async throws -> T {
        guard let url = URL(string: endpoint) else {
            throw GraphQLClientError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = ["query": query]
        if let variables {
            body["variables"] = variables
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GraphQLClientError.httpStatus(http.statusCode)
        }

        let decoded = try JSONDecoder.iso8601.decode(GraphQLResponse<T>.self, from: data)
        if decoded.errors?.contains(where: { $0.extensions?.code == "UNAUTHENTICATED" }) == true {
            onUnauthorized?()
            throw GraphQLClientError.unauthorized
        }
        if let errors = decoded.errors, !errors.isEmpty {
            throw GraphQLClientError.graphql(errors)
        }
        guard let payload = decoded.data else {
            throw GraphQLClientError.missingData
        }
        return payload
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
