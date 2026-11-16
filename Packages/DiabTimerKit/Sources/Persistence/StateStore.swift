import Foundation

/// Liest und schreibt `AppState` als JSON-Datei.
///
/// App und Widget-Extension greifen auf dieselbe Datei im App-Group-Container zu. Auf
/// Apple-Plattformen schützt `NSFileCoordinator` vor gleichzeitigem Schreiben, zusätzlich
/// wird immer atomar geschrieben.
public final class StateStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Speicherort im App-Group-Container, sonst im Dokumentenordner (z. B. in Tests).
    public static func standard(appGroup: String?) -> StateStore {
        var directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #if canImport(Darwin)
        if let appGroup,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            directory = container
        }
        #endif
        return StateStore(fileURL: directory.appendingPathComponent("DiabTimerState.json"))
    }

    public func load() -> AppState {
        lock.lock()
        defer { lock.unlock() }
        var state = AppState()
        coordinate(writing: false) { url in
            state = Self.read(url)
        }
        return state
    }

    public func save(_ state: AppState) {
        lock.lock()
        defer { lock.unlock() }
        coordinate(writing: true) { url in
            Self.write(state, to: url)
        }
    }

    /// Liest, verändert und schreibt den Zustand in einem Schritt.
    @discardableResult
    public func update<T>(_ body: (inout AppState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        var result: T?
        coordinate(writing: true) { url in
            var state = Self.read(url)
            result = body(&state)
            Self.write(state, to: url)
        }
        guard let result else {
            var state = Self.read(fileURL)
            let value = body(&state)
            Self.write(state, to: fileURL)
            return value
        }
        return result
    }

    // MARK: - Datei

    private static func read(_ url: URL) -> AppState {
        guard let data = try? Data(contentsOf: url) else { return AppState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(AppState.self, from: data)) ?? AppState()
    }

    private static func write(_ state: AppState, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func coordinate(writing: Bool, _ body: (URL) -> Void) {
        #if canImport(Darwin)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        if writing {
            coordinator.coordinate(writingItemAt: fileURL, options: .forMerging, error: &error) { body($0) }
        } else {
            coordinator.coordinate(readingItemAt: fileURL, options: [], error: &error) { body($0) }
        }
        if error != nil {
            body(fileURL)
        }
        #else
        body(fileURL)
        #endif
    }
}
