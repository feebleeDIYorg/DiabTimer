import AppIntents
import Persistence
import SwiftUI
import TimerCore
import WidgetKit

@main
struct DiabTimerWidgetBundle: WidgetBundle {
    var body: some Widget {
        SingleTimerWidget()
        OverviewWidget()
    }
}

// MARK: - Timeline

struct TimerEntry: TimelineEntry, Sendable {
    let date: Date
    let state: AppState
    /// Timer, dessen „Gewechselt“-Button gerade auf Bestätigung wartet.
    let confirming: TimerKind?
    /// Im Einzel-Widget konfigurierter Timer.
    var kind: TimerKind = .cannula

    func status(_ kind: TimerKind) -> TimerStatus {
        state.status(for: kind, now: date)
    }

    static let placeholder: TimerEntry = {
        var state = AppState()
        let now = Date()
        state.events[.cannula] = [ChangeEvent(kind: .cannula, date: now.addingTimeInterval(-40 * 3600), isOwn: true)]
        state.events[.sensor] = [ChangeEvent(kind: .sensor, date: now.addingTimeInterval(-100 * 3600), isOwn: true)]
        state.events[.insulin] = [ChangeEvent(kind: .insulin, date: now.addingTimeInterval(-40 * 3600), isOwn: true)]
        state.events[.battery] = [ChangeEvent(kind: .battery, date: now.addingTimeInterval(-200 * 3600), isOwn: true)]
        state.tubing.add(ChangeEvent(kind: .tubing, date: now.addingTimeInterval(-90 * 3600), isOwn: true))
        return TimerEntry(date: now, state: state, confirming: nil)
    }()
}

enum TimelineFactory {
    static func loadState() -> AppState {
        StateStore.standard(appGroup: AppConfiguration.appGroupIdentifier).load()
    }

    /// Einträge jetzt, an jedem Stufenwechsel, stündlich für die nächsten 12 Stunden
    /// und am Ende einer laufenden Bestätigung.
    static func timeline(kinds: [TimerKind], selected: TimerKind = .cannula, now: Date = Date()) -> Timeline<TimerEntry> {
        let state = loadState()
        var dates: Set<Date> = [now]
        for kind in kinds {
            dates.formUnion(state.status(for: kind, now: now).upcomingTransitionDates.prefix(3))
        }
        for hour in 1...12 {
            dates.insert(now.addingTimeInterval(Double(hour) * 3600))
        }
        var confirmation: WidgetConfirmation?
        if let pending = state.widgetConfirmation, pending.expiresAt > now {
            confirmation = pending
            dates.insert(pending.expiresAt)
        }
        let entries = dates.sorted().prefix(40).map { date in
            TimerEntry(
                date: date,
                state: state,
                confirming: (confirmation.map { date < $0.expiresAt } ?? false) ? confirmation?.kind : nil,
                kind: selected
            )
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(12 * 3600)))
    }
}

// MARK: - Einzel-Widget

struct SingleTimerProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TimerEntry {
        .placeholder
    }

    func snapshot(for configuration: SelectTimerIntent, in context: Context) async -> TimerEntry {
        let kind = configuration.timer.kind
        var entry = context.isPreview ? TimerEntry.placeholder : TimerEntry(date: Date(), state: TimelineFactory.loadState(), confirming: nil)
        entry.kind = kind
        return entry
    }

    func timeline(for configuration: SelectTimerIntent, in context: Context) async -> Timeline<TimerEntry> {
        let kind = configuration.timer.kind
        return TimelineFactory.timeline(kinds: [kind], selected: kind)
    }
}

struct SingleTimerWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DiabTimer.single", intent: SelectTimerIntent.self, provider: SingleTimerProvider()) { entry in
            SingleTimerWidgetView(entry: entry)
        }
        .configurationDisplayName("Timer")
        .description("Alter eines Teils mit Button zum Eintragen des Wechsels.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct SingleTimerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TimerEntry

    var body: some View {
        TimerFamilyView(entry: entry, family: family)
    }
}

struct TimerFamilyView: View {
    let entry: TimerEntry
    let family: WidgetFamily

    var body: some View {
        let kind = entry.kind
        let status = entry.status(kind)
        switch family {
        case .accessoryCircular:
            CircularTimerView(status: status)
                .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label(kind.displayName, systemImage: kind.symbolName)
                    .font(.headline)
                Text(Formatting.ageText(status))
                    .font(.body.monospacedDigit())
                DueText(status: status)
                    .font(.caption)
            }
            .containerBackground(.clear, for: .widget)
        case .accessoryInline:
            Text("\(kind.displayName) \(Formatting.ageText(status))")
                .containerBackground(.clear, for: .widget)
        default:
            SmallTimerView(entry: entry, status: status)
                .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct SmallTimerView: View {
    let entry: TimerEntry
    let status: TimerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: status.kind.symbolName)
                    .foregroundStyle(status.level.color)
                Text(status.kind.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: status.level.symbolName)
                    .foregroundStyle(status.level.color)
            }
            Text(Formatting.ageText(status))
                .font(.title2.monospacedDigit().weight(.semibold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            DueText(status: status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            ChangeButtons(kind: status.kind, confirming: entry.confirming == status.kind)
        }
    }
}

/// „Gewechselt“ mit zwei Tipps: erst vormerken, dann bestätigen.
struct ChangeButtons: View {
    let kind: TimerKind
    let confirming: Bool

    var body: some View {
        if confirming {
            HStack(spacing: 6) {
                Button(intent: ConfirmChangeIntent(timer: TimerKindOption(kind))) {
                    Label("Wirklich", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                }
                .tint(.green)
                Button(intent: CancelChangeConfirmationIntent()) {
                    Image(systemName: "xmark")
                }
                .tint(.gray)
            }
            .font(.caption.weight(.semibold))
        } else {
            Button(intent: RequestChangeConfirmationIntent(timer: TimerKindOption(kind))) {
                Label("Gewechselt", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .font(.caption.weight(.semibold))
        }
    }
}

struct CircularTimerView: View {
    let status: TimerStatus

    var body: some View {
        if let lastChange = status.lastChange, let due = status.dueDate, due > lastChange {
            ProgressView(timerInterval: lastChange...due, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                Image(systemName: status.kind.symbolName)
            }
            .progressViewStyle(.circular)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: status.kind.symbolName)
            }
        }
    }
}

struct DueText: View {
    let status: TimerStatus

    var body: some View {
        if let due = status.dueDate {
            if due > status.now {
                Text("fällig \(due, style: .relative)")
            } else {
                Text("überfällig \(due, style: .relative)")
            }
        } else {
            Text("kein Wechsel bekannt")
        }
    }
}

// MARK: - Übersicht

/// Die Übersicht hat keine Einstellungen. Eine leere Konfiguration erlaubt die async-Variante
/// des Providers.
struct OverviewConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Alle Timer"
    static let description = IntentDescription("Zeigt alle aktiven Timer.")

    init() {}
}

struct OverviewProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TimerEntry {
        .placeholder
    }

    func snapshot(for configuration: OverviewConfigurationIntent, in context: Context) async -> TimerEntry {
        context.isPreview ? .placeholder : TimerEntry(date: Date(), state: TimelineFactory.loadState(), confirming: nil)
    }

    func timeline(for configuration: OverviewConfigurationIntent, in context: Context) async -> Timeline<TimerEntry> {
        let state = TimelineFactory.loadState()
        return TimelineFactory.timeline(kinds: state.settings.orderedEnabledTimers)
    }
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DiabTimer.overview", intent: OverviewConfigurationIntent.self, provider: OverviewProvider()) { entry in
            OverviewWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Alle Timer")
        .description("Alter aller aktiven Teile auf einen Blick.")
        .supportedFamilies([.systemMedium])
    }
}

struct OverviewWidgetView: View {
    let entry: TimerEntry

    var body: some View {
        let kinds = entry.state.settings.orderedEnabledTimers
        HStack(alignment: .top, spacing: 8) {
            ForEach(kinds, id: \.self) { kind in
                let status = entry.status(kind)
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(status.level.color.opacity(0.25), lineWidth: 5)
                        Circle()
                            .trim(from: 0, to: status.progress)
                            .stroke(status.level.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: kind.symbolName)
                            .font(.caption)
                            .foregroundStyle(status.level.color)
                    }
                    .frame(width: 40, height: 40)
                    Text(kind.displayName)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(Formatting.ageText(status))
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
