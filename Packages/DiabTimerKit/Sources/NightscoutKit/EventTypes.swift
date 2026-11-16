import Foundation
import TimerCore

/// Zuordnung zwischen Nightscout-`eventType` und den Timern.
public enum NightscoutEventType {
    public static let siteChange = "Site Change"
    public static let sensorStart = "Sensor Start"
    public static let sensorChange = "Sensor Change"
    public static let insulinChange = "Insulin Change"
    public static let pumpBatteryChange = "Pump Battery Change"

    /// Alle Ereignistypen, die DiabTimer auswertet.
    public static let all: [String] = [siteChange, sensorStart, sensorChange, insulinChange, pumpBatteryChange]

    public static func kind(for eventType: String) -> TimerKind? {
        switch eventType {
        case siteChange: .cannula
        case sensorStart, sensorChange: .sensor
        case insulinChange: .insulin
        case pumpBatteryChange: .battery
        default: nil
        }
    }

    /// Ereignistypen, die für einen Timer zählen (beim Sensor zwei).
    public static func eventTypes(for kind: TimerKind) -> [String] {
        switch kind {
        case .cannula: [siteChange]
        case .sensor: [sensorStart, sensorChange]
        case .insulin: [insulinChange]
        case .battery: [pumpBatteryChange]
        case .tubing: []
        }
    }

    /// Ereignistyp, den DiabTimer beim Eintragen verwendet.
    public static func eventTypeForNewEntry(_ kind: TimerKind) -> String? {
        switch kind {
        case .cannula: siteChange
        case .sensor: sensorChange
        case .insulin: insulinChange
        case .battery: pumpBatteryChange
        case .tubing: nil
        }
    }
}

/// Feste Kennungen, mit denen DiabTimer seine Einträge markiert.
public enum DiabTimerIdentity {
    public static let app = "DiabTimer"
    public static let device = "DiabTimer"
    public static let enteredBy = "DiabTimer"
}
