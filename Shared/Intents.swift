import AppIntents
import TimerCore
import WidgetKit

/// Timer als Auswahl für App Intents und Widget-Konfiguration.
enum TimerKindOption: String, AppEnum {
    case cannula
    case tubing
    case insulin
    case sensor
    case battery

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Teil")

    static let caseDisplayRepresentations: [TimerKindOption: DisplayRepresentation] = [
        .cannula: DisplayRepresentation(title: "Kanüle", image: .init(systemName: TimerKind.cannula.symbolName)),
        .tubing: DisplayRepresentation(title: "Schlauch", image: .init(systemName: TimerKind.tubing.symbolName)),
        .insulin: DisplayRepresentation(title: "Insulin", image: .init(systemName: TimerKind.insulin.symbolName)),
        .sensor: DisplayRepresentation(title: "Sensor", image: .init(systemName: TimerKind.sensor.symbolName)),
        .battery: DisplayRepresentation(title: "Batterie", image: .init(systemName: TimerKind.battery.symbolName)),
    ]

    var kind: TimerKind { TimerKind(rawValue: rawValue) ?? .cannula }

    init(_ kind: TimerKind) {
        self = TimerKindOption(rawValue: kind.rawValue) ?? .cannula
    }
}

/// Konfiguration des Einzel-Widgets: welcher Timer.
struct SelectTimerIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Timer auswählen"
    static let description = IntentDescription("Welcher Timer im Widget angezeigt wird.")

    @Parameter(title: "Teil", default: .cannula)
    var timer: TimerKindOption

    init() {}

    init(timer: TimerKindOption) {
        self.timer = timer
    }
}

/// Erster Tipp auf „Gewechselt“ im Widget: Button wird zur Rückfrage.
struct RequestChangeConfirmationIntent: AppIntent {
    static let title: LocalizedStringResource = "Wechsel vormerken"
    static let isDiscoverable = false

    @Parameter(title: "Teil")
    var timer: TimerKindOption

    init() {}

    init(timer: TimerKindOption) {
        self.timer = timer
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        ChangeService.shared.reload()
        ChangeService.shared.requestWidgetConfirmation(for: timer.kind)
        return .result()
    }
}

/// Zweiter Tipp: Wechsel eintragen und sofort senden.
struct ConfirmChangeIntent: AppIntent {
    static let title: LocalizedStringResource = "Wechsel eintragen"
    static let isDiscoverable = false

    @Parameter(title: "Teil")
    var timer: TimerKindOption

    init() {}

    init(timer: TimerKindOption) {
        self.timer = timer
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await ChangeService.shared.confirmFromWidget(kind: timer.kind)
        return .result()
    }
}

/// Rückfrage im Widget abbrechen.
struct CancelChangeConfirmationIntent: AppIntent {
    static let title: LocalizedStringResource = "Abbrechen"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        ChangeService.shared.cancelWidgetConfirmation()
        return .result()
    }
}
