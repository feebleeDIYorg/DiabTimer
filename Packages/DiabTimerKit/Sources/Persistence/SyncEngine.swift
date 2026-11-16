import Foundation
import NightscoutKit
import TimerCore

/// Gleicht den Zustand mit Nightscout ab: Warteschlange senden, Änderungen holen.
public struct SyncEngine: Sendable {
    public let api: NightscoutAPI

    public init(api: NightscoutAPI) {
        self.api = api
    }

    /// Ergebnis eines Abgleichs.
    public struct Report: Equatable, Sendable {
        /// Neu bekannt gewordene Kanülenwechsel aus anderen Apps.
        public var foreignCannulaChanges: [ChangeEvent] = []
        /// Hat sich an den Wechseln etwas geändert?
        public var changed = false
        public var error: String?

        public init() {}
    }

    // MARK: - Senden

    /// Sendet alle fälligen Aufträge. Fehler bleiben am Auftrag hängen und werden später wiederholt.
    @discardableResult
    public func flushOutbox(now: Date, state: inout AppState) async -> Report {
        var report = Report()
        let due = state.outbox.filter { $0.sendAfter <= now }
        for item in due {
            do {
                let identifier = try await send(item)
                state.outbox.removeAll { $0.id == item.id && $0.operation == item.operation }
                if let identifier {
                    replaceLocalID(item.id, with: identifier, kind: item.kind, state: &state)
                }
                report.changed = true
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                report.error = message
                if let index = state.outbox.firstIndex(where: { $0.id == item.id && $0.operation == item.operation }) {
                    state.outbox[index].attempts += 1
                    state.outbox[index].lastError = message
                    state.outbox[index].sendAfter = now.addingTimeInterval(Self.backoff(attempts: state.outbox[index].attempts))
                }
                if let nsError = error as? NightscoutError, nsError == .unauthorized || nsError == .forbidden {
                    break
                }
            }
        }
        return report
    }

    static func backoff(attempts: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(0, attempts - 1))), 30 * 60)
    }

    /// Führt einen Auftrag aus. Gibt bei `create` die vom Server vergebene `identifier` zurück.
    private func send(_ item: OutboxItem) async throws -> String? {
        switch item.operation {
        case .create(let treatment):
            // Bei einer Wiederholung erst nachsehen, ob der erste Versuch angekommen ist.
            if item.attempts > 0, let existing = try await api.findExisting(treatment) {
                return existing.identifier
            }
            return try await api.create(treatment).identifier
        case .patch(let identifier, let patch):
            try await api.patch(identifier: identifier, patch)
            return nil
        case .delete(let identifier):
            do {
                try await api.delete(identifier: identifier)
            } catch NightscoutError.notFound {
                // Schon weg: Ziel erreicht.
            }
            return nil
        }
    }

    private func replaceLocalID(_ localID: String, with identifier: String, kind: TimerKind, state: inout AppState) {
        guard localID != identifier else { return }
        if var events = state.events[kind], let index = events.firstIndex(where: { $0.id == localID }) {
            // Kam der Eintrag über den Abgleich schon herein, das lokale Duplikat entfernen.
            if events.contains(where: { $0.id == identifier }) {
                events.remove(at: index)
            } else {
                events[index].id = identifier
            }
            state.events[kind] = events
        }
        // Spätere Aufträge (Änderung, Löschung) auf die echte ID umstellen.
        for index in state.outbox.indices where state.outbox[index].id == localID {
            state.outbox[index].id = identifier
            switch state.outbox[index].operation {
            case .patch(_, let patch):
                state.outbox[index].operation = .patch(identifier: identifier, patch: patch)
            case .delete:
                state.outbox[index].operation = .delete(identifier: identifier)
            case .create:
                break
            }
        }
    }

    // MARK: - Holen

    /// Erstbefüllung: die letzten Wechsel je Timer.
    public func initialLoad(kinds: [TimerKind], now: Date, state: inout AppState) async throws {
        var newestModified: Int64 = state.lastModified ?? 0
        for kind in kinds where kind.isNightscoutBacked {
            let treatments = try await api.latestTreatments(for: kind, limit: AppState.maxEventsPerKind)
            for treatment in treatments {
                newestModified = max(newestModified, treatment.srvModified ?? 0)
            }
            let serverEvents = treatments.compactMap { $0.changeEvent() }
            let pending = (state.events[kind] ?? []).filter { state.isPending(eventID: $0.id) }
            state.events[kind] = Array((serverEvents + pending).sortedNewestFirst().prefix(AppState.maxEventsPerKind))
        }
        // Ohne srvModified (alte Einträge) mit „jetzt“ weitermachen, damit history nicht alles liefert.
        state.lastModified = newestModified > 0 ? newestModified : Int64(now.timeIntervalSince1970 * 1000)
        state.lastSync = now
        state.lastSyncError = nil
    }

    /// Holt alle Änderungen seit dem letzten Abgleich und wendet sie an.
    public func pullChanges(now: Date, state: inout AppState) async throws -> Report {
        guard let since = state.lastModified else {
            try await initialLoad(kinds: TimerKind.allCases, now: now, state: &state)
            var report = Report()
            report.changed = true
            return report
        }
        var report = Report()
        var cursor = since
        let pageSize = 500
        while true {
            let page = try await api.history(since: cursor, limit: pageSize)
            let pageReport = Self.apply(history: page, now: now, state: &state)
            report.changed = report.changed || pageReport.changed
            report.foreignCannulaChanges += pageReport.foreignCannulaChanges
            let maxModified = page.compactMap(\.srvModified).max() ?? cursor
            guard page.count >= pageSize, maxModified > cursor else { break }
            cursor = maxModified
        }
        state.lastSync = now
        state.lastSyncError = nil
        return report
    }

    /// Wendet Änderungen aus `history` an: neue und geänderte Einträge übernehmen,
    /// gelöschte (`isValid == false`) entfernen.
    @discardableResult
    static func apply(history: [NightscoutTreatment], now: Date, state: inout AppState) -> Report {
        var report = Report()
        for treatment in history {
            if let modified = treatment.srvModified {
                state.lastModified = max(state.lastModified ?? 0, modified)
            }
            guard let kind = treatment.kind else { continue }
            let existing = state.events[kind]?.first { $0.id == treatment.identifier }
            if !treatment.isValid {
                if existing != nil {
                    ChangeLog.removeEvent(id: treatment.identifier, kind: kind, in: &state)
                    report.changed = true
                }
                continue
            }
            guard let event = treatment.changeEvent() else { continue }
            if existing != event {
                // Eigenes, gerade gesendetes Ereignis mit lokaler ID nicht doppelt führen.
                if treatment.isOwn, let duplicate = state.events[kind]?.first(where: {
                    $0.id.hasPrefix("local-") && abs($0.date.timeIntervalSince(event.date)) < 0.002
                }), !state.isPending(eventID: duplicate.id) {
                    ChangeLog.removeEvent(id: duplicate.id, kind: kind, in: &state)
                }
                ChangeLog.insert(event, in: &state)
                report.changed = true
                if existing == nil, kind == .cannula, !event.isOwn,
                   now.timeIntervalSince(event.date) < 24 * 3600 {
                    report.foreignCannulaChanges.append(event)
                }
            }
        }
        return report
    }

    // MARK: - Server-Prüfung

    /// Liest Version und Rechte und speichert sie im Zustand.
    public func refreshServerInfo(state: inout AppState) async throws -> ServerStatus {
        let status = try await api.status()
        state.permissions = status.treatments
        state.serverVersion = status.version
        return status
    }
}

extension OutboxItem.Operation {
    public var label: String {
        switch self {
        case .create: "Eintragen"
        case .patch: "Ändern"
        case .delete: "Löschen"
        }
    }
}
