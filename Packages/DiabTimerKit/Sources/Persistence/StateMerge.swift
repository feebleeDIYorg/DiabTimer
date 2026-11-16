import Foundation
import TimerCore

/// Dreiwege-Zusammenführung für einen Abgleich, der mit einer Kopie des Zustands arbeitet.
///
/// Während der Netzwerkaufrufe kann der Zustand in der Datei verändert werden (Eintrag in der
/// App, Widget, Benachrichtigung). `merge` übernimmt das Ergebnis des Abgleichs und spielt alle
/// Änderungen, die seit `base` dazugekommen sind, wieder ein.
public enum StateMerge {
    /// - Parameters:
    ///   - base: Stand beim Beginn des Abgleichs.
    ///   - synced: Ergebnis des Abgleichs (aus `base` entstanden).
    ///   - current: Stand in der Datei beim Ende des Abgleichs.
    public static func merge(base: AppState, synced: AppState, current: AppState) -> AppState {
        if current == base { return synced }
        var result = synced

        // Wechsel je Timer.
        for kind in TimerKind.allCases where kind.isNightscoutBacked {
            let baseEvents = base.events[kind] ?? []
            let currentEvents = current.events[kind] ?? []
            let baseByID = Dictionary(baseEvents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let currentIDs = Set(currentEvents.map(\.id))

            for event in currentEvents where baseByID[event.id] != event {
                ChangeLog.insert(event, in: &result)
            }
            for event in baseEvents where !currentIDs.contains(event.id) {
                ChangeLog.removeEvent(id: event.id, kind: kind, in: &result)
            }
        }

        // Warteschlange.
        let added = current.outbox.filter { !base.outbox.contains($0) }
        let removed = base.outbox.filter { !current.outbox.contains($0) }
        result.outbox.removeAll { item in removed.contains { $0.id == item.id && $0.operation == item.operation } }
        for item in added where !result.outbox.contains(item) {
            result.outbox.append(item)
        }

        // Schlauch: Vereinigung über IDs, Löschungen gewinnen.
        result.tubing = synced.tubing.merged(with: current.tubing)
        if current.tubing != base.tubing {
            result.tubingNeedsUpload = true
        }

        // Was nur lokal geändert wird, kommt aus `current`.
        result.settings = current.settings
        result.snoozes = current.snoozes
        result.widgetConfirmation = current.widgetConfirmation
        result.askedAboutTubingFor = Array(Set(synced.askedAboutTubingFor).union(current.askedAboutTubingFor)).sorted()
        return result
    }
}
