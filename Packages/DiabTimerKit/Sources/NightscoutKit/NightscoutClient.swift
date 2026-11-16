import Foundation
import TimerCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client für Nightscout API v3 (ab Nightscout 15).
///
/// Anmeldung: Der Zugriffstoken wird über `/api/v2/authorization/request/<token>` gegen ein
/// JWT getauscht, das als `Authorization: Bearer` mitgeht und vor Ablauf erneuert wird.
public actor NightscoutClient {
    public let baseURL: URL
    private let accessToken: String
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date

    private var jwt: String?
    private var jwtExpiry: Date?

    public init(
        baseURL: URL,
        accessToken: String,
        transport: HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.transport = transport
        self.now = now
    }

    /// Normalisiert eine eingegebene Adresse („meinns.example.com“ → https://…).
    public static func normalizedURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        return url
    }

    // MARK: - Öffentliche Aufrufe

    /// Version und Rechte des Tokens.
    public func status() async throws -> ServerStatus {
        let data = try await get(path: "api/v3/status")
        let envelope = try decodeEnvelope(StatusResult.self, from: data)
        let flags = envelope.apiPermissions?["treatments"] ?? ""
        return ServerStatus(
            version: envelope.version ?? "?",
            apiVersion: envelope.apiVersion,
            treatments: CollectionPermissions(flags)
        )
    }

    /// Schwellen aus `extendedSettings` von `GET /api/v1/status.json`.
    /// Fehlt ein Wert, ist der Timer nicht im Ergebnis enthalten.
    public func serverThresholds() async throws -> [TimerKind: Thresholds] {
        let data = try await get(path: "api/v1/status.json", queryItems: [URLQueryItem(name: "token", value: accessToken)], authenticated: false)
        return try ExtendedSettingsParser.thresholds(fromStatusJSON: data)
    }

    /// Die letzten Wechsel eines Timers, neuester zuerst.
    public func latestTreatments(for kind: TimerKind, limit: Int = 20) async throws -> [NightscoutTreatment] {
        let types = NightscoutEventType.eventTypes(for: kind)
        guard !types.isEmpty else { return [] }
        var query = [
            URLQueryItem(name: "sort$desc", value: "date"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if types.count == 1 {
            query.append(URLQueryItem(name: "eventType$eq", value: types[0]))
        } else {
            query.append(URLQueryItem(name: "eventType$in", value: types.joined(separator: "|")))
        }
        let data = try await get(path: "api/v3/treatments", queryItems: query)
        return try decodeEnvelope(LossyList<NightscoutTreatment>.self, from: data).elements.filter(\.isValid)
    }

    /// Alle seit `lastModified` (Millisekunden, Serverzeit) geänderten Einträge, auch gelöschte
    /// (`isValid == false`). Aufsteigend nach `srvModified`.
    public func history(since lastModified: Int64, limit: Int = 1000) async throws -> [NightscoutTreatment] {
        let data = try await get(
            path: "api/v3/treatments/history/\(lastModified)",
            queryItems: [URLQueryItem(name: "limit", value: String(limit))]
        )
        return try decodeEnvelope(LossyList<NightscoutTreatment>.self, from: data).elements
    }

    /// Sucht einen bestimmten eigenen Eintrag, um vor einer Wiederholung zu prüfen,
    /// ob er schon angekommen ist.
    public func findExisting(_ treatment: NewTreatment) async throws -> NightscoutTreatment? {
        let data = try await get(path: "api/v3/treatments", queryItems: [
            URLQueryItem(name: "eventType$eq", value: treatment.eventType),
            URLQueryItem(name: "date$eq", value: String(treatment.date)),
            URLQueryItem(name: "device$eq", value: treatment.device),
            URLQueryItem(name: "limit", value: "1"),
        ])
        return try decodeEnvelope(LossyList<NightscoutTreatment>.self, from: data).elements.first { $0.isValid }
    }

    public func create(_ treatment: NewTreatment) async throws -> CreateResult {
        let body = try JSONEncoder().encode(treatment)
        let data = try await send(method: "POST", path: "api/v3/treatments", body: body)
        do {
            return try JSONDecoder().decode(CreateResult.self, from: data)
        } catch {
            throw NightscoutError.decoding(String(describing: error))
        }
    }

    public func patch(identifier: String, _ patch: TreatmentPatch) async throws {
        let body = try JSONEncoder().encode(patch)
        _ = try await send(method: "PATCH", path: "api/v3/treatments/\(identifier)", body: body)
    }

    public func delete(identifier: String) async throws {
        _ = try await send(method: "DELETE", path: "api/v3/treatments/\(identifier)", body: nil)
    }

    // MARK: - Anmeldung

    private func bearerToken() async throws -> String {
        if let jwt, let jwtExpiry, jwtExpiry.timeIntervalSince(now()) > 60 {
            return jwt
        }
        let url = try makeURL(path: "api/v2/authorization/request/\(accessToken)", queryItems: [])
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 { throw NightscoutError.unauthorized }
            throw NightscoutError.http(status: response.statusCode, message: String(data: data, encoding: .utf8))
        }
        let result: JWTResponse
        do {
            result = try JSONDecoder().decode(JWTResponse.self, from: data)
        } catch {
            throw NightscoutError.decoding(String(describing: error))
        }
        jwt = result.token
        jwtExpiry = result.exp.map { Date(timeIntervalSince1970: $0) } ?? now().addingTimeInterval(3600)
        return result.token
    }

    // MARK: - HTTP

    private func get(path: String, queryItems: [URLQueryItem] = [], authenticated: Bool = true) async throws -> Data {
        try await perform(method: "GET", path: path, queryItems: queryItems, body: nil, authenticated: authenticated)
    }

    private func send(method: String, path: String, body: Data?) async throws -> Data {
        try await perform(method: method, path: path, queryItems: [], body: body, authenticated: true)
    }

    private func perform(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: Data?,
        authenticated: Bool,
        isRetry: Bool = false
    ) async throws -> Data {
        var request = URLRequest(url: try makeURL(path: path, queryItems: queryItems))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            request.setValue("Bearer \(try await bearerToken())", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300:
            return data
        case 401 where authenticated && !isRetry:
            // JWT abgelaufen oder widerrufen: einmal neu holen.
            jwt = nil
            jwtExpiry = nil
            return try await perform(
                method: method, path: path, queryItems: queryItems,
                body: body, authenticated: authenticated, isRetry: true
            )
        case 401:
            throw NightscoutError.unauthorized
        case 403:
            throw NightscoutError.forbidden
        case 404:
            throw NightscoutError.notFound
        default:
            throw NightscoutError.http(status: response.statusCode, message: Self.message(from: data))
        }
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard var components = URLComponents(string: base + "/" + path) else {
            throw NightscoutError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
            // „+“ würde vom Server als Leerzeichen gelesen.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw NightscoutError.invalidURL }
        return url
    }

    private func decodeEnvelope<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            if let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data), let result = envelope.result {
                return result
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NightscoutError.decoding(String(describing: error))
        }
    }

    private static func message(from data: Data) -> String? {
        if let object = try? JSONDecoder().decode(ErrorBody.self, from: data) {
            return object.message
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Interne Antwortformate

private struct Envelope<T: Decodable>: Decodable {
    var status: Int?
    var result: T?
}

private struct StatusResult: Decodable {
    var version: String?
    var apiVersion: String?
    var apiPermissions: [String: String]?
}

private struct JWTResponse: Decodable {
    var token: String
    var exp: Double?
}

/// Liste, die einzelne unlesbare Elemente überspringt, statt ganz zu scheitern.
struct LossyList<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(Skip.self)) == nil {
                // Element ist kein Objekt und lässt sich nicht überspringen.
                break
            }
        }
        self.elements = elements
    }

    private struct Skip: Decodable {}
}

private struct ErrorBody: Decodable {
    var message: String?
}
