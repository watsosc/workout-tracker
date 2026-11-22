import Foundation
@testable import WorkoutTrackerIOS

/// Intercepts all GraphQL requests in tests. Each request is answered by `handler`, which sees
/// the operation text and variables and returns either a JSON body or an error.
final class StubURLProtocol: URLProtocol {
    enum Reply {
        case json(Any)
        case failure(URLError.Code)
    }

    struct Request {
        let query: String
        let variables: [String: Any]
        let authorization: String?
    }

    nonisolated(unsafe) static var handler: ((Request) -> Reply)?
    nonisolated(unsafe) static var requests: [Request] = []

    static func install() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        GraphQLClient.urlSession = URLSession(configuration: config)
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let parsed = Request(
            query: body["query"] as? String ?? "",
            variables: body["variables"] as? [String: Any] ?? [:],
            authorization: request.value(forHTTPHeaderField: "Authorization")
        )
        Self.requests.append(parsed)

        switch Self.handler?(parsed) ?? .failure(.notConnectedToInternet) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .json(let object):
            let data = try! JSONSerialization.data(withJSONObject: object)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLProtocol receives bodies as a stream.
    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
