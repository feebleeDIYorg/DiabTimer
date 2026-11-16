import Foundation
import Testing
import TimerCore
@testable import Persistence

struct StorageTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func temporaryStore() -> StateStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiabTimerTests-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        return StateStore(fileURL: url)
    }

    @Test func missingFileGivesDefaultState() {
        #expect(temporaryStore().load() == AppState())
    }

    @Test func roundTrip() {
        let store = temporaryStore()
        var state = AppState()
        ChangeLog.record(kinds: [.cannula, .tubing], at: now, note: "x", now: now, in: &state)
        state.settings.thresholds[.sensor] = .sensor(lifetimeHours: 240)
        state.settings.tubingPolicy = .always
        state.snoozes[.battery] = now
        store.save(state)
        #expect(store.load() == state)
    }

    @Test func updateReadsModifiesAndWrites() {
        let store = temporaryStore()
        let count = store.update { state -> Int in
            ChangeLog.record(kinds: [.insulin], at: now, note: nil, now: now, in: &state)
            return state.outbox.count
        }
        #expect(count == 1)
        #expect(store.load().lastChange(for: .insulin) == now)
    }

    @Test func corruptFileGivesDefaultState() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kein json".utf8).write(to: store.fileURL)
        #expect(store.load() == AppState())
    }

    @Test func olderFilesWithMissingFieldsStillLoad() throws {
        let json = #"{"settings":{"insulinWithCannula":true},"lastModified":42}"#
        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        #expect(state.settings.insulinWithCannula)
        #expect(state.settings.sendDelay == 15)
        #expect(state.settings.tubingPolicy == .standard)
        #expect(state.lastModified == 42)
        #expect(state.outbox.isEmpty)
    }

    @Test func cloudSyncMergesBothWays() {
        let cloud = MemoryCloudStore()
        let sync = TubingCloudSync(store: cloud)

        // Gerät A trägt ein und lädt hoch.
        var deviceA = AppState()
        ChangeLog.record(kinds: [.tubing], at: now, note: nil, now: now, in: &deviceA)
        sync.reconcile(state: &deviceA)
        #expect(!deviceA.tubingNeedsUpload)
        #expect(sync.remoteLog()?.entries.count == 1)

        // Gerät B hat offline einen eigenen Eintrag und erhält den von A.
        var deviceB = AppState()
        ChangeLog.record(kinds: [.tubing], at: now.addingTimeInterval(3600), note: nil, now: now, in: &deviceB)
        let changed = sync.reconcile(state: &deviceB)
        #expect(changed)
        #expect(deviceB.tubing.entries.count == 2)
        #expect(sync.remoteLog()?.entries.count == 2)

        // A bekommt den Eintrag von B.
        sync.reconcile(state: &deviceA)
        #expect(deviceA.tubing == deviceB.tubing)
    }

    @Test func cloudSyncWithoutChangesDoesNotWrite() {
        let cloud = MemoryCloudStore()
        let sync = TubingCloudSync(store: cloud)
        var state = AppState()
        sync.reconcile(state: &state)
        #expect(cloud.syncCount == 0)
    }
}
