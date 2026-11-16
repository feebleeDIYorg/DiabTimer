import Foundation
import Testing
@testable import TimerCore

struct ReminderPlannerTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    var planner: ReminderPlanner { ReminderPlanner(calendar: calendar) }

    /// 2027-01-04 (Montag) zur angegebenen Uhrzeit in UTC.
    func date(day: Int = 4, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: 1, day: day, hour: hour, minute: minute))!
    }

    let noQuiet = ReminderSettings(quietHours: QuietHours(isEnabled: false), overdueRepeatCount: 0)

    @Test func plansOnlyFutureThresholds() {
        // Kanüle vor 46 h gewechselt: Info (44 h) liegt in der Vergangenheit.
        let now = date(hour: 12)
        let input = TimerReminderInput(
            kind: .cannula,
            lastChange: now.addingTimeInterval(-46 * 3600),
            thresholds: .defaults(for: .cannula)
        )
        let plan = planner.plan(inputs: [input], settings: noQuiet, now: now)
        #expect(plan.map(\.level) == [.warn, .urgent])
        #expect(plan.first?.date == now.addingTimeInterval(2 * 3600))
    }

    @Test func overdueThresholdsAfterSetupProduceNoImmediateReminder() {
        let now = date(hour: 12)
        let input = TimerReminderInput(
            kind: .cannula,
            lastChange: now.addingTimeInterval(-100 * 3600),
            thresholds: .defaults(for: .cannula)
        )
        let plan = planner.plan(inputs: [input], settings: noQuiet, now: now)
        #expect(plan.isEmpty)
    }

    @Test func disabledLevelsAreSkipped() {
        let now = date(hour: 12)
        let input = TimerReminderInput(
            kind: .cannula,
            lastChange: now,
            thresholds: .defaults(for: .cannula),
            enabledLevels: [.urgent]
        )
        let plan = planner.plan(inputs: [input], settings: noQuiet, now: now)
        #expect(plan.map(\.level) == [.urgent])
    }

    @Test func remindersWithinWindowAreBundled() {
        let now = date(hour: 0)
        let cannula = TimerReminderInput(kind: .cannula, lastChange: now, thresholds: .defaults(for: .cannula))
        let insulin = TimerReminderInput(
            kind: .insulin,
            lastChange: now.addingTimeInterval(20 * 60),
            thresholds: .defaults(for: .insulin)
        )
        let plan = planner.plan(inputs: [cannula, insulin], settings: noQuiet, now: now)
        #expect(plan.count == 3)
        #expect(plan.allSatisfy { $0.kinds == [.cannula, .insulin] })
        #expect(plan.last?.level == .urgent)
        // Die gebündelte Erinnerung kommt zum frühesten Zeitpunkt.
        #expect(plan.first?.date == now.addingTimeInterval(44 * 3600))
    }

    @Test func remindersOutsideWindowAreSeparate() {
        let now = date(hour: 0)
        let cannula = TimerReminderInput(kind: .cannula, lastChange: now, thresholds: .defaults(for: .cannula))
        let insulin = TimerReminderInput(
            kind: .insulin,
            lastChange: now.addingTimeInterval(2 * 3600),
            thresholds: .defaults(for: .insulin)
        )
        let plan = planner.plan(inputs: [cannula, insulin], settings: noQuiet, now: now)
        #expect(plan.count == 6)
    }

    @Test func overdueRepeatsDaily() {
        let now = date(hour: 12)
        // Dringend wird um 13:00 erreicht.
        let input = TimerReminderInput(
            kind: .sensor,
            lastChange: now.addingTimeInterval(-165 * 3600),
            thresholds: .defaults(for: .sensor)
        )
        var settings = noQuiet
        settings.overdueRepeatCount = 3
        let plan = planner.plan(inputs: [input], settings: settings, now: now)
        let overdue = plan.filter { $0.items.contains { $0.isOverdue } }
        // Frühestens 12 h nach „dringend“ (01:00 am 5.), also erstmals am 5. um 09:00.
        #expect(overdue.map(\.date) == [date(day: 5, hour: 9), date(day: 6, hour: 9), date(day: 7, hour: 9)])
    }

    @Test func overdueContinuesWhenAlreadyOverdue() {
        let now = date(hour: 12)
        let input = TimerReminderInput(
            kind: .cannula,
            lastChange: now.addingTimeInterval(-200 * 3600),
            thresholds: .defaults(for: .cannula)
        )
        var settings = noQuiet
        settings.overdueRepeatCount = 2
        let plan = planner.plan(inputs: [input], settings: settings, now: now)
        #expect(plan.map(\.date) == [date(day: 5, hour: 9), date(day: 6, hour: 9)])
        #expect(plan.allSatisfy { $0.level == .urgent })
    }

    @Test func snoozeSuppressesUntilThenRemindsOnce() {
        let now = date(hour: 12)
        // Warnung in 1 h, dringend in 25 h.
        let input = TimerReminderInput(
            kind: .cannula,
            lastChange: now.addingTimeInterval(-47 * 3600),
            thresholds: .defaults(for: .cannula),
            snoozedUntil: now.addingTimeInterval(3 * 3600)
        )
        let plan = planner.plan(inputs: [input], settings: noQuiet, now: now)
        #expect(plan.map(\.date) == [now.addingTimeInterval(3 * 3600), now.addingTimeInterval(25 * 3600)])
        #expect(plan.first?.level == .warn)
    }

    @Test func expiredSnoozeIsIgnored() {
        let now = date(hour: 12)
        let input = TimerReminderInput(
            kind: .cannula,
            lastChange: now.addingTimeInterval(-47 * 3600),
            thresholds: .defaults(for: .cannula),
            snoozedUntil: now.addingTimeInterval(-60)
        )
        let plan = planner.plan(inputs: [input], settings: noQuiet, now: now)
        #expect(plan.first?.date == now.addingTimeInterval(3600))
    }

    @Test func quietHoursMoveInfoToEnd() {
        let settings = ReminderSettings(overdueRepeatCount: 0)
        let now = date(hour: 0)
        // Info um 23:00, also in der Ruhezeit 22–7.
        let input = TimerReminderInput(
            kind: .cannula,
            lastChange: date(hour: 23).addingTimeInterval(-44 * 3600),
            thresholds: .defaults(for: .cannula),
            enabledLevels: [.info]
        )
        let plan = planner.plan(inputs: [input], settings: settings, now: now)
        #expect(plan.map(\.date) == [date(day: 5, hour: 7)])
    }

    @Test func quietHoursPullUrgentBeforeStart() {
        let settings = ReminderSettings(overdueRepeatCount: 0)
        let now = date(hour: 0)
        // Dringend am 5. um 03:00 → vorgezogen auf den 4. um 21:30.
        let input = TimerReminderInput(
            kind: .cannula,
            lastChange: date(day: 5, hour: 3).addingTimeInterval(-72 * 3600),
            thresholds: .defaults(for: .cannula),
            enabledLevels: [.urgent]
        )
        let plan = planner.plan(inputs: [input], settings: settings, now: now)
        #expect(plan.map(\.date) == [date(hour: 21, minute: 30)])
    }

    @Test func urgentInQuietHoursFallsBackToEndWhenTooLate() {
        let settings = ReminderSettings(overdueRepeatCount: 0)
        let now = date(hour: 23)
        // Dringend um 23:30, Vorziehen auf 21:30 liegt schon in der Vergangenheit.
        let input = TimerReminderInput(
            kind: .cannula,
            lastChange: date(hour: 23, minute: 30).addingTimeInterval(-72 * 3600),
            thresholds: .defaults(for: .cannula),
            enabledLevels: [.urgent]
        )
        let plan = planner.plan(inputs: [input], settings: settings, now: now)
        #expect(plan.map(\.date) == [date(day: 5, hour: 7)])
    }

    @Test func quietHoursWithinSameDay() {
        let quiet = QuietHours(isEnabled: true, startMinute: 13 * 60, endMinute: 14 * 60)
        #expect(quiet.contains(minuteOfDay: 13 * 60 + 30))
        #expect(!quiet.contains(minuteOfDay: 14 * 60))
        #expect(!quiet.contains(minuteOfDay: 12 * 60))
        let overnight = QuietHours()
        #expect(overnight.contains(minuteOfDay: 23 * 60))
        #expect(overnight.contains(minuteOfDay: 6 * 60 + 59))
        #expect(!overnight.contains(minuteOfDay: 7 * 60))
        #expect(!QuietHours(isEnabled: false).contains(minuteOfDay: 23 * 60))
    }

    @Test func respectsMaximum() {
        var settings = noQuiet
        settings.maxReminders = 2
        settings.bundleWindow = 0
        let now = date(hour: 0)
        let input = TimerReminderInput(kind: .cannula, lastChange: now, thresholds: .defaults(for: .cannula))
        #expect(planner.plan(inputs: [input], settings: settings, now: now).count == 2)
    }

    @Test func unknownChangeHasNoReminders() {
        let input = TimerReminderInput(kind: .battery, lastChange: nil, thresholds: .defaults(for: .battery))
        #expect(planner.plan(inputs: [input], settings: noQuiet, now: date(hour: 0)).isEmpty)
    }

    @Test func idsAreStable() {
        let now = date(hour: 0)
        let input = TimerReminderInput(kind: .cannula, lastChange: now, thresholds: .defaults(for: .cannula))
        let first = planner.plan(inputs: [input], settings: noQuiet, now: now)
        let second = planner.plan(inputs: [input], settings: noQuiet, now: now.addingTimeInterval(60))
        #expect(first.map(\.id) == second.map(\.id))
    }
}
