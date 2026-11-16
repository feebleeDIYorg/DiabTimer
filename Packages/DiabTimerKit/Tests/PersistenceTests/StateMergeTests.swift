import Foundation
import NightscoutKit
import Testing
import TimerCore
@testable import Persistence

struct StateMergeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func unchangedFileTakesSyncResult() {
        let base = AppState()
        var synced = base
        synced.lastSync = now
        #expect(StateMerge.merge(base: base, synced: synced, current: base) == synced)
    }

    @Test func entryRecordedDuringSyncSurvives() {
        let base = AppState()
        var synced = base
        ChangeLog.insert(ChangeEvent(id: "srv-9", kind: .sensor, date: now, isOwn: false), in: &synced)
        synced.lastModified = 99

        var current = base
        ChangeLog.record(kinds: [.cannula, .tubing], at: now, note: nil, now: now, in: &current)

        let merged = StateMerge.merge(base: base, synced: synced, current: current)
        #expect(merged.lastChange(for: .sensor) == now)
        #expect(merged.lastChange(for: .cannula) == now)
        #expect(merged.lastChange(for: .tubing) == now)
        #expect(merged.outbox.count == 1)
        #expect(merged.tubingNeedsUpload)
        #expect(merged.lastModified == 99)
    }

    @Test func undoDuringSyncWins() {
        var base = AppState()
        let recorded = ChangeLog.record(kinds: [.insulin], at: now, note: nil, now: now, in: &base)
        // Der Abgleich hat den Auftrag noch nicht gesendet (noch nicht fällig).
        let synced = base
        var current = base
        ChangeLog.remove(eventID: recorded.eventIDs[0], kind: .insulin, now: now, in: &current)

        let merged = StateMerge.merge(base: base, synced: synced, current: current)
        #expect(merged.outbox.isEmpty)
        #expect(merged.history(for: .insulin).isEmpty)
    }

    @Test func settingsComeFromCurrent() {
        let base = AppState()
        var synced = base
        synced.permissions = CollectionPermissions("cr")
        var current = base
        current.settings.insulinWithCannula = true
        current.snoozes[.cannula] = now

        let merged = StateMerge.merge(base: base, synced: synced, current: current)
        #expect(merged.settings.insulinWithCannula)
        #expect(merged.snoozes[.cannula] == now)
        #expect(merged.permissions == CollectionPermissions("cr"))
    }
}
