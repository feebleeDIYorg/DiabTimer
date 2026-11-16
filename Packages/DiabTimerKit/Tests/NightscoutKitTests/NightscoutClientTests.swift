import Foundation
import Testing
import TimerCore
@testable import NightscoutKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct NightscoutClientTests {
    let baseURL = URL(string: "https://ns.example.com")!
    /// Kurz nach `iat` aus jwt.json.
    let fixedNow = Date(timeIntervalSince1970: 1_794_810_000)

    func makeClient(_ transport: MockTransport) -> NightscoutClient {
        let now = fixedNow
        transport.on("/api/v2/authorization/request/diabtimer-abc123", fixture: "jwt")
        return NightscoutClient(baseURL: baseURL, accessToken: "diabtimer-abc123", transport: transport, now: { now })
    }

    @Test func statusReadsVersionAndPermissions() async throws {
        let transport = MockTransport()
        transport.on("/api/v3/status", fixture: "status-v3")
        let status = try await makeClient(transport).status()
        #expect(status.version == "15.0.9")
        #expect(status.majorVersion == 15)
        #expect(status.treatments == CollectionPermissions(create: true, read: true, update: true, delete: true))

        let statusRequest = transport.requests.last!
        #expect(statusRequest.value(forHTTPHeaderField: "Authorization") == "Bearer eyJ.test.jwt")
    }

    @Test func careportalOnlyPermissions() async throws {
        let transport = MockTransport()
        transport.on("/api/v3/status", fixture: "status-v3-careportal")
        let status = try await makeClient(transport).status()
        #expect(status.treatments.isSufficient)
        #expect(!status.treatments.update)
        #expect(!status.treatments.delete)
    }

    @Test func jwtIsReused() async throws {
        let transport = MockTransport()
        transport.on("/api/v3/status", fixture: "status-v3")
        let client = makeClient(transport)
        _ = try await client.status()
        _ = try await client.status()
        let authRequests = transport.requests.filter { $0.url!.path.contains("authorization/request") }
        #expect(authRequests.count == 1)
    }

    @Test func expiredJWTIsRefreshedOn401() async throws {
        let transport = MockTransport()
        transport.on("/api/v3/status", status: 401, body: Data("{}".utf8))
        let client = makeClient(transport)
        await #expect(throws: NightscoutError.unauthorized) {
            _ = try await client.status()
        }
        // Erster Versuch, neues JWT, zweiter Versuch.
        let authRequests = transport.requests.filter { $0.url!.path.contains("authorization/request") }
        #expect(authRequests.count == 2)
    }

    @Test func invalidTokenIsUnauthorized() async throws {
        let transport = MockTransport()
        transport.on("/api/v2/authorization/request/falsch", status: 401, body: Data("{}".utf8))
        let client = NightscoutClient(baseURL: baseURL, accessToken: "falsch", transport: transport)
        await #expect(throws: NightscoutError.unauthorized) {
            _ = try await client.status()
        }
    }

    @Test func forbiddenIsReported() async throws {
        let transport = MockTransport()
        transport.on("/api/v3/treatments/abc", method: "DELETE", status: 403, body: Data("{\"message\":\"Missing permission\"}".utf8))
        await #expect(throws: NightscoutError.forbidden) {
            try await makeClient(transport).delete(identifier: "abc")
        }
    }

    @Test func latestTreatmentsSkipBrokenEntries() async throws {
        let transport = MockTransport()
        transport.on("/api/v3/treatments", fixture: "treatments-site-change")
        let treatments = try await makeClient(transport).latestTreatments(for: .cannula)

        #expect(treatments.count == 2)
        #expect(treatments[0].isOwn)
        #expect(treatments[0].date == Date(timeIntervalSince1970: 1_794_817_800))
        #expect(treatments[1].isOwn == false)
        #expect(treatments[1].enteredBy == "Trio")
        #expect(treatments[1].date == NightscoutDate.parse("2026-11-13T19:05:00Z"))

        let query = transport.requests.last!.url!.query ?? ""
        #expect(query.contains("eventType$eq=Site%20Change"))
        #expect(query.contains("sort$desc=date"))
        #expect(query.contains("limit=20"))
    }

    @Test func sensorQueriesBothEventTypes() async throws {
        let transport = MockTransport()
        transport.on("/api/v3/treatments", body: Data("{\"status\":200,\"result\":[]}".utf8))
        _ = try await makeClient(transport).latestTreatments(for: .sensor)
        let query = transport.requests.last!.url!.query ?? ""
        #expect(query.contains("eventType$in=Sensor%20Start%7CSensor%20Change"))
    }

    @Test func tubingIsNeverQueried() async throws {
        let transport = MockTransport()
        let result = try await makeClient(transport).latestTreatments(for: .tubing)
        #expect(result.isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test func historyIncludesDeletedAndOtherEvents() async throws {
        let transport = MockTransport()
        transport.on("/api/v3/treatments/history/1794800000000", fixture: "history")
        let history = try await makeClient(transport).history(since: 1_794_800_000_000)

        #expect(history.map(\.identifier) == ["h-1", "h-2", "h-3", "h-4"])
        #expect(history[1].isValid == false)
        #expect(history[2].kind == nil)
        // Zahlen als Text werden toleriert.
        #expect(history[3].date == Date(timeIntervalSince1970: 1_794_815_000))
        #expect(history[3].srvModified == 1_794_817_300_000)
        #expect(history[0].changeEvent()?.kind == .sensor)
    }

    @Test func createSendsRequiredFields() async throws {
        let transport = MockTransport()
        transport.on("/api/v3/treatments", method: "POST", status: 201, fixture: "created")
        let date = Date(timeIntervalSince1970: 1_794_817_800.125)
        let treatment = NewTreatment(
            eventType: NightscoutEventType.siteChange,
            date: date,
            timeZone: TimeZone(identifier: "Europe/Zurich")!,
            notes: "Bauch rechts"
        )
        let result = try await makeClient(transport).create(treatment)
        #expect(result.identifier == "a1b2c3d4-0000-5000-8000-000000000009")

        let request = transport.requests.last!
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["eventType"] as? String == "Site Change")
        #expect(json["app"] as? String == "DiabTimer")
        #expect(json["device"] as? String == "DiabTimer")
        #expect(json["date"] as? Int == 1_794_817_800_125)
        #expect(json["utcOffset"] as? Int == 60)
        #expect(json["created_at"] as? String == "2026-11-16T08:30:00.125Z")
        #expect(json["notes"] as? String == "Bauch rechts")
    }

    @Test func emptyNotesAreOmitted() throws {
        let treatment = NewTreatment(eventType: "Site Change", date: fixedNow, notes: "")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(treatment)) as? [String: Any]
        #expect(json?["notes"] == nil)
    }

    @Test func patchAndDeleteUseIdentifier() async throws {
        let transport = MockTransport()
        transport.on("/api/v3/treatments/abc", method: "PATCH")
        transport.on("/api/v3/treatments/abc", method: "DELETE")
        let client = makeClient(transport)
        try await client.patch(identifier: "abc", TreatmentPatch(notes: "neu"))
        try await client.delete(identifier: "abc")
        let methods = transport.requests.compactMap(\.httpMethod).filter { $0 != "GET" }
        #expect(methods == ["PATCH", "DELETE"])
    }

    @Test func findExistingQueriesExactEntry() async throws {
        let transport = MockTransport()
        transport.on("/api/v3/treatments", fixture: "treatments-site-change")
        let treatment = NewTreatment(eventType: "Site Change", date: Date(timeIntervalSince1970: 1_794_817_800))
        let found = try await makeClient(transport).findExisting(treatment)
        #expect(found?.identifier == "a1b2c3d4-0000-5000-8000-000000000001")
        let query = transport.requests.last!.url!.query ?? ""
        #expect(query.contains("date$eq=1794817800000"))
        #expect(query.contains("device$eq=DiabTimer"))
    }

    @Test func serverThresholdsFromExtendedSettings() async throws {
        let transport = MockTransport()
        transport.on("/api/v1/status.json", fixture: "status-v1")
        let thresholds = try await makeClient(transport).serverThresholds()

        #expect(thresholds[.cannula] == Thresholds(infoHours: 40, warnHours: 46, urgentHours: 70))
        #expect(thresholds[.sensor] == Thresholds(infoHours: 216, warnHours: 234, urgentHours: 238))
        // Ohne Werte: nicht enthalten.
        #expect(thresholds[.insulin] == nil)
        // Ungültige Reihenfolge: verworfen.
        #expect(thresholds[.battery] == nil)
        #expect(transport.requests.last!.url!.query?.contains("token=diabtimer-abc123") == true)
    }

    @Test func normalizedURL() {
        #expect(NightscoutClient.normalizedURL(from: " ns.example.com/ ")?.absoluteString == "https://ns.example.com")
        #expect(NightscoutClient.normalizedURL(from: "http://10.0.0.2:1337")?.absoluteString == "http://10.0.0.2:1337")
        #expect(NightscoutClient.normalizedURL(from: "") == nil)
    }

    @Test func eventTypeMapping() {
        #expect(NightscoutEventType.kind(for: "Site Change") == .cannula)
        #expect(NightscoutEventType.kind(for: "Sensor Start") == .sensor)
        #expect(NightscoutEventType.kind(for: "Sensor Change") == .sensor)
        #expect(NightscoutEventType.kind(for: "Insulin Change") == .insulin)
        #expect(NightscoutEventType.kind(for: "Pump Battery Change") == .battery)
        #expect(NightscoutEventType.kind(for: "Meal Bolus") == nil)
        #expect(NightscoutEventType.eventTypeForNewEntry(.tubing) == nil)
    }
}
