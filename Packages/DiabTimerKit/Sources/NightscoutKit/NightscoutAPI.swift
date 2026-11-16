import Foundation
import TimerCore

/// Die Aufrufe, die der Abgleich braucht. `NightscoutClient` erfüllt das Protokoll,
/// Tests verwenden eine Attrappe.
public protocol NightscoutAPI: Sendable {
    func status() async throws -> ServerStatus
    func latestTreatments(for kind: TimerKind, limit: Int) async throws -> [NightscoutTreatment]
    func history(since lastModified: Int64, limit: Int) async throws -> [NightscoutTreatment]
    func findExisting(_ treatment: NewTreatment) async throws -> NightscoutTreatment?
    func create(_ treatment: NewTreatment) async throws -> CreateResult
    func patch(identifier: String, _ patch: TreatmentPatch) async throws
    func delete(identifier: String) async throws
}

extension NightscoutClient: NightscoutAPI {}
