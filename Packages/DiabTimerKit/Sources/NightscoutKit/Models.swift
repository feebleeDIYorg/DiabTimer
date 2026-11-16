import Foundation
import TimerCore

/// Ein Treatment, wie API v3 es liefert. Die Dekodierung ist bewusst tolerant,
/// weil ältere Clients Felder weglassen oder als Text speichern.
public struct NightscoutTreatment: Decodable, Equatable, Sendable {
    public var identifier: String
    public var eventType: String
    public var date: Date
    public var app: String?
    public var device: String?
    public var enteredBy: String?
    public var notes: String?
    public var isValid: Bool
    /// Serverzeit der letzten Änderung in Millisekunden.
    public var srvModified: Int64?

    public init(
        identifier: String,
        eventType: String,
        date: Date,
        app: String? = nil,
        device: String? = nil,
        enteredBy: String? = nil,
        notes: String? = nil,
        isValid: Bool = true,
        srvModified: Int64? = nil
    ) {
        self.identifier = identifier
        self.eventType = eventType
        self.date = date
        self.app = app
        self.device = device
        self.enteredBy = enteredBy
        self.notes = notes
        self.isValid = isValid
        self.srvModified = srvModified
    }

    private enum CodingKeys: String, CodingKey {
        case identifier, _id, eventType, date, created_at, app, device, enteredBy, notes, isValid, srvModified
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
            ?? container.decodeIfPresent(String.self, forKey: ._id) else {
            throw DecodingError.keyNotFound(
                CodingKeys.identifier,
                .init(codingPath: decoder.codingPath, debugDescription: "identifier fehlt")
            )
        }
        self.identifier = identifier
        self.eventType = (try? container.decodeIfPresent(String.self, forKey: .eventType)) ?? ""

        if let milliseconds = Self.decodeNumber(container, .date) {
            self.date = Date(timeIntervalSince1970: milliseconds / 1000)
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .created_at),
                  let parsed = NightscoutDate.parse(text) {
            self.date = parsed
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.date,
                .init(codingPath: decoder.codingPath, debugDescription: "date und created_at fehlen")
            )
        }

        self.app = try? container.decodeIfPresent(String.self, forKey: .app)
        self.device = try? container.decodeIfPresent(String.self, forKey: .device)
        self.enteredBy = try? container.decodeIfPresent(String.self, forKey: .enteredBy)
        self.notes = try? container.decodeIfPresent(String.self, forKey: .notes)
        self.isValid = (try? container.decodeIfPresent(Bool.self, forKey: .isValid)) ?? true
        self.srvModified = Self.decodeNumber(container, .srvModified).map { Int64($0) }
    }

    private static func decodeNumber(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }

    /// Timer, zu dem der Eintrag gehört.
    public var kind: TimerKind? { NightscoutEventType.kind(for: eventType) }

    /// Von DiabTimer eingetragen?
    public var isOwn: Bool { app == DiabTimerIdentity.app }

    /// Umwandlung in das gemeinsame Modell.
    public func changeEvent() -> ChangeEvent? {
        guard let kind else { return nil }
        let updated = srvModified.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        return ChangeEvent(
            id: identifier,
            kind: kind,
            date: date,
            note: notes,
            source: app ?? enteredBy ?? device,
            isOwn: isOwn,
            updatedAt: updated
        )
    }
}

/// Ein neuer Eintrag für `POST /api/v3/treatments`.
public struct NewTreatment: Codable, Equatable, Sendable {
    public var eventType: String
    /// Millisekunden seit 1970. Wird beim Antippen einmal festgelegt und bei
    /// Wiederholungen unverändert gesendet, damit der Server Duplikate erkennt.
    public var date: Int64
    public var utcOffset: Int
    public var app: String
    public var device: String
    public var enteredBy: String
    public var created_at: String
    public var notes: String?

    public init(eventType: String, date: Date, timeZone: TimeZone = .current, notes: String? = nil) {
        self.eventType = eventType
        self.date = Int64((date.timeIntervalSince1970 * 1000).rounded())
        self.utcOffset = timeZone.secondsFromGMT(for: date) / 60
        self.app = DiabTimerIdentity.app
        self.device = DiabTimerIdentity.device
        self.enteredBy = DiabTimerIdentity.enteredBy
        self.created_at = NightscoutDate.format(Date(timeIntervalSince1970: Double(self.date) / 1000))
        self.notes = (notes?.isEmpty ?? true) ? nil : notes
    }
}

/// Änderung eines bestehenden Eintrags für `PATCH /api/v3/treatments/{identifier}`.
public struct TreatmentPatch: Codable, Equatable, Sendable {
    public var date: Int64?
    public var utcOffset: Int?
    public var created_at: String?
    public var notes: String?

    public init(date: Date? = nil, timeZone: TimeZone = .current, notes: String? = nil) {
        if let date {
            let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
            self.date = milliseconds
            self.utcOffset = timeZone.secondsFromGMT(for: date) / 60
            self.created_at = NightscoutDate.format(Date(timeIntervalSince1970: Double(milliseconds) / 1000))
        }
        self.notes = notes
    }
}

/// Antwort auf `POST`.
public struct CreateResult: Decodable, Equatable, Sendable {
    public var identifier: String
    public var lastModified: Int64?
    public var isDeduplication: Bool?
}

/// Rechte eines Tokens auf eine Collection, aus `apiPermissions` (z. B. "crud").
public struct CollectionPermissions: Equatable, Sendable, Codable {
    public var create: Bool
    public var read: Bool
    public var update: Bool
    public var delete: Bool

    public init(create: Bool, read: Bool, update: Bool, delete: Bool) {
        self.create = create
        self.read = read
        self.update = update
        self.delete = delete
    }

    public init(_ flags: String) {
        self.init(
            create: flags.contains("c"),
            read: flags.contains("r"),
            update: flags.contains("u"),
            delete: flags.contains("d")
        )
    }

    public static let none = CollectionPermissions(create: false, read: false, update: false, delete: false)

    /// Mindestens nötig: lesen und anlegen.
    public var isSufficient: Bool { read && create }
}

/// Antwort von `GET /api/v3/status`.
public struct ServerStatus: Equatable, Sendable {
    public var version: String
    public var apiVersion: String?
    public var treatments: CollectionPermissions

    public init(version: String, apiVersion: String?, treatments: CollectionPermissions) {
        self.version = version
        self.apiVersion = apiVersion
        self.treatments = treatments
    }

    /// Hauptversion, z. B. 15 bei "15.0.9".
    public var majorVersion: Int? {
        version.split(separator: ".").first.flatMap { Int($0) }
    }
}

/// Datumsformat von Nightscout (`created_at`).
public enum NightscoutDate {
    public static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    public static func parse(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        if let date = try? Date.ISO8601FormatStyle().parse(text) {
            return date
        }
        return nil
    }
}
