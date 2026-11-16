import Foundation

/// Ein Wechsel eines Teils, egal ob aus Nightscout oder aus iCloud.
public struct ChangeEvent: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Nightscout-`identifier` bzw. UUID beim Schlauch oder bei noch nicht gesendeten Einträgen.
    public var id: String
    public var kind: TimerKind
    /// Zeitpunkt des Wechsels (intern immer absolut, also UTC).
    public var date: Date
    public var note: String?
    /// Herkunft, z. B. `app` oder `enteredBy` aus Nightscout.
    public var source: String?
    /// Von DiabTimer eingetragen?
    public var isOwn: Bool
    /// Letzte Änderung, für das Zusammenführen von Listen.
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: TimerKind,
        date: Date,
        note: String? = nil,
        source: String? = nil,
        isOwn: Bool,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.date = date
        self.note = note
        self.source = source
        self.isOwn = isOwn
        self.updatedAt = updatedAt ?? date
    }
}

extension Array where Element == ChangeEvent {
    /// Neuester Eintrag zuerst.
    public func sortedNewestFirst() -> [ChangeEvent] {
        sorted { lhs, rhs in
            lhs.date != rhs.date ? lhs.date > rhs.date : lhs.id > rhs.id
        }
    }

    /// Durchschnittliche Tragedauer aus aufeinanderfolgenden Wechseln, höchstens `limit` Abstände.
    public func averageWearDuration(limit: Int = 10) -> TimeInterval? {
        let sorted = sortedNewestFirst()
        guard sorted.count >= 2 else { return nil }
        var durations: [TimeInterval] = []
        for index in 0..<(sorted.count - 1) where durations.count < limit {
            let duration = sorted[index].date.timeIntervalSince(sorted[index + 1].date)
            if duration > 0 { durations.append(duration) }
        }
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +) / Double(durations.count)
    }
}
