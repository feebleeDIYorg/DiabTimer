import Foundation

/// Wann „Schlauch auch gewechselt“ beim Kanülenwechsel vorausgewählt ist.
public enum TubingPolicy: Codable, Equatable, Sendable {
    case always
    case never
    /// Nur wenn der Schlauch älter ist als die angegebene Zeit.
    case olderThan(hours: Double)

    public static let standard = TubingPolicy.olderThan(hours: 96)

    /// Soll der Schlauch beim Kanülenwechsel mit angehakt sein?
    /// Ist noch kein Schlauchwechsel bekannt, wird er vorgeschlagen.
    public func suggestsTubingChange(lastTubingChange: Date?, at date: Date) -> Bool {
        switch self {
        case .always:
            return true
        case .never:
            return false
        case .olderThan(let hours):
            guard let lastTubingChange else { return true }
            return date.timeIntervalSince(lastTubingChange) >= hours * 3600
        }
    }
}

/// Die Liste der Schlauchwechsel, wie sie im iCloud-Schlüssel-Wert-Speicher liegt.
///
/// Zwei Geräte können unabhängig voneinander schreiben. `merged(with:)` vereinigt beide
/// Stände über die IDs, gelöschte IDs gewinnen. So geht kein Eintrag verloren.
public struct TubingLog: Codable, Equatable, Sendable {
    public static let maxEntries = 20
    public static let maxDeletedIDs = 100

    public private(set) var entries: [ChangeEvent]
    public private(set) var deletedIDs: [String]

    public init(entries: [ChangeEvent] = [], deletedIDs: [String] = []) {
        let deleted = Array(deletedIDs.suffix(Self.maxDeletedIDs))
        self.deletedIDs = deleted
        self.entries = Self.normalize(entries, deleted: Set(deleted))
    }

    public var latest: ChangeEvent? { entries.first }

    public mutating func add(_ event: ChangeEvent) {
        var event = event
        event.kind = .tubing
        entries.removeAll { $0.id == event.id }
        entries.append(event)
        entries = Self.normalize(entries, deleted: Set(deletedIDs))
    }

    public mutating func update(_ event: ChangeEvent) {
        add(event)
    }

    public mutating func delete(id: String) {
        entries.removeAll { $0.id == id }
        if !deletedIDs.contains(id) {
            deletedIDs.append(id)
            deletedIDs = Array(deletedIDs.suffix(Self.maxDeletedIDs))
        }
    }

    /// Vereinigt zwei Stände. Bei gleicher ID gewinnt die jüngere Änderung.
    public func merged(with other: TubingLog) -> TubingLog {
        var deleted = deletedIDs
        for id in other.deletedIDs where !deleted.contains(id) {
            deleted.append(id)
        }
        var byID: [String: ChangeEvent] = [:]
        for event in entries + other.entries {
            if let existing = byID[event.id], existing.updatedAt >= event.updatedAt {
                continue
            }
            byID[event.id] = event
        }
        return TubingLog(entries: Array(byID.values), deletedIDs: deleted)
    }

    private static func normalize(_ entries: [ChangeEvent], deleted: Set<String>) -> [ChangeEvent] {
        Array(entries.filter { !deleted.contains($0.id) }.sortedNewestFirst().prefix(maxEntries))
    }
}
