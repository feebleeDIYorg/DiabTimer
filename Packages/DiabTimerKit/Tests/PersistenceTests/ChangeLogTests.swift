import Foundation
import NightscoutKit
import Testing
import TimerCore
@testable import Persistence

struct ChangeLogTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let zurich = TimeZone(identifier: "Europe/Zurich")!

    @Test func recordCreatesEventsAndDelayedOutbox() {
        var state = AppState()
        state.snoozes[.cannula] = now.addingTimeInterval(3600)
        let recorded = ChangeLog.record(
            kinds: [.cannula, .tubing, .insulin],
            at: now,
            note: "  Bauch  ",
            now: now,
            timeZone: zurich,
            in: &state
        )

        #expect(recorded.events.count == 3)
        #expect(state.lastChange(for: .cannula) == now)
        #expect(state.lastChange(for: .insulin) == now)
        #expect(state.lastChange(for: .tubing) == now)
        #expect(state.tubingNeedsUpload)
        #expect(state.snoozes[.cannula] == nil)

        // Schlauch kommt nie in die Warteschlange.
        #expect(state.outbox.map(\.kind) == [.cannula, .insulin])
        #expect(state.outbox.allSatisfy { $0.sendAfter == now.addingTimeInterval(15) })
        guard case .create(let treatment) = state.outbox[0].operation else {
            Issue.record("kein create")
            return
        }
        #expect(treatment.eventType == "Site Change")
        #expect(treatment.notes == "Bauch")
        #expect(treatment.utcOffset == 60)
        #expect(state.history(for: .cannula).first?.note == "Bauch")
        #expect(state.isPending(eventID: state.outbox[0].id))
    }

    @Test func undoPendingLeavesNothing() {
        var state = AppState()
        let recorded = ChangeLog.record(kinds: [.cannula], at: now, note: nil, now: now, in: &state)
        let removed = ChangeLog.remove(eventID: recorded.eventIDs[0], kind: .cannula, now: now, in: &state)
        #expect(removed)
        #expect(state.outbox.isEmpty)
        #expect(state.history(for: .cannula).isEmpty)
    }

    @Test func removingSentEntryNeedsDeletePermission() {
        var state = AppState()
        state.permissions = CollectionPermissions("cr")
        ChangeLog.insert(ChangeEvent(id: "srv-1", kind: .cannula, date: now, isOwn: true), in: &state)

        #expect(!ChangeLog.remove(eventID: "srv-1", kind: .cannula, now: now, in: &state))
        #expect(state.history(for: .cannula).count == 1)

        state.permissions = CollectionPermissions("crud")
        #expect(ChangeLog.remove(eventID: "srv-1", kind: .cannula, now: now, in: &state))
        #expect(state.history(for: .cannula).isEmpty)
        #expect(state.outbox.first?.operation == .delete(identifier: "srv-1"))
    }

    @Test func foreignEntriesCannotBeRemoved() {
        var state = AppState()
        state.permissions = CollectionPermissions("crud")
        ChangeLog.insert(ChangeEvent(id: "trio-1", kind: .cannula, date: now, source: "Trio", isOwn: false), in: &state)
        #expect(!ChangeLog.remove(eventID: "trio-1", kind: .cannula, now: now, in: &state))
    }

    @Test func editPendingChangesPayload() {
        var state = AppState()
        let recorded = ChangeLog.record(kinds: [.sensor], at: now, note: nil, now: now, in: &state)
        let earlier = now.addingTimeInterval(-1800)
        #expect(ChangeLog.edit(eventID: recorded.eventIDs[0], kind: .sensor, date: earlier, note: "G7", now: now, in: &state))

        #expect(state.outbox.count == 1)
        guard case .create(let treatment) = state.outbox[0].operation else {
            Issue.record("kein create")
            return
        }
        #expect(treatment.date == Int64(earlier.timeIntervalSince1970 * 1000))
        #expect(treatment.notes == "G7")
        #expect(state.lastChange(for: .sensor) == earlier)
    }

    @Test func editSentEntryQueuesPatch() {
        var state = AppState()
        state.permissions = CollectionPermissions("cru")
        ChangeLog.insert(ChangeEvent(id: "srv-1", kind: .insulin, date: now, isOwn: true), in: &state)
        #expect(ChangeLog.edit(eventID: "srv-1", kind: .insulin, date: now, note: "Fiasp", now: now, in: &state))
        guard case .patch(let identifier, let patch) = state.outbox.first?.operation else {
            Issue.record("kein patch")
            return
        }
        #expect(identifier == "srv-1")
        #expect(patch.notes == "Fiasp")
    }

    @Test func tubingUndoUsesTubingLog() {
        var state = AppState()
        let recorded = ChangeLog.record(kinds: [.tubing], at: now, note: nil, now: now, in: &state)
        state.tubingNeedsUpload = false
        #expect(ChangeLog.remove(eventID: recorded.eventIDs[0], kind: .tubing, now: now, in: &state))
        #expect(state.tubing.entries.isEmpty)
        #expect(state.tubing.deletedIDs == recorded.eventIDs)
        #expect(state.tubingNeedsUpload)
    }

    @Test func sendPendingNow() {
        var state = AppState()
        ChangeLog.record(kinds: [.cannula, .battery], at: now, note: nil, now: now, in: &state)
        ChangeLog.sendPendingNow(now: now, in: &state)
        #expect(state.outbox.allSatisfy { $0.sendAfter == now })
    }

    @Test func eventsAreCappedPerKind() {
        var state = AppState()
        for index in 0..<30 {
            ChangeLog.insert(ChangeEvent(id: "e\(index)", kind: .cannula, date: now.addingTimeInterval(Double(index)), isOwn: false), in: &state)
        }
        #expect(state.history(for: .cannula).count == AppState.maxEventsPerKind)
        #expect(state.history(for: .cannula).first?.id == "e29")
    }

    @Test func reminderInputsFollowSettings() {
        var state = AppState()
        state.settings.enabledTimers = [.cannula, .tubing]
        state.settings.enabledLevels[.tubing] = [.urgent]
        state.snoozes[.cannula] = now
        let inputs = state.reminderInputs()
        #expect(inputs.map(\.kind) == [.cannula, .tubing])
        #expect(inputs[1].enabledLevels == [.urgent])
        #expect(inputs[0].snoozedUntil == now)
    }
}
