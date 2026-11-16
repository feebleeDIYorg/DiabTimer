import Foundation
import Testing
@testable import TimerCore

struct TimerStatusTests {
    let change = Date(timeIntervalSince1970: 1_800_000_000)

    func status(hoursAfterChange hours: Double, kind: TimerKind = .cannula) -> TimerStatus {
        TimerStatus(
            kind: kind,
            lastChange: change,
            thresholds: .defaults(for: kind),
            now: change.addingTimeInterval(hours * 3600)
        )
    }

    @Test func levelsFollowThresholds() {
        #expect(status(hoursAfterChange: 10).level == .ok)
        #expect(status(hoursAfterChange: 44).level == .info)
        #expect(status(hoursAfterChange: 47.9).level == .info)
        #expect(status(hoursAfterChange: 48).level == .warn)
        #expect(status(hoursAfterChange: 72).level == .urgent)
        #expect(status(hoursAfterChange: 500).level == .urgent)
    }

    @Test func unknownChangeIsOk() {
        let status = TimerStatus(kind: .sensor, lastChange: nil, thresholds: .defaults(for: .sensor), now: change)
        #expect(status.level == .ok)
        #expect(status.age == nil)
        #expect(status.dueDate == nil)
        #expect(status.progress == 0)
    }

    @Test func dueDateAndTimeUntilDue() {
        let current = status(hoursAfterChange: 70)
        #expect(current.dueDate == change.addingTimeInterval(72 * 3600))
        #expect(current.timeUntilDue.map { $0.rounded() } == TimeInterval(7200))
        #expect(status(hoursAfterChange: 75).timeUntilDue.map { $0.rounded() } == TimeInterval(-10_800))
    }

    @Test func nextTransition() {
        let transition = status(hoursAfterChange: 45).nextTransition
        #expect(transition?.level == .warn)
        #expect(transition?.date == change.addingTimeInterval(48 * 3600))
        #expect(status(hoursAfterChange: 80).nextTransition == nil)
    }

    @Test func upcomingTransitionDates() {
        let dates = status(hoursAfterChange: 45).upcomingTransitionDates
        #expect(dates == [change.addingTimeInterval(48 * 3600), change.addingTimeInterval(72 * 3600)])
    }

    @Test func progressIsClamped() {
        #expect(status(hoursAfterChange: 36).progress == 0.5)
        #expect(status(hoursAfterChange: 100).progress == 1)
    }

    @Test func ageNeverNegative() {
        // Wechsel in der Zukunft eingetragen (z. B. falsche Uhr)
        #expect(status(hoursAfterChange: -1).age == 0)
    }

    @Test func defaultsMatchNightscoutPlugins() {
        #expect(Thresholds.defaults(for: .cannula) == Thresholds(infoHours: 44, warnHours: 48, urgentHours: 72))
        #expect(Thresholds.defaults(for: .sensor) == Thresholds(infoHours: 144, warnHours: 164, urgentHours: 166))
        #expect(Thresholds.defaults(for: .insulin) == Thresholds(infoHours: 44, warnHours: 48, urgentHours: 72))
        #expect(Thresholds.defaults(for: .battery) == Thresholds(infoHours: 312, warnHours: 336, urgentHours: 360))
        #expect(Thresholds.defaults(for: .tubing) == Thresholds(infoHours: 120, warnHours: 144, urgentHours: 168))
        for kind in TimerKind.allCases {
            #expect(Thresholds.defaults(for: kind).isValid)
        }
    }

    @Test func sensorThresholdsFromLifetime() {
        let tenDays = Thresholds.sensor(lifetimeHours: 240)
        #expect(tenDays == Thresholds(infoHours: 216, warnHours: 234, urgentHours: 238))
        #expect(tenDays.isValid)
    }

    @Test func averageWearDuration() {
        let events = [0.0, 72, 120, 192].map {
            ChangeEvent(kind: .cannula, date: change.addingTimeInterval($0 * 3600), isOwn: true)
        }
        // Abstände 72, 48, 72 h
        #expect(events.averageWearDuration().map { $0.rounded() } == TimeInterval(230_400))
        #expect([ChangeEvent]().averageWearDuration() == nil)
    }
}
