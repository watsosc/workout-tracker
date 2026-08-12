import Foundation

struct GraphQLErrorItem: Codable {
    let message: String
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
        }
    }
}

struct GraphQLClient {
    let endpoint: String

    func execute<T: Decodable>(_ query: String, variables: [String: Any]? = nil, dataType: T.Type) async throws -> T {
        guard let url = URL(string: endpoint) else {
            throw GraphQLClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
