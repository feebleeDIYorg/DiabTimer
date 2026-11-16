import Foundation
import NightscoutKit
import Observation
import Persistence
import TimerCore
import WidgetKit

/// Zentrale Stelle für alle Änderungen und Abgleiche. Wird von App, Widget-Intents und
/// Benachrichtigungs-Aktionen gleichermaßen genutzt.
@MainActor
@Observable
final class ChangeService {
    static let shared = ChangeService()

    let store: StateStore
    private(set) var state: AppState
    private(set) var credentials: ServerCredentials?
    private(set) var isSyncing = false

    /// Nur die App darf den iCloud-Speicher nutzen (die Widget-Extension hat die Berechtigung nicht).
    var cloudSyncEnabled = false

    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?

    init(store: StateStore = .standard(appGroup: AppConfiguration.appGroupIdentifier)) {
        self.store = store
        self.state = store.load()
        self.credentials = CredentialStore.load()
    }

    var isConfigured: Bool { credentials != nil }

    /// Neu aus der Datei lesen (z. B. nachdem das Widget etwas eingetragen hat).
    func reload() {
        state = store.load()
        credentials = CredentialStore.load()
    }

    private func makeClient() -> NightscoutClient? {
        guard let credentials else { return nil }
        return NightscoutClient(baseURL: credentials.url, accessToken: credentials.token)
    }

    // MARK: - Eintragen

    /// Kombi-Vorschlag beim Antippen eines Timers: bei der Kanüle Schlauch und ggf. Insulin dazu.
    func suggestedKinds(for kind: TimerKind, at date: Date = Date()) -> Set<TimerKind> {
        var kinds: Set<TimerKind> = [kind]
        guard kind == .cannula else { return kinds }
        let enabled = state.settings.enabledTimers
        if enabled.contains(.tubing),
           state.settings.tubingPolicy.suggestsTubingChange(lastTubingChange: state.lastChange(for: .tubing), at: date) {
            kinds.insert(.tubing)
        }
        if enabled.contains(.insulin), state.settings.insulinWithCannula {
            kinds.insert(.insulin)
        }
        return kinds
    }

    /// Trägt einen Wechsel ein. Mit `sendDelay == nil` gilt die Wartezeit aus den Einstellungen
    /// (Rückgängig möglich), mit `0` wird sofort gesendet (Widget, Benachrichtigung).
    @discardableResult
    func record(kinds: Set<TimerKind>, at date: Date = Date(), note: String? = nil, sendDelay: TimeInterval? = nil) -> [String] {
        guard !kinds.isEmpty else { return [] }
        let now = Date()
        let recorded = store.update { state in
            ChangeLog.record(kinds: kinds, at: date, note: note, now: now, sendDelay: sendDelay, in: &state)
        }
        afterLocalChange()
        if kinds.contains(.tubing) { reconcileCloud() }
        scheduleSend()
        return recorded.eventIDs
    }

    /// Entfernt einen Eintrag (Rückgängig oder Löschen).
    /// - Returns: `false`, wenn das Token das Löschen nicht erlaubt.
    @discardableResult
    func remove(_ event: ChangeEvent) -> Bool {
        let now = Date()
        let removed = store.update { state in
            ChangeLog.remove(eventID: event.id, kind: event.kind, now: now, in: &state)
        }
        afterLocalChange()
        if event.kind == .tubing { reconcileCloud() }
        if removed { scheduleSend() }
        return removed
    }

    /// Macht mehrere noch nicht gesendete Einträge rückgängig.
    func undo(eventIDs: [String]) {
        let now = Date()
        store.update { state in
            for id in eventIDs {
                for kind in TimerKind.allCases where state.history(for: kind).contains(where: { $0.id == id }) {
                    ChangeLog.remove(eventID: id, kind: kind, now: now, in: &state)
                }
            }
        }
        afterLocalChange()
        reconcileCloud()
    }

    @discardableResult
    func edit(_ event: ChangeEvent, date: Date, note: String?) -> Bool {
        let now = Date()
        let edited = store.update { state in
            ChangeLog.edit(eventID: event.id, kind: event.kind, date: date, note: note, now: now, in: &state)
        }
        afterLocalChange()
        if event.kind == .tubing { reconcileCloud() }
        if edited { scheduleSend() }
        return edited
    }

    func snooze(_ kinds: [TimerKind], until date: Date) {
        store.update { state in
            for kind in kinds { state.snoozes[kind] = date }
        }
        afterLocalChange()
    }

    func updateSettings(_ body: (inout AppSettings) -> Void) {
        store.update { state in body(&state.settings) }
        afterLocalChange()
    }

    // MARK: - Widget-Bestätigung (zwei Tipps)

    func requestWidgetConfirmation(for kind: TimerKind, seconds: TimeInterval = 8) {
        store.update { state in
            state.widgetConfirmation = WidgetConfirmation(kind: kind, expiresAt: Date().addingTimeInterval(seconds))
        }
        reload()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func cancelWidgetConfirmation() {
        store.update { state in state.widgetConfirmation = nil }
        reload()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Zweiter Tipp im Widget: eintragen und sofort senden.
    func confirmFromWidget(kind: TimerKind) async {
        store.update { state in state.widgetConfirmation = nil }
        reload()
        record(kinds: suggestedKinds(for: kind), sendDelay: 0)
        await sync()
    }

    /// „Jetzt gewechselt“ aus einer Benachrichtigung.
    func recordFromNotification(kinds: [TimerKind]) async {
        reload()
        var selection = Set(kinds)
        if selection.contains(.cannula) {
            selection.formUnion(suggestedKinds(for: .cannula))
        }
        record(kinds: selection, sendDelay: 0)
        await sync()
    }

    // MARK: - Einrichtung

    /// Speichert die Zugangsdaten und Startwerte und lädt die Daten erstmals.
    func completeSetup(
        credentials: ServerCredentials,
        serverThresholds: [TimerKind: Thresholds],
        sensorLifetimeHours: Double?,
        lastTubingChange: Date?
    ) async throws {
        try CredentialStore.save(credentials)
        let now = Date()
        store.update { state in
            state.events = [:]
            state.outbox = []
            state.lastModified = nil
            state.permissions = nil
            for (kind, thresholds) in serverThresholds {
                state.settings.thresholds[kind] = thresholds
            }
            if serverThresholds[.sensor] == nil, let sensorLifetimeHours {
                state.settings.sensorLifetimeHours = sensorLifetimeHours
                state.settings.thresholds[.sensor] = .sensor(lifetimeHours: sensorLifetimeHours)
            }
            if let lastTubingChange, state.tubing.entries.isEmpty {
                ChangeLog.record(kinds: [.tubing], at: lastTubingChange, note: nil, now: now, in: &state)
            }
        }
        reload()
        reconcileCloud()
        await sync()
    }

    /// Server abmelden. Lokaler Nightscout-Bestand wird verworfen, der Schlauch bleibt.
    func signOut() async {
        CredentialStore.delete()
        store.update { state in
            state.events = [:]
            state.outbox = []
            state.lastModified = nil
            state.lastSync = nil
            state.lastSyncError = nil
            state.permissions = nil
            state.serverVersion = nil
        }
        reload()
        let state = self.state
        await ReminderScheduler.reschedule(state)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Übernimmt die Schwellen erneut vom Server.
    func refreshThresholdsFromServer() async throws -> Int {
        guard let client = makeClient() else { return 0 }
        let thresholds = try await client.serverThresholds()
        updateSettings { settings in
            for (kind, value) in thresholds { settings.thresholds[kind] = value }
        }
        return thresholds.count
    }

    // MARK: - Abgleich

    /// Sendet fällige Einträge und holt Änderungen. Gleichzeitige Aufrufe werden zusammengefasst.
    func sync() async {
        if let syncTask {
            await syncTask.value
            return
        }
        guard let client = makeClient() else { return }
        let task = Task { await self.performSync(client: client) }
        syncTask = task
        await task.value
        syncTask = nil
    }

    private func performSync(client: NightscoutClient) async {
        isSyncing = true
        defer { isSyncing = false }

        let base = store.load()
        var working = base
        let engine = SyncEngine(api: client)
        let now = Date()
        var report = SyncEngine.Report()
        do {
            if working.permissions == nil || working.lastSync.map({ now.timeIntervalSince($0) > 6 * 3600 }) ?? true {
                _ = try await engine.refreshServerInfo(state: &working)
            }
            let flush = await engine.flushOutbox(now: now, state: &working)
            report = try await engine.pullChanges(now: now, state: &working)
            working.lastSyncError = flush.error
        } catch {
            working.lastSyncError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        let synced = working
        store.update { current in
            current = StateMerge.merge(base: base, synced: synced, current: current)
        }
        reload()
        reconcileCloud()
        await askAboutTubing(for: report.foreignCannulaChanges)
        let state = self.state
        await ReminderScheduler.reschedule(state)
        WidgetCenter.shared.reloadAllTimelines()
        scheduleSend()
    }

    /// Gleicht den Schlauch mit iCloud ab (nur in der App).
    func reconcileCloud() {
        guard cloudSyncEnabled else { return }
        let sync = TubingCloudSync(store: NSUbiquitousKeyValueStore.default)
        let changed = store.update { state in sync.reconcile(state: &state) }
        if changed { afterLocalChange() } else { reload() }
    }

    /// Plant das Senden der nächsten wartenden Einträge.
    private func scheduleSend() {
        sendTask?.cancel()
        guard let next = state.outbox.map(\.sendAfter).min() else { return }
        let delay = max(0, next.timeIntervalSinceNow) + 0.5
        // Fehlgeschlagene Aufträge mit langem Backoff nicht im Vordergrund abwarten.
        guard delay < 10 * 60 else { return }
        sendTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    private func askAboutTubing(for changes: [ChangeEvent]) async {
        guard state.settings.enabledTimers.contains(.tubing), state.settings.tubingPolicy != .never else { return }
        for event in changes where !state.askedAboutTubingFor.contains(event.id) {
            let suggests = state.settings.tubingPolicy.suggestsTubingChange(
                lastTubingChange: state.lastChange(for: .tubing),
                at: event.date
            )
            store.update { state in
                state.askedAboutTubingFor.append(event.id)
                state.askedAboutTubingFor = Array(state.askedAboutTubingFor.suffix(50))
            }
            if suggests {
                await ReminderScheduler.askAboutTubing(after: event)
            }
        }
        reload()
    }

    private func afterLocalChange() {
        reload()
        let state = self.state
        Task { await ReminderScheduler.reschedule(state) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
