import Foundation
import NightscoutKit
import TimerCore

/// Lokale Änderungen am Zustand: Eintragen, Rückgängig, Korrigieren, Löschen.
/// Alles ist reine Logik auf `AppState`, ohne Netzwerk.
public enum ChangeLog {
    /// Ergebnis von `record`: die neuen Ereignisse (für „Rückgängig“).
    public struct Recorded: Equatable, Sendable {
        public var events: [ChangeEvent]
        public var eventIDs: [String] { events.map(\.id) }
    }

    /// Trägt einen Wechsel für mehrere Teile mit gemeinsamem Zeitpunkt ein.
    ///
    /// Nightscout-Teile landen sofort im Bestand und mit `sendAfter = now + sendDelay` in der
    /// Warteschlange. Der Schlauch landet im `TubingLog` und wird von der App nach iCloud geschrieben.
    @discardableResult
    public static func record(
        kinds: Set<TimerKind>,
        at date: Date,
        note: String?,
        now: Date,
        sendDelay: TimeInterval? = nil,
        timeZone: TimeZone = .current,
        in state: inout AppState
    ) -> Recorded {
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote
        let delay = sendDelay ?? state.settings.sendDelay
        var recorded: [ChangeEvent] = []

        for kind in kinds.sorted() {
            if kind == .tubing {
                let event = ChangeEvent(kind: .tubing, date: date, note: cleanNote, source: DiabTimerIdentity.app, isOwn: true, updatedAt: now)
                state.tubing.add(event)
                state.tubingNeedsUpload = true
                recorded.append(event)
                continue
            }
            guard let eventType = NightscoutEventType.eventTypeForNewEntry(kind) else { continue }
            let treatment = NewTreatment(eventType: eventType, date: date, timeZone: timeZone, notes: cleanNote)
            // Lokale ID, bis der Server die echte `identifier` liefert.
            let localID = "local-" + UUID().uuidString
            let event = ChangeEvent(
                id: localID,
                kind: kind,
                date: Date(timeIntervalSince1970: Double(treatment.date) / 1000),
                note: cleanNote,
                source: DiabTimerIdentity.app,
                isOwn: true,
                updatedAt: now
            )
            insert(event, in: &state)
            state.outbox.append(OutboxItem(id: localID, kind: kind, operation: .create(treatment), sendAfter: now.addingTimeInterval(delay)))
            recorded.append(event)
        }

        // Ein neuer Wechsel beendet das Schlummern dieses Timers.
        for kind in kinds {
            state.snoozes[kind] = nil
        }
        return Recorded(events: recorded)
    }

    /// Macht einen Eintrag rückgängig.
    ///
    /// - Noch nicht gesendet: Ereignis und Auftrag verschwinden spurlos.
    /// - Schon gesendet: lokal entfernen und Löschauftrag einreihen (braucht das Recht `delete`).
    /// - Returns: `false`, wenn der Eintrag schon gesendet ist und das Token nicht löschen darf.
    @discardableResult
    public static func remove(eventID: String, kind: TimerKind, now: Date, in state: inout AppState) -> Bool {
        if kind == .tubing {
            state.tubing.delete(id: eventID)
            state.tubingNeedsUpload = true
            return true
        }
        if let index = state.outbox.firstIndex(where: { $0.id == eventID && $0.isCreate }) {
            state.outbox.remove(at: index)
            state.outbox.removeAll { $0.id == eventID }
            removeEvent(id: eventID, kind: kind, in: &state)
            return true
        }
        if let permissions = state.permissions, !permissions.delete {
            return false
        }
        guard let event = state.events[kind]?.first(where: { $0.id == eventID }), event.isOwn else {
            return false
        }
        removeEvent(id: eventID, kind: kind, in: &state)
        state.outbox.removeAll { $0.id == eventID }
        state.outbox.append(OutboxItem(id: eventID, kind: kind, operation: .delete(identifier: eventID), sendAfter: now))
        return true
    }

    /// Ändert Zeitpunkt oder Notiz eines eigenen Eintrags.
    /// - Returns: `false`, wenn der Eintrag gesendet ist und das Token nicht ändern darf.
    @discardableResult
    public static func edit(
        eventID: String,
        kind: TimerKind,
        date: Date,
        note: String?,
        now: Date,
        timeZone: TimeZone = .current,
        in state: inout AppState
    ) -> Bool {
        let cleanNote = (note?.isEmpty ?? true) ? nil : note
        if kind == .tubing {
            guard var event = state.tubing.entries.first(where: { $0.id == eventID }) else { return false }
            event.date = date
            event.note = cleanNote
            event.updatedAt = now
            state.tubing.update(event)
            state.tubingNeedsUpload = true
            return true
        }
        guard var event = state.events[kind]?.first(where: { $0.id == eventID }), event.isOwn else {
            return false
        }
        if let index = state.outbox.firstIndex(where: { $0.id == eventID && $0.isCreate }),
           case .create(let old) = state.outbox[index].operation {
            let treatment = NewTreatment(eventType: old.eventType, date: date, timeZone: timeZone, notes: cleanNote)
            state.outbox[index].operation = .create(treatment)
        } else {
            if let permissions = state.permissions, !permissions.update {
                return false
            }
            let patch = TreatmentPatch(date: date, timeZone: timeZone, notes: cleanNote ?? "")
            state.outbox.removeAll { $0.id == eventID && !$0.isCreate }
            state.outbox.append(OutboxItem(id: eventID, kind: kind, operation: .patch(identifier: eventID, patch: patch), sendAfter: now))
        }
        event.date = date
        event.note = cleanNote
        event.updatedAt = now
        removeEvent(id: eventID, kind: kind, in: &state)
        insert(event, in: &state)
        return true
    }

    /// Sendet alle wartenden Einträge sofort (z. B. wenn die App in den Hintergrund geht).
    public static func sendPendingNow(now: Date, in state: inout AppState) {
        for index in state.outbox.indices where state.outbox[index].sendAfter > now {
            state.outbox[index].sendAfter = now
        }
    }

    // MARK: - Hilfen

    static func insert(_ event: ChangeEvent, in state: inout AppState) {
        var list = state.events[event.kind] ?? []
        list.removeAll { $0.id == event.id }
        list.append(event)
        state.events[event.kind] = Array(list.sortedNewestFirst().prefix(AppState.maxEventsPerKind))
    }

    static func removeEvent(id: String, kind: TimerKind, in state: inout AppState) {
        state.events[kind]?.removeAll { $0.id == id }
    }
}
