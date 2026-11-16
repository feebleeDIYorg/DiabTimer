import Foundation
import TimerCore

/// Liest die Schwellen der Plugins `cage`, `sage`, `iage` und `bage` aus `status.json`.
///
/// Die Werte stammen aus Umgebungsvariablen des Servers und können als Zahl oder als Text
/// ankommen. Fehlt ein Wert, gilt der Nightscout-Standard für diesen Timer.
public enum ExtendedSettingsParser {
    private static let pluginKeys: [TimerKind: String] = [
        .cannula: "cage",
        .sensor: "sage",
        .insulin: "iage",
        .battery: "bage",
    ]

    public static func thresholds(fromStatusJSON data: Data) throws -> [TimerKind: Thresholds] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NightscoutError.decoding("status.json ist kein Objekt")
        }
        let extended = root["extendedSettings"] as? [String: Any] ?? [:]
        var result: [TimerKind: Thresholds] = [:]
        for (kind, key) in pluginKeys {
            guard let plugin = extended[key] as? [String: Any] else { continue }
            let defaults = Thresholds.defaults(for: kind)
            let info = number(plugin["info"])
            let warn = number(plugin["warn"])
            let urgent = number(plugin["urgent"])
            guard info != nil || warn != nil || urgent != nil else { continue }
            let thresholds = Thresholds(
                info: info.map { $0 * 3600 } ?? defaults.info,
                warn: warn.map { $0 * 3600 } ?? defaults.warn,
                urgent: urgent.map { $0 * 3600 } ?? defaults.urgent
            )
            if thresholds.isValid {
                result[kind] = thresholds
            }
        }
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        case let text as String:
            return Double(text.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }
}
