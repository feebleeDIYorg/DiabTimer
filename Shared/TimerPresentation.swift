import SwiftUI
import TimerCore

/// Texte, Symbole und Farben für Timer und Stufen.
extension TimerKind {
    var displayName: String {
        switch self {
        case .cannula: "Kanüle"
        case .tubing: "Schlauch"
        case .insulin: "Insulin"
        case .sensor: "Sensor"
        case .battery: "Batterie"
        }
    }

    var symbolName: String {
        switch self {
        case .cannula: "syringe"
        case .tubing: "point.topleft.down.curvedto.point.bottomright.up"
        case .insulin: "drop"
        case .sensor: "waveform.path.ecg"
        case .battery: "battery.75percent"
        }
    }
}

extension TimerLevel {
    var color: Color {
        switch self {
        case .ok: .green
        case .info: .yellow
        case .warn: .orange
        case .urgent: .red
        }
    }

    var symbolName: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .urgent: "exclamationmark.octagon.fill"
        }
    }

    var displayName: String {
        switch self {
        case .ok: "In Ordnung"
        case .info: "Info"
        case .warn: "Warnung"
        case .urgent: "Dringend"
        }
    }
}

enum Formatting {
    /// „2 T 5 h“, „5 h 20 min“ oder „12 min“.
    static func duration(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(abs(interval) / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days) T \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        return "\(minutes) min"
    }

    /// „fällig in 5 h 20 min“ bzw. „überfällig seit 2 h 3 min“.
    static func dueText(_ status: TimerStatus) -> String {
        guard let remaining = status.timeUntilDue else { return "Noch kein Wechsel bekannt" }
        return remaining >= 0
            ? "fällig in \(duration(remaining))"
            : "überfällig seit \(duration(remaining))"
    }

    static func ageText(_ status: TimerStatus) -> String {
        guard let age = status.age else { return "–" }
        return duration(age)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    static func hours(_ interval: TimeInterval) -> String {
        let hours = interval / 3600
        if hours.rounded() == hours {
            return "\(Int(hours)) h"
        }
        return hours.formatted(.number.precision(.fractionLength(1))) + " h"
    }

    /// Minuten seit Mitternacht als Datum von heute (für `DatePicker`).
    static func date(fromMinuteOfDay minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    static func minuteOfDay(from date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}
