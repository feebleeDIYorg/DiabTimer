import Foundation

/// Zustand eines Timers zu einem Zeitpunkt.
public struct TimerStatus: Equatable, Sendable {
    public var kind: TimerKind
    /// Letzter Wechsel, `nil` wenn noch keiner bekannt ist.
    public var lastChange: Date?
    public var thresholds: Thresholds
    public var now: Date

    public init(kind: TimerKind, lastChange: Date?, thresholds: Thresholds, now: Date) {
        self.kind = kind
        self.lastChange = lastChange
        self.thresholds = thresholds
        self.now = now
    }

    /// Alter seit dem letzten Wechsel.
    public var age: TimeInterval? {
        lastChange.map { max(0, now.timeIntervalSince($0)) }
    }

    /// Aktuelle Stufe. Ohne bekannten Wechsel `ok`.
    public var level: TimerLevel {
        guard let age else { return .ok }
        if age >= thresholds.urgent { return .urgent }
        if age >= thresholds.warn { return .warn }
        if age >= thresholds.info { return .info }
        return .ok
    }

    /// Zeitpunkt, an dem eine Stufe erreicht wird.
    public func date(for level: TimerLevel) -> Date? {
        guard let lastChange, let interval = thresholds.interval(for: level) else { return nil }
        return lastChange.addingTimeInterval(interval)
    }

    /// Fälligkeit, also das Erreichen von „dringend“.
    public var dueDate: Date? { date(for: .urgent) }

    /// Zeit bis „dringend“, negativ wenn überfällig.
    public var timeUntilDue: TimeInterval? {
        dueDate.map { $0.timeIntervalSince(now) }
    }

    /// Die nächste noch nicht erreichte Stufe mit Zeitpunkt.
    public var nextTransition: (level: TimerLevel, date: Date)? {
        for candidate in [TimerLevel.info, .warn, .urgent] where candidate > level {
            if let date = date(for: candidate) { return (candidate, date) }
        }
        return nil
    }

    /// Anteil des Wegs bis „dringend“ (0…1), für Ringe und Balken.
    public var progress: Double {
        guard let age, thresholds.urgent > 0 else { return 0 }
        return min(1, max(0, age / thresholds.urgent))
    }

    /// Alle Zeitpunkte, an denen sich die Stufe ändert, ab `now`.
    /// Wird für Widget-Timelines gebraucht.
    public var upcomingTransitionDates: [Date] {
        [TimerLevel.info, .warn, .urgent].compactMap { date(for: $0) }.filter { $0 > now }
    }
}
