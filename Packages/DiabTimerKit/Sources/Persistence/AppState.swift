import Foundation
import NightscoutKit
import TimerCore

/// Einstellungen der App. Fehlende Felder in älteren Dateien bekommen Standardwerte.
public struct AppSettings: Codable, Equatable, Sendable {
    public var thresholds: [TimerKind: Thresholds]
    public var enabledTimers: Set<TimerKind>
    public var enabledLevels: [TimerKind: Set<TimerLevel>]
    public var reminders: ReminderSettings
    public var tubingPolicy: TubingPolicy
    public var insulinWithCannula: Bool
    /// Wartezeit vor dem Senden, in der „Rückgängig“ möglich ist.
    public var sendDelay: TimeInterval
    public var sensorLifetimeHours: Double?

    public init(
        thresholds: [TimerKind: Thresholds] = [:],
        enabledTimers: Set<TimerKind> = Set(TimerKind.allCases),
        enabledLevels: [TimerKind: Set<TimerLevel>] = [:],
        reminders: ReminderSettings = ReminderSettings(),
        tubingPolicy: TubingPolicy = .standard,
        insulinWithCannula: Bool = false,
        sendDelay: TimeInterval = 15,
        sensorLifetimeHours: Double? = nil
    ) {
        self.thresholds = thresholds
        self.enabledTimers = enabledTimers
        self.enabledLevels = enabledLevels
        self.reminders = reminders
        self.tubingPolicy = tubingPolicy
        self.insulinWithCannula = insulinWithCannula
        self.sendDelay = sendDelay
        self.sensorLifetimeHours = sensorLifetimeHours
    }

    public func thresholds(for kind: TimerKind) -> Thresholds {
        thresholds[kind] ?? .defaults(for: kind)
    }

    public func levels(for kind: TimerKind) -> Set<TimerLevel> {
        enabledLevels[kind] ?? [.info, .warn, .urgent]
    }

    /// Aktive Timer in fester Reihenfolge.
    public var orderedEnabledTimers: [TimerKind] {
        TimerKind.allCases.filter { enabledTimers.contains($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case thresholds, enabledTimers, enabledLevels, reminders, tubingPolicy
        case insulinWithCannula, sendDelay, sensorLifetimeHours
    }

    public init(from decoder: Decoder) throws {
        let defaults = AppSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thresholds = (try? container.decodeIfPresent([TimerKind: Thresholds].self, forKey: .thresholds)) ?? defaults.thresholds
        enabledTimers = (try? container.decodeIfPresent(Set<TimerKind>.self, forKey: .enabledTimers)) ?? defaults.enabledTimers
        enabledLevels = (try? container.decodeIfPresent([TimerKind: Set<TimerLevel>].self, forKey: .enabledLevels)) ?? defaults.enabledLevels
        reminders = (try? container.decodeIfPresent(ReminderSettings.self, forKey: .reminders)) ?? defaults.reminders
        tubingPolicy = (try? container.decodeIfPresent(TubingPolicy.self, forKey: .tubingPolicy)) ?? defaults.tubingPolicy
        insulinWithCannula = (try? container.decodeIfPresent(Bool.self, forKey: .insulinWithCannula)) ?? defaults.insulinWithCannula
        sendDelay = (try? container.decodeIfPresent(TimeInterval.self, forKey: .sendDelay)) ?? defaults.sendDelay
        sensorLifetimeHours = try? container.decodeIfPresent(Double.self, forKey: .sensorLifetimeHours)
    }
}

/// Ein Auftrag an Nightscout, der noch nicht erledigt ist.
public struct OutboxItem: Codable, Equatable, Sendable, Identifiable {
    public enum Operation: Codable, Equatable, Sendable {
        case create(NewTreatment)
        case patch(identifier: String, patch: TreatmentPatch)
        case delete(identifier: String)
    }

    /// ID des lokalen Ereignisses, auf das sich der Auftrag bezieht.
    public var id: String
    public var kind: TimerKind
    public var operation: Operation
    public var sendAfter: Date
    public var attempts: Int
    public var lastError: String?

    public init(id: String, kind: TimerKind, operation: Operation, sendAfter: Date, attempts: Int = 0, lastError: String? = nil) {
        self.id = id
        self.kind = kind
        self.operation = operation
        self.sendAfter = sendAfter
        self.attempts = attempts
        self.lastError = lastError
    }

    public var isCreate: Bool {
        if case .create = operation { return true }
        return false
    }
}

/// Bestätigungszustand des Widget-Buttons (zwei Tipps).
public struct WidgetConfirmation: Codable, Equatable, Sendable {
    public var kind: TimerKind
    public var expiresAt: Date

    public init(kind: TimerKind, expiresAt: Date) {
        self.kind = kind
        self.expiresAt = expiresAt
    }
}

/// Gesamter Zustand, der als JSON in der App Group liegt und von App und Widget geteilt wird.
public struct AppState: Codable, Equatable, Sendable {
    public static let maxEventsPerKind = 20

    /// Nightscout-Wechsel je Timer, neuester zuerst (ohne Schlauch).
    public var events: [TimerKind: [ChangeEvent]]
    public var tubing: TubingLog
    /// Das Widget hat einen Schlauchwechsel eingetragen, den die App noch nach iCloud schreiben muss.
    public var tubingNeedsUpload: Bool
    public var outbox: [OutboxItem]
    /// Höchster `srvModified`-Wert für den `history`-Abgleich (Millisekunden).
    public var lastModified: Int64?
    public var lastSync: Date?
    public var lastSyncError: String?
    public var snoozes: [TimerKind: Date]
    public var settings: AppSettings
    public var permissions: CollectionPermissions?
    public var serverVersion: String?
    public var widgetConfirmation: WidgetConfirmation?
    /// Fremde Kanülenwechsel, zu denen schon nach dem Schlauch gefragt wurde.
    public var askedAboutTubingFor: [String]

    public init(
        events: [TimerKind: [ChangeEvent]] = [:],
        tubing: TubingLog = TubingLog(),
        tubingNeedsUpload: Bool = false,
        outbox: [OutboxItem] = [],
        lastModified: Int64? = nil,
        lastSync: Date? = nil,
        lastSyncError: String? = nil,
        snoozes: [TimerKind: Date] = [:],
        settings: AppSettings = AppSettings(),
        permissions: CollectionPermissions? = nil,
        serverVersion: String? = nil,
        widgetConfirmation: WidgetConfirmation? = nil,
        askedAboutTubingFor: [String] = []
    ) {
        self.events = events
        self.tubing = tubing
        self.tubingNeedsUpload = tubingNeedsUpload
        self.outbox = outbox
        self.lastModified = lastModified
        self.lastSync = lastSync
        self.lastSyncError = lastSyncError
        self.snoozes = snoozes
        self.settings = settings
        self.permissions = permissions
        self.serverVersion = serverVersion
        self.widgetConfirmation = widgetConfirmation
        self.askedAboutTubingFor = askedAboutTubingFor
    }

    private enum CodingKeys: String, CodingKey {
        case events, tubing, tubingNeedsUpload, outbox, lastModified, lastSync, lastSyncError
        case snoozes, settings, permissions, serverVersion, widgetConfirmation, askedAboutTubingFor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = (try? container.decodeIfPresent([TimerKind: [ChangeEvent]].self, forKey: .events)) ?? [:]
        tubing = (try? container.decodeIfPresent(TubingLog.self, forKey: .tubing)) ?? TubingLog()
        tubingNeedsUpload = (try? container.decodeIfPresent(Bool.self, forKey: .tubingNeedsUpload)) ?? false
        outbox = (try? container.decodeIfPresent([OutboxItem].self, forKey: .outbox)) ?? []
        lastModified = try? container.decodeIfPresent(Int64.self, forKey: .lastModified)
        lastSync = try? container.decodeIfPresent(Date.self, forKey: .lastSync)
        lastSyncError = try? container.decodeIfPresent(String.self, forKey: .lastSyncError)
        snoozes = (try? container.decodeIfPresent([TimerKind: Date].self, forKey: .snoozes)) ?? [:]
        settings = (try? container.decodeIfPresent(AppSettings.self, forKey: .settings)) ?? AppSettings()
        permissions = try? container.decodeIfPresent(CollectionPermissions.self, forKey: .permissions)
        serverVersion = try? container.decodeIfPresent(String.self, forKey: .serverVersion)
        widgetConfirmation = try? container.decodeIfPresent(WidgetConfirmation.self, forKey: .widgetConfirmation)
        askedAboutTubingFor = (try? container.decodeIfPresent([String].self, forKey: .askedAboutTubingFor)) ?? []
    }

    // MARK: - Abfragen

    /// Wechsel eines Timers, neuester zuerst.
    public func history(for kind: TimerKind) -> [ChangeEvent] {
        kind == .tubing ? tubing.entries : (events[kind] ?? [])
    }

    public func lastChange(for kind: TimerKind) -> Date? {
        history(for: kind).first?.date
    }

    public func status(for kind: TimerKind, now: Date) -> TimerStatus {
        TimerStatus(
            kind: kind,
            lastChange: lastChange(for: kind),
            thresholds: settings.thresholds(for: kind),
            now: now
        )
    }

    /// Status aller aktiven Timer in fester Reihenfolge.
    public func statuses(now: Date) -> [TimerStatus] {
        settings.orderedEnabledTimers.map { status(for: $0, now: now) }
    }

    /// Eingaben für den Erinnerungsplan.
    public func reminderInputs() -> [TimerReminderInput] {
        settings.orderedEnabledTimers.map { kind in
            TimerReminderInput(
                kind: kind,
                lastChange: lastChange(for: kind),
                thresholds: settings.thresholds(for: kind),
                enabledLevels: settings.levels(for: kind),
                snoozedUntil: snoozes[kind]
            )
        }
    }

    /// Wird ein Ereignis noch nicht gesendet (Rückgängig noch möglich)?
    public func isPending(eventID: String) -> Bool {
        outbox.contains { $0.id == eventID && $0.isCreate }
    }

    /// Schlummer-Zeiten, die abgelaufen sind, entfernen.
    public mutating func pruneSnoozes(now: Date) {
        snoozes = snoozes.filter { $0.value > now }
    }
}
