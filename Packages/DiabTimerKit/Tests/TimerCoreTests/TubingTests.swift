import Foundation
import Testing
@testable import TimerCore

struct TubingTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ id: String, hours: Double, updated: Double? = nil) -> ChangeEvent {
        ChangeEvent(
            id: id,
            kind: .tubing,
            date: base.addingTimeInterval(hours * 3600),
            isOwn: true,
            updatedAt: updated.map { base.addingTimeInterval($0 * 3600) }
        )
    }

    @Test func policyOlderThan() {
        let policy = TubingPolicy.standard
        #expect(policy.suggestsTubingChange(lastTubingChange: nil, at: base))
        #expect(!policy.suggestsTubingChange(lastTubingChange: base, at: base.addingTimeInterval(72 * 3600)))
        #expect(policy.suggestsTubingChange(lastTubingChange: base, at: base.addingTimeInterval(96 * 3600)))
    }

    @Test func policyAlwaysAndNever() {
        #expect(TubingPolicy.always.suggestsTubingChange(lastTubingChange: base, at: base))
        #expect(!TubingPolicy.never.suggestsTubingChange(lastTubingChange: nil, at: base))
    }

    @Test func policyIsCodable() throws {
        let data = try JSONEncoder().encode(TubingPolicy.olderThan(hours: 48))
        #expect(try JSONDecoder().decode(TubingPolicy.self, from: data) == .olderThan(hours: 48))
    }

    @Test func addKeepsNewestFirstAndCaps() {
        var log = TubingLog()
        for index in 0..<25 {
            log.add(event("e\(index)", hours: Double(index)))
        }
        #expect(log.entries.count == TubingLog.maxEntries)
        #expect(log.latest?.id == "e24")
        #expect(log.entries.last?.id == "e5")
    }

    @Test func mergeIsUnion() {
        var deviceA = TubingLog()
        deviceA.add(event("a", hours: 0))
        var deviceB = TubingLog()
        deviceB.add(event("b", hours: 1))

        let merged = deviceA.merged(with: deviceB)
        #expect(merged.entries.map(\.id) == ["b", "a"])
        #expect(merged == deviceB.merged(with: deviceA))
    }

    @Test func mergeRespectsDeletion() {
        var deviceA = TubingLog()
        deviceA.add(event("a", hours: 0))
        deviceA.add(event("b", hours: 1))
        var deviceB = deviceA
        deviceB.delete(id: "b")

        let merged = deviceA.merged(with: deviceB)
        #expect(merged.entries.map(\.id) == ["a"])
        #expect(merged.deletedIDs == ["b"])
        // Ein später wieder auftauchender Stand bringt den gelöschten Eintrag nicht zurück.
        #expect(merged.merged(with: deviceA).entries.map(\.id) == ["a"])
    }

    @Test func mergePrefersNewerUpdate() {
        var deviceA = TubingLog()
        deviceA.add(event("a", hours: 0, updated: 1))
        var deviceB = TubingLog()
        var corrected = event("a", hours: -2, updated: 5)
        corrected.note = "korrigiert"
        deviceB.add(corrected)

        let merged = deviceA.merged(with: deviceB)
        #expect(merged.entries.count == 1)
        #expect(merged.latest?.note == "korrigiert")
        #expect(deviceB.merged(with: deviceA).latest?.note == "korrigiert")
    }

    @Test func addForcesTubingKind() {
        var log = TubingLog()
        log.add(ChangeEvent(id: "x", kind: .cannula, date: base, isOwn: true))
        #expect(log.latest?.kind == .tubing)
    }
}
