import Foundation
import Persistence
import TimerCore
import UserNotifications

/// Plant die Erinnerungen als lokale Benachrichtigungen. Der Plan selbst kommt aus
/// `ReminderPlanner` (TimerCore), hier wird er nur in `UNNotificationRequest`s übersetzt.
enum ReminderScheduler {
    static let reminderCategory = "DT_REMINDER"
    static let tubingCategory = "DT_TUBING"

    static let changedAction = "DT_CHANGED"
    static let snoozeHourAction = "DT_SNOOZE_1H"
    static let snoozeMorningAction = "DT_SNOOZE_MORNING"
    static let tubingYesAction = "DT_TUBING_YES"
    static let tubingNoAction = "DT_TUBING_NO"

    static let kindsKey = "kinds"
    static let dateKey = "date"
    private static let reminderPrefix = "dt-"

    static func registerCategories() {
        let changed = UNNotificationAction(identifier: changedAction, title: "Jetzt gewechselt", options: [])
        let snoozeHour = UNNotificationAction(identifier: snoozeHourAction, title: "In 1 Std. erinnern", options: [])
        let snoozeMorning = UNNotificationAction(identifier: snoozeMorningAction, title: "Morgen früh erinnern", options: [])
        let reminder = UNNotificationCategory(
            identifier: reminderCategory,
            actions: [changed, snoozeHour, snoozeMorning],
            intentIdentifiers: [],
            options: []
        )
        let yes = UNNotificationAction(identifier: tubingYesAction, title: "Ja, Schlauch auch", options: [])
        let no = UNNotificationAction(identifier: tubingNoAction, title: "Nein", options: [])
        let tubing = UNNotificationCategory(identifier: tubingCategory, actions: [yes, no], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([reminder, tubing])
    }

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Ersetzt alle geplanten Erinnerungen durch den aktuellen Plan.
    static func reschedule(_ state: AppState, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let plan = ReminderPlanner().plan(
            inputs: state.reminderInputs(),
            settings: state.settings.reminders,
            now: now
        )
        let pending = await center.pendingNotificationRequests()
        let oldIDs = pending.map(\.identifier).filter { $0.hasPrefix(reminderPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: oldIDs)

        for reminder in plan {
            let content = UNMutableNotificationContent()
            content.title = title(for: reminder)
            content.body = body(for: reminder, state: state)
            content.sound = .default
            // „Zeitkritisch“ bräuchte die Capability Time Sensitive Notifications, die sich über die
            // App-Store-Connect-API nicht aktivieren lässt. Ohne sie stellt iOS die Mitteilung normal zu.
            content.interruptionLevel = reminder.level >= .warn ? .timeSensitive : .active
            content.categoryIdentifier = reminderCategory
            content.threadIdentifier = "reminders"
            content.userInfo = [kindsKey: reminder.kinds.map(\.rawValue)]
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, reminder.date.timeIntervalSince(now)),
                repeats: false
            )
            let request = UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    /// Fragt nach einem Kanülenwechsel aus einer anderen App, ob der Schlauch mitgewechselt wurde.
    static func askAboutTubing(after event: ChangeEvent) async {
        let content = UNMutableNotificationContent()
        let source = event.source.map { " (\($0))" } ?? ""
        content.title = "Kanüle wurde gewechselt\(source)"
        content.body = "Schlauch auch gewechselt? Lange drücken, um zu antworten."
        content.sound = .default
        content.categoryIdentifier = tubingCategory
        content.userInfo = [dateKey: event.date.timeIntervalSince1970]
        let request = UNNotificationRequest(identifier: "tubing-\(event.id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Texte

    static func title(for reminder: PlannedReminder) -> String {
        let names = reminder.items.map(\.kind.displayName)
        let list = ListFormatter.localizedString(byJoining: names)
        if reminder.items.contains(where: \.isOverdue) {
            return "\(list) überfällig"
        }
        switch reminder.level {
        case .urgent: return "\(list) jetzt wechseln"
        case .warn: return "\(list) bald fällig"
        default: return "\(list): Wechsel vorbereiten"
        }
    }

    static func body(for reminder: PlannedReminder, state: AppState) -> String {
        var lines: [String] = []
        for item in reminder.items {
            guard let lastChange = state.lastChange(for: item.kind) else { continue }
            let age = reminder.date.timeIntervalSince(lastChange)
            lines.append("\(item.kind.displayName): seit \(Formatting.duration(age)) in Gebrauch")
        }
        if let lastSync = state.lastSync {
            lines.append("Zuletzt abgeglichen: \(Formatting.dateTime(lastSync))")
        }
        return lines.joined(separator: "\n")
    }
}
