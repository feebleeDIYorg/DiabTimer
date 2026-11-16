import Foundation
import NightscoutKit
import TimerCore
@testable import Persistence

/// Nightscout-Attrappe mit einstellbaren Antworten.
actor FakeAPI: NightscoutAPI {
    var serverStatus = ServerStatus(version: "15.0.9", apiVersion: "3", treatments: CollectionPermissions("crud"))
    var latest: [TimerKind: [NightscoutTreatment]] = [:]
    var historyPages: [[NightscoutTreatment]] = []
    var existing: NightscoutTreatment?
    var createError: NightscoutError?
    var deleteError: NightscoutError?

    private(set) var created: [NewTreatment] = []
    private(set) var patched: [(String, TreatmentPatch)] = []
    private(set) var deleted: [String] = []
    private(set) var findCalls = 0
    private(set) var historyCalls: [Int64] = []
    private var nextID = 1

    func set(createError: NightscoutError?) { self.createError = createError }
    func set(deleteError: NightscoutError?) { self.deleteError = deleteError }
    func set(existing: NightscoutTreatment?) { self.existing = existing }
    func set(latest: [NightscoutTreatment], for kind: TimerKind) { self.latest[kind] = latest }
    func set(historyPages: [[NightscoutTreatment]]) { self.historyPages = historyPages }

    func status() async throws -> ServerStatus { serverStatus }

    func latestTreatments(for kind: TimerKind, limit: Int) async throws -> [NightscoutTreatment] {
        latest[kind] ?? []
    }

    func history(since lastModified: Int64, limit: Int) async throws -> [NightscoutTreatment] {
        historyCalls.append(lastModified)
        return historyPages.isEmpty ? [] : historyPages.removeFirst()
    }

    func findExisting(_ treatment: NewTreatment) async throws -> NightscoutTreatment? {
        findCalls += 1
        return existing
    }

    func create(_ treatment: NewTreatment) async throws -> CreateResult {
        if let createError { throw createError }
        created.append(treatment)
        defer { nextID += 1 }
        return CreateResult(identifier: "srv-\(nextID)", lastModified: nil, isDeduplication: nil)
    }

    func patch(identifier: String, _ patch: TreatmentPatch) async throws {
        patched.append((identifier, patch))
    }

    func delete(identifier: String) async throws {
        if let deleteError { throw deleteError }
        deleted.append(identifier)
    }
}

final class MemoryCloudStore: KeyValueCloudStore {
    var values: [String: Data] = [:]
    var syncCount = 0

    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data?, forKey key: String) { values[key] = data }
    func synchronize() -> Bool {
        syncCount += 1
        return true
    }
}

func treatment(
    _ id: String,
    _ eventType: String,
    at date: Date,
    app: String? = "Trio",
    valid: Bool = true,
    modified: Int64? = nil
) -> NightscoutTreatment {
    NightscoutTreatment(
        identifier: id,
        eventType: eventType,
        date: date,
        app: app,
        isValid: valid,
        srvModified: modified
    )
}
