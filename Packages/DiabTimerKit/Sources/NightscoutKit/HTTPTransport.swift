import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Schicht für HTTP-Anfragen, damit der Client ohne Netzwerk getestet werden kann.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Standard-Transport über `URLSession`.
public struct URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: (data ?? Data(), http))
                } else {
                    continuation.resume(throwing: NightscoutError.invalidResponse)
                }
            }
            task.resume()
        }
    }
}

public enum NightscoutError: Error, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    /// Token unbekannt oder abgelaufen.
    case unauthorized
    /// Token ist gültig, hat aber nicht das nötige Recht.
    case forbidden
    case notFound
    case http(status: Int, message: String?)
    case decoding(String)
}

extension NightscoutError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Die Server-Adresse ist ungültig."
        case .invalidResponse:
            "Der Server hat unerwartet geantwortet."
        case .unauthorized:
            "Der Zugriffstoken wurde nicht akzeptiert."
        case .forbidden:
            "Dem Zugriffstoken fehlt eine Berechtigung."
        case .notFound:
            "Der Eintrag oder die Adresse wurde nicht gefunden."
        case .http(let status, let message):
            "Serverfehler \(status)\(message.map { ": \($0)" } ?? "")"
        case .decoding(let detail):
            "Antwort konnte nicht gelesen werden: \(detail)"
        }
    }
}
