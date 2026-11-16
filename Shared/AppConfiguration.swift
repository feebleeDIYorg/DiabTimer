import Foundation

/// Werte aus der Info.plist, die über die xcconfig-Dateien gesetzt werden.
enum AppConfiguration {
    /// App Group, über die App und Widget den Zustand teilen.
    static var appGroupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "DTAppGroupIdentifier") as? String
    }

    /// Kennung der Hintergrundaktualisierung (`BGAppRefreshTask`).
    static var backgroundRefreshIdentifier: String {
        (Bundle.main.object(forInfoDictionaryKey: "DTBackgroundRefreshIdentifier") as? String)
            ?? "DiabTimer.refresh"
    }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
