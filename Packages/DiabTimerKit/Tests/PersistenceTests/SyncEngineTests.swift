import Foundation
import NightscoutKit
import Testing
import TimerCore
@testable import Persistence

struct SyncEngineTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func flushSendsOnlyDueItemsAndReplacesLocalID() async {
        let api = FakeAPI()
        let engine = SyncEngine(api: api)
        var state = AppState()
        let recorded = ChangeLog.record(kinds: [.cannula], at: now, note: nil, now: now, in: &state)

        // Innerhalb der 15 Sekunden passiert nichts.
        await engine.flushOutbox(now: now.addingTimeInterval(5), state: &state)
        #expect(await api.created.isEmpty)
        #expect(state.outbox.count == 1)

        let report = await engine.flushOutbox(now: now.addingTimeInterval(16), state: &state)
        #expect(report.changed)
        #expect(await api.created.count == 1)
        #expect(state.outbox.isEmpty)
        #expect(state.history(for: .cannula).map(\.id) == ["srv-1"])
        #expect(!state.history(for: .cannula).contains { $0.id == recorded.eventIDs[0] })
    }

    @Test func failedSendIsRetriedWithBackoffAndDeduplicated() async {
        let api = FakeAPI()
        await api.set(createError: .http(status: 500, message: "boom"))
        let engine = SyncEngine(api: api)
        var state = AppState()
        ChangeLog.record(kinds: [.cannula], at: now, note: nil, now: now, sendDelay: 0, in: &state)

        let report = await engine.flushOutbox(now: now, state: &state)
        #expect(report.error != nil)
        #expect(state.outbox.first?.attempts == 1)
        #expect(state.outbox.first?.sendAfter == now.addingTimeInterval(30))

        // Der erste Versuch ist doch angekommen: kein zweiter Eintrag.
        await api.set(createError: nil)
        await api.set(existing: treatment("srv-x", "Site Change", at: now, app: "DiabTimer"))
        await engine.flushOutbox(now: now.addingTimeInterval(31), state: &state)
        #expect(await api.findCalls == 1)
        #expect(await api.created.isEmpty)
        #expect(state.outbox.isEmpty)
        #expect(state.history(for: .cannula).map(\.id) == ["srv-x"])
    }

    @Test func unauthorizedStopsFlush() async {
        let api = FakeAPI()
        await api.set(createError: .unauthorized)
        let engine = SyncEngine(api: api)
        var state = AppState()
        ChangeLog.record(kinds: [.cannula, .insulin], at: now, note: nil, now: now, sendDelay: 0, in: &state)
        await engine.flushOutbox(now: now, state: &state)
        #expect(state.outbox.map(\.attempts) == [1, 0])
    }

    @Test func deleteOfMissingEntryCountsAsDone() async {
        let api = FakeAPI()
        await api.set(deleteError: .notFound)
        let engine = SyncEngine(api: api)
        var state = AppState()
        state.outbox = [OutboxItem(id: "srv-1", kind: .cannula, operation: .delete(identifier: "srv-1"), sendAfter: now)]
        await engine.flushOutbox(now: now, state: &state)
        #expect(state.outbox.isEmpty)
    }

    @Test func backoffGrowsAndIsCapped() {
        #expect(SyncEngine.backoff(attempts: 1) == 30)
        #expect(SyncEngine.backoff(attempts: 2) == 60)
        #expect(SyncEngine.backoff(attempts: 20) == 1800)
    }

    @Test func initialLoadKeepsPendingEntries() async throws {
        let api = FakeAPI()
        await api.set(latest: [
            treatment("a", "Site Change", at: now.addingTimeInterval(-7200), modified: 1_799_000_000_000),
            treatment("b", "Site Change", at: now.addingTimeInterval(-90000), modified: 1_798_000_000_000),
        ], for: .cannula)
        let engine = SyncEngine(api: api)
        var state = AppState()
        ChangeLog.record(kinds: [.cannula], at: now, note: nil, now: now, in: &state)

        try await engine.initialLoad(kinds: [.cannula, .tubing], now: now, state: &state)
        #expect(state.history(for: .cannula).count == 3)
        #expect(state.lastChange(for: .cannula) == now)
        #expect(state.lastModified == 1_799_000_000_000)
        #expect(state.lastSync == now)
    }

    @Test func pullAppliesHistory() async throws {
        let api = FakeAPI()
        let engine = SyncEngine(api: api)
        var state = AppState()
        state.lastModified = 1_000
        ChangeLog.insert(ChangeEvent(id: "old", kind: .cannula, date: now.addingTimeInterval(-200_000), isOwn: false), in: &state)
        ChangeLog.insert(ChangeEvent(id: "gone", kind: .cannula, date: now.addingTimeInterval(-3600), isOwn: false), in: &state)

        await api.set(historyPages: [[
            treatment("gone", "Site Change", at: now.addingTimeInterval(-3600), valid: false, modified: 2_000),
            treatment("new", "Site Change", at: now.addingTimeInterval(-600), app: "AAPS", modified: 3_000),
            treatment("meal", "Meal Bolus", at: now, modified: 4_000),
            treatment("sensor", "Sensor Start", at: now.addingTimeInterval(-60), app: "xDrip4iOS", modified: 5_000),
        ]])

        let report = try await engine.pullChanges(now: now, state: &state)
        #expect(report.changed)
        #expect(state.history(for: .cannula).map(\.id) == ["new", "old"])
        #expect(state.lastChange(for: .sensor) == now.addingTimeInterval(-60))
        #expect(state.lastModified == 5_000)
        #expect(report.foreignCannulaChanges.map(\.id) == ["new"])
        #expect(await api.historyCalls == [1_000])
    }

    @Test func deletingNewestFallsBackToPrevious() {
        var state = AppState()
        ChangeLog.insert(ChangeEvent(id: "a", kind: .insulin, date: now.addingTimeInterval(-100_000), isOwn: false), in: &state)
        ChangeLog.insert(ChangeEvent(id: "b", kind: .insulin, date: now, isOwn: false), in: &state)
        SyncEngine.apply(history: [treatment("b", "Insulin Change", at: now, valid: false)], now: now, state: &state)
        #expect(state.lastChange(for: .insulin) == now.addingTimeInterval(-100_000))
    }

    @Test func ownEntriesAreNotReportedAsForeign() {
        var state = AppState()
        let report = SyncEngine.apply(history: [
            treatment("x", "Site Change", at: now, app: "DiabTimer"),
            treatment("y", "Site Change", at: now.addingTimeInterval(-30 * 3600), app: "Trio"),
        ], now: now, state: &state)
        // Eigener Eintrag nicht, zu alter fremder Eintrag auch nicht.
        #expect(report.foreignCannulaChanges.isEmpty)
        #expect(state.history(for: .cannula).count == 2)
    }

    @Test func refreshServerInfoStoresPermissions() async throws {
        let engine = SyncEngine(api: FakeAPI())
        var state = AppState()
        _ = try await engine.refreshServerInfo(state: &state)
        #expect(state.permissions == CollectionPermissions("crud"))
        #expect(state.serverVersion == "15.0.9")
    }
}
