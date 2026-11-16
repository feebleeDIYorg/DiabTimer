import Foundation

/// Die Teile, deren Alter DiabTimer verfolgt.
public enum TimerKind: String, Codable, CaseIterable, Sendable, Hashable, Comparable {
    case cannula
    case tubing
    case insulin
    case sensor
    case battery

    /// Feste Reihenfolge für Anzeige und Bündelung.
    public var sortIndex: Int {
        switch self {
        case .cannula: 0
        case .tubing: 1
        case .insulin: 2
        case .sensor: 3
        case .battery: 4
        }
    }

    public static func < (lhs: TimerKind, rhs: TimerKind) -> Bool {
        lhs.sortIndex < rhs.sortIndex
    }

    /// Wird der Timer über Nightscout geführt? Der Schlauch nicht, er liegt in iCloud.
    public var isNightscoutBacked: Bool {
        self != .tubing
    }
}

/// Eine Warnstufe. Die Reihenfolge entspricht der Dringlichkeit.
public enum TimerLevel: Int, Codable, Sendable, Comparable, CaseIterable {
    case ok = 0
    case info = 1
    case warn = 2
    case urgent = 3

    public static func < (lhs: TimerLevel, rhs: TimerLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension TimerKind: CodingKeyRepresentable {}
