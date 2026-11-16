import Foundation
@testable import NightscoutKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Antwortet auf Anfragen anhand des Pfads und zeichnet sie auf.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Route {
        var method: String
        var pathSuffix: String
        var status: Int
        var body: Data
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var _requests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func on(_ pathSuffix: String, method: String = "GET", status: Int = 200, fixture: String) {
        on(pathSuffix, method: method, status: status, body: Self.fixture(fixture))
    }

    func on(_ pathSuffix: String, method: String = "GET", status: Int = 200, body: Data = Data("{}".utf8)) {
        lock.lock()
        defer { lock.unlock() }
        // Neuere Routen haben Vorrang.
        routes.insert(Route(method: method, pathSuffix: pathSuffix, status: status, body: body), at: 0)
    }

    /// Zeichnet die Anfrage auf und sucht die passende Route (synchron, wegen `NSLock`).
    private func record(_ request: URLRequest) -> Route? {
        lock.lock()
        defer { lock.unlock() }
        _requests.append(request)
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        return routes.first { $0.method == method && path.hasSuffix($0.pathSuffix) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let route = record(request)

        guard let route, let url = request.url else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data("{\"message\":\"no route\"}".utf8), response)
        }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: nil, headerFields: nil)!
        return (route.body, response)
    }

    static func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "json")!
        return try! Data(contentsOf: url)
    }
}
