import Foundation

/// Ruhezeit als Minuten seit Mitternacht (Ortszeit). Darf über Mitternacht gehen.
public struct QuietHours: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var startMinute: Int
    public var endMinute: Int

    public init(isEnabled: Bool = true, startMinute: Int = 22 * 60, endMinute: Int = 7 * 60) {
        self.isEnabled = isEnabled
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// Liegt eine Uhrzeit (Minuten seit Mitternacht) in der Ruhezeit?
    public func contains(minuteOfDay minute: Int) -> Bool {
        guard isEnabled, startMinute != endMinute else { return false }
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        return minute >= startMinute || minute < endMinute
    }
}

/// Einstellungen für die Erinnerungsplanung.
public struct ReminderSettings: Codable, Equatable, Sendable {
    public var quietHours: QuietHours
    /// Uhrzeit der täglichen Überfällig-Erinnerung (Minuten seit Mitternacht).
    public var overdueMinuteOfDay: Int
    /// Erinnerungen innerhalb dieses Fensters werden gebündelt.
    public var bundleWindow: TimeInterval
    /// Um so viel wird „dringend“ vor den Beginn der Ruhezeit vorgezogen.
    public var urgentLeadBeforeQuietHours: TimeInterval
    /// Wie viele tägliche Überfällig-Erinnerungen im Voraus geplant werden.
    public var overdueRepeatCount: Int
    /// iOS erlaubt 64 geplante Benachrichtigungen pro App, mit Reserve.
    public var maxReminders: Int

    public init(
        quietHours: QuietHours = QuietHours(),
        overdueMinuteOfDay: Int = 9 * 60,
        bundleWindow: TimeInterval = 30 * 60,
        urgentLeadBeforeQuietHours: TimeInterval = 30 * 60,
        overdueRepeatCount: Int = 7,
        maxReminders: Int = 60
    ) {
        self.quietHours = quietHours
        self.overdueMinuteOfDay = overdueMinuteOfDay
        self.bundleWindow = bundleWindow
        self.urgentLeadBeforeQuietHours = urgentLeadBeforeQuietHours
        self.overdueRepeatCount = overdueRepeatCount
        self.maxReminders = maxReminders
    }
}

/// Eingabe pro Timer.
public struct TimerReminderInput: Equatable, Sendable {
    public var kind: TimerKind
    public var lastChange: Date?
    public var thresholds: Thresholds
    public var enabledLevels: Set<TimerLevel>
    public var snoozedUntil: Date?

    public init(
        kind: TimerKind,
        lastChange: Date?,
        thresholds: Thresholds,
        enabledLevels: Set<TimerLevel> = [.info, .warn, .urgent],
        snoozedUntil: Date? = nil
    ) {
        self.kind = kind
        self.lastChange = lastChange
        self.thresholds = thresholds
        self.enabledLevels = enabledLevels
        self.snoozedUntil = snoozedUntil
    }
}

/// Eine geplante (ggf. gebündelte) Erinnerung.
public struct PlannedReminder: Codable, Equatable, Hashable, Sendable {
    public var date: Date
    /// Höchste Stufe der enthaltenen Timer.
    public var level: TimerLevel
    /// Enthaltene Timer mit ihrer jeweiligen Stufe.
    public var items: [Item]

    public struct Item: Codable, Equatable, Hashable, Sendable {
        public var kind: TimerKind
        public var level: TimerLevel
        public var isOverdue: Bool

        public init(kind: TimerKind, level: TimerLevel, isOverdue: Bool) {
            self.kind = kind
            self.level = level
            self.isOverdue = isOverdue
        }
    }

    public var kinds: [TimerKind] { items.map(\.kind) }

    /// Stabile ID für `UNNotificationRequest`.
    public var id: String {
        let kindList = items.map(\.kind.rawValue).joined(separator: "+")
        return "dt-\(Int(date.timeIntervalSince1970))-\(kindList)"
    }
}

/// Berechnet aus den Timern einen vollständigen Erinnerungsplan.
///
/// Regeln (siehe PLAN.md, Abschnitt 6):
/// - Nur zukünftige Schwellen werden geplant.
/// - Schlummern: Bis zur Schlummer-Zeit entfallen die Erinnerungen des Timers, danach kommt genau eine.
/// - Überfällig: tägliche Erinnerung zur eingestellten Uhrzeit, frühestens 12 h nach „dringend“.
/// - Ruhezeit: Info und Warnung auf das Ende verschieben, „dringend“ vor den Beginn vorziehen.
/// - Erinnerungen innerhalb des Bündelfensters werden zu einer zusammengefasst.
public struct ReminderPlanner: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    private struct Candidate {
        var kind: TimerKind
        var date: Date
        var level: TimerLevel
        var isOverdue: Bool
        var isSnoozeFollowUp: Bool
    }

    public func plan(
        inputs: [TimerReminderInput],
        settings: ReminderSettings,
        now: Date
    ) -> [PlannedReminder] {
        var candidates: [Candidate] = []
        for input in inputs {
            candidates.append(contentsOf: self.candidates(for: input, settings: settings, now: now))
        }

        candidates = candidates.map { applyQuietHours($0, settings: settings, now: now) }
            .filter { $0.date > now }
            .sorted { lhs, rhs in
                lhs.date != rhs.date ? lhs.date < rhs.date : lhs.kind < rhs.kind
            }

        var reminders: [PlannedReminder] = []
        for candidate in candidates {
            let item = PlannedReminder.Item(
                kind: candidate.kind,
                level: candidate.level,
                isOverdue: candidate.isOverdue
            )
            if var last = reminders.last,
               candidate.date.timeIntervalSince(last.date) <= settings.bundleWindow {
                if let index = last.items.firstIndex(where: { $0.kind == candidate.kind }) {
                    if candidate.level > last.items[index].level {
                        last.items[index] = item
                    }
                } else {
                    last.items.append(item)
                    last.items.sort { $0.kind < $1.kind }
                }
                last.level = max(last.level, candidate.level)
                reminders[reminders.count - 1] = last
            } else {
                reminders.append(PlannedReminder(date: candidate.date, level: candidate.level, items: [item]))
            }
        }
        return Array(reminders.prefix(settings.maxReminders))
    }

    // MARK: - Kandidaten

    private func candidates(
        for input: TimerReminderInput,
        settings: ReminderSettings,
        now: Date
    ) -> [Candidate] {
        guard let lastChange = input.lastChange else { return [] }
        var result: [Candidate] = []

        for level in [TimerLevel.info, .warn, .urgent] where input.enabledLevels.contains(level) {
            guard let interval = input.thresholds.interval(for: level) else { continue }
            let date = lastChange.addingTimeInterval(interval)
            if date > now {
                result.append(Candidate(kind: input.kind, date: date, level: level, isOverdue: false, isSnoozeFollowUp: false))
            }
        }

        if input.enabledLevels.contains(.urgent) {
            let urgentDate = lastChange.addingTimeInterval(input.thresholds.urgent)
            var next = nextOccurrence(
                ofMinute: settings.overdueMinuteOfDay,
                onOrAfter: max(now.addingTimeInterval(1), urgentDate.addingTimeInterval(12 * 3600))
            )
            for _ in 0..<max(0, settings.overdueRepeatCount) {
                guard let date = next else { break }
                result.append(Candidate(kind: input.kind, date: date, level: .urgent, isOverdue: true, isSnoozeFollowUp: false))
                next = calendar.date(byAdding: .day, value: 1, to: date)
            }
        }

        if let snoozedUntil = input.snoozedUntil, snoozedUntil > now {
            result.removeAll { $0.date < snoozedUntil }
            let status = TimerStatus(kind: input.kind, lastChange: lastChange, thresholds: input.thresholds, now: snoozedUntil)
            if status.level > .ok {
                let followUp = Candidate(
                    kind: input.kind,
                    date: snoozedUntil,
                    level: status.level,
                    isOverdue: status.level == .urgent,
                    isSnoozeFollowUp: true
                )
                result.removeAll { abs($0.date.timeIntervalSince(snoozedUntil)) < 1 }
                result.append(followUp)
            }
        }
        return result
    }

    // MARK: - Ruhezeit

    private func applyQuietHours(_ candidate: Candidate, settings: ReminderSettings, now: Date) -> Candidate {
        let quiet = settings.quietHours
        guard !candidate.isSnoozeFollowUp,
              quiet.contains(minuteOfDay: minuteOfDay(candidate.date)) else {
            return candidate
        }
        var moved = candidate
        if candidate.level == .urgent && !candidate.isOverdue,
           let start = quietStart(containing: candidate.date, quiet: quiet) {
            let early = start.addingTimeInterval(-settings.urgentLeadBeforeQuietHours)
            if early > now {
                moved.date = early
                return moved
            }
        }
        if let end = quietEnd(after: candidate.date, quiet: quiet) {
            moved.date = end
        }
        return moved
    }

    func minuteOfDay(_ date: Date) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func date(atMinute minute: Int, onDayOf date: Date) -> Date? {
        let start = calendar.startOfDay(for: date)
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: start)
    }

    /// Erstes Vorkommen der Uhrzeit am oder nach `date`.
    func nextOccurrence(ofMinute minute: Int, onOrAfter date: Date) -> Date? {
        guard let sameDay = self.date(atMinute: minute, onDayOf: date) else { return nil }
        if sameDay >= date { return sameDay }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else {
            return nil
        }
        return self.date(atMinute: minute, onDayOf: nextDay)
    }

    /// Ende der Ruhezeit, in der `date` liegt.
    func quietEnd(after date: Date, quiet: QuietHours) -> Date? {
        nextOccurrence(ofMinute: quiet.endMinute, onOrAfter: date)
    }

    /// Beginn der Ruhezeit, in der `date` liegt.
    func quietStart(containing date: Date, quiet: QuietHours) -> Date? {
        guard let sameDay = self.date(atMinute: quiet.startMinute, onDayOf: date) else { return nil }
        if sameDay <= date { return sameDay }
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date)) else {
            return nil
        }
        return self.date(atMinute: quiet.startMinute, onDayOf: previousDay)
    }
}
