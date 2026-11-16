import BackgroundTasks
import Persistence
import SwiftUI
import TimerCore
import UIKit
import UserNotifications

@main
struct DiabTimerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                ChangeService.shared.reload()
                ChangeService.shared.reconcileCloud()
                Task { await ChangeService.shared.sync() }
            case .background:
                BackgroundSync.sendPendingBeforeSuspension()
                BackgroundSync.scheduleRefresh(for: ChangeService.shared.state)
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(AppConfiguration.backgroundRefreshIdentifier)) {
            await BackgroundSync.performRefresh()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ReminderScheduler.registerCategories()

        ChangeService.shared.cloudSyncEnabled = true
        NSUbiquitousKeyValueStore.default.synchronize()
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ChangeService.shared.reconcileCloud()
            }
        }
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let kinds = (userInfo[ReminderScheduler.kindsKey] as? [String] ?? []).compactMap(TimerKind.init(rawValue:))
        let changeDate = (userInfo[ReminderScheduler.dateKey] as? Double).map(Date.init(timeIntervalSince1970:))
        await NotificationActions.handle(action: action, kinds: kinds, changeDate: changeDate)
    }
}

/// Reaktionen auf Benachrichtigungs-Aktionen.
@MainActor
enum NotificationActions {
    static func handle(action: String, kinds: [TimerKind], changeDate: Date?) async {
        let service = ChangeService.shared
        service.reload()
        switch action {
        case ReminderScheduler.changedAction:
            await service.recordFromNotification(kinds: kinds)
        case ReminderScheduler.snoozeHourAction:
            service.snooze(kinds, until: Date().addingTimeInterval(3600))
        case ReminderScheduler.snoozeMorningAction:
            service.snooze(kinds, until: nextMorning(minuteOfDay: service.state.settings.reminders.overdueMinuteOfDay))
        case ReminderScheduler.tubingYesAction:
            service.record(kinds: [.tubing], at: changeDate ?? Date(), sendDelay: 0)
        default:
            break
        }
    }

    static func nextMorning(minuteOfDay: Int, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let today = calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: now) ?? now
        if today > now.addingTimeInterval(3600) { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)
    }
}

/// Hintergrund-Abgleich und Senden beim Wechsel in den Hintergrund.
@MainActor
enum BackgroundSync {
    private static var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Wartende Einträge sofort senden, solange iOS der App noch Zeit gibt.
    static func sendPendingBeforeSuspension() {
        let service = ChangeService.shared
        guard !service.state.outbox.isEmpty else { return }
        let now = Date()
        service.store.update { state in ChangeLog.sendPendingNow(now: now, in: &state) }
        service.reload()

        endBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "DiabTimer.send") {
            MainActor.assumeIsolated { endBackgroundTask() }
        }
        Task {
            await service.sync()
            endBackgroundTask()
        }
    }

    private static func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    static func performRefresh() async {
        let service = ChangeService.shared
        service.reload()
        await service.sync()
        scheduleRefresh(for: service.state)
    }

    /// Nächster Lauf kurz vor der nächsten Warn- oder Dringend-Schwelle, spätestens nach 4 Stunden.
    static func scheduleRefresh(for state: AppState, now: Date = Date()) {
        let upcoming = state.statuses(now: now)
            .flatMap { status in [status.date(for: .warn), status.date(for: .urgent)].compactMap { $0 } }
            .filter { $0 > now }
            .map { $0.addingTimeInterval(-30 * 60) }
            .min()
        let latest = now.addingTimeInterval(4 * 3600)
        let earliest = max(now.addingTimeInterval(15 * 60), min(upcoming ?? latest, latest))

        let request = BGAppRefreshTaskRequest(identifier: AppConfiguration.backgroundRefreshIdentifier)
        request.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(request)
    }
}
