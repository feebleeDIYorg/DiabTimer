import Foundation

/// Schwellen eines Timers, jeweils als Zeit seit dem letzten Wechsel.
public struct Thresholds: Codable, Equatable, Sendable {
    public var info: TimeInterval
    public var warn: TimeInterval
    public var urgent: TimeInterval

    public init(info: TimeInterval, warn: TimeInterval, urgent: TimeInterval) {
        self.info = info
        self.warn = warn
        self.urgent = urgent
    }

    public init(infoHours: Double, warnHours: Double, urgentHours: Double) {
        self.init(info: infoHours * 3600, warn: warnHours * 3600, urgent: urgentHours * 3600)
    }

    /// Die Schwelle für eine Stufe. `ok` hat keine Schwelle.
    public func interval(for level: TimerLevel) -> TimeInterval? {
        switch level {
        case .ok: nil
        case .info: info
        case .warn: warn
        case .urgent: urgent
        }
    }

    /// Sind die Schwellen aufsteigend und positiv?
    public var isValid: Bool {
        info > 0 && info <= warn && warn <= urgent
    }

    /// Standardwerte, identisch mit den Vorgaben der Nightscout-Plugins
    /// (`cage`, `sage`, `iage`, `bage`). Für den Schlauch gibt es kein Plugin.
    public static func defaults(for kind: TimerKind) -> Thresholds {
        switch kind {
        case .cannula: Thresholds(infoHours: 44, warnHours: 48, urgentHours: 72)
        case .insulin: Thresholds(infoHours: 44, warnHours: 48, urgentHours: 72)
        case .sensor: Thresholds(infoHours: 144, warnHours: 164, urgentHours: 166)
        case .battery: Thresholds(infoHours: 312, warnHours: 336, urgentHours: 360)
        case .tubing: Thresholds(infoHours: 120, warnHours: 144, urgentHours: 168)
        }
    }

    /// Schwellen aus der Laufzeit eines Sensors: Info 24 h, Warnung 6 h und
    /// dringend 2 h vor Ablauf.
    public static func sensor(lifetimeHours: Double) -> Thresholds {
        let info = max(lifetimeHours - 24, 1)
        let warn = max(lifetimeHours - 6, info)
        let urgent = max(lifetimeHours - 2, warn)
        return Thresholds(infoHours: info, warnHours: warn, urgentHours: urgent)
    }

    /// Vorschläge für die Sensor-Laufzeit in der Einrichtung, in Stunden.
    public static let sensorLifetimeSuggestions: [Double] = [7 * 24, 10 * 24, 10.5 * 24, 14 * 24, 15 * 24]
}
