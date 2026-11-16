import Foundation
import TimerCore

/// Schlüssel-Wert-Speicher in der Cloud. In der App ist das `NSUbiquitousKeyValueStore`,
/// in Tests ein Wörterbuch.
public protocol KeyValueCloudStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

/// Gleicht die Schlauchwechsel mit dem iCloud-Schlüssel-Wert-Speicher ab.
public struct TubingCloudSync {
    public static let key = "tubingLog.v1"

    public let store: KeyValueCloudStore

    public init(store: KeyValueCloudStore) {
        self.store = store
    }

    /// Stand in der Cloud, `nil` wenn leer oder unlesbar.
    public func remoteLog() -> TubingLog? {
        guard let data = store.data(forKey: Self.key) else { return nil }
        return try? Self.decoder.decode(TubingLog.self, from: data)
    }

    /// Führt lokalen und entfernten Stand zusammen, schreibt das Ergebnis in beide Richtungen.
    /// - Returns: `true`, wenn sich der lokale Stand geändert hat.
    @discardableResult
    public func reconcile(state: inout AppState) -> Bool {
        let remote = remoteLog() ?? TubingLog()
        let merged = state.tubing.merged(with: remote)
        let localChanged = merged != state.tubing
        state.tubing = merged
        if merged != remote, let data = try? Self.encoder.encode(merged) {
            store.set(data, forKey: Self.key)
            store.synchronize()
        }
        state.tubingNeedsUpload = false
        return localChanged
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

#if canImport(Darwin)
// `data(forKey:)`, `set(_:forKey:)` mit `Data?` und `synchronize()` gibt es dort bereits.
extension NSUbiquitousKeyValueStore: KeyValueCloudStore {}
#endif
