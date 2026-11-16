import NightscoutKit
import Persistence
import SwiftUI
import TimerCore

struct SettingsView: View {
    private var service = ChangeService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var thresholdMessage: String?
    @State private var confirmSignOut = false

    var body: some View {
        let state = service.state
        NavigationStack {
            Form {
                serverSection(state)

                Section("Timer") {
                    ForEach(TimerKind.allCases, id: \.self) { kind in
                        NavigationLink {
                            TimerSettingsView(kind: kind)
                        } label: {
                            HStack {
                                Label(kind.displayName, systemImage: kind.symbolName)
                                Spacer()
                                Text(state.settings.enabledTimers.contains(kind) ? "an" : "aus")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Schwellen vom Server übernehmen") {
                        Task {
                            do {
                                let count = try await service.refreshThresholdsFromServer()
                                thresholdMessage = count == 0 ? "Der Server hat keine eigenen Schwellen." : "\(count) Timer übernommen."
                            } catch {
                                thresholdMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                            }
                        }
                    }
                    if let thresholdMessage {
                        Text(thresholdMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("Schlauch mitwechseln", selection: tubingPolicyMode) {
                        Text("ab Alter").tag(0)
                        Text("immer").tag(1)
                        Text("nie").tag(2)
                    }
                    if case .olderThan(let hours) = state.settings.tubingPolicy {
                        Stepper("ab \(Formatting.duration(hours * 3600))", value: tubingHours, in: 12...240, step: 12)
                    }
                    Toggle("Insulin mit der Kanüle wechseln", isOn: Binding(
                        get: { state.settings.insulinWithCannula },
                        set: { value in service.updateSettings { $0.insulinWithCannula = value } }
                    ))
                } header: {
                    Text("Wechsel eintragen")
                } footer: {
                    Text("Legt fest, ob beim Kanülenwechsel Schlauch und Insulin vorausgewählt sind.")
                }

                Section {
                    Toggle("Ruhezeit", isOn: Binding(
                        get: { state.settings.reminders.quietHours.isEnabled },
                        set: { value in service.updateSettings { $0.reminders.quietHours.isEnabled = value } }
                    ))
                    if state.settings.reminders.quietHours.isEnabled {
                        DatePicker("Beginn", selection: minuteBinding(\.reminders.quietHours.startMinute), displayedComponents: .hourAndMinute)
                        DatePicker("Ende", selection: minuteBinding(\.reminders.quietHours.endMinute), displayedComponents: .hourAndMinute)
                    }
                    DatePicker("Überfällig-Erinnerung", selection: minuteBinding(\.reminders.overdueMinuteOfDay), displayedComponents: .hourAndMinute)
                } header: {
                    Text("Erinnerungen")
                } footer: {
                    Text("In der Ruhezeit kommen Info und Warnung erst an ihrem Ende. „Dringend“ kommt 30 Minuten vor ihrem Beginn. Überfällige Wechsel werden täglich zur gewählten Uhrzeit erinnert.")
                }

                Section("iCloud") {
                    LabeledContent("Schlauch-Abgleich", value: FileManager.default.ubiquityIdentityToken == nil ? "iCloud nicht verfügbar" : "aktiv")
                }

                Section {
                    LabeledContent("Version", value: AppConfiguration.appVersion)
                    Text("DiabTimer ist kein Medizinprodukt. Keine Dosisberechnung, keine BZ-Alarme.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .confirmationDialog("Vom Server abmelden?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Abmelden", role: .destructive) {
                    Task {
                        await service.signOut()
                        dismiss()
                    }
                }
            } message: {
                Text("Der lokale Nightscout-Bestand wird gelöscht. Die Schlauchwechsel in iCloud bleiben erhalten.")
            }
        }
    }

    private func serverSection(_ state: AppState) -> some View {
        Section("Nightscout") {
            if let credentials = service.credentials {
                LabeledContent("Server", value: credentials.url.host ?? credentials.url.absoluteString)
            }
            if let version = state.serverVersion {
                LabeledContent("Version", value: version)
            }
            if let permissions = state.permissions {
                LabeledContent("Rechte", value: permissionText(permissions))
                if !permissions.update || !permissions.delete {
                    Text("Ohne die Rechte update und delete lassen sich gesendete Einträge nicht korrigieren oder löschen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Jetzt abgleichen") {
                Task { await service.sync() }
            }
            Button("Abmelden", role: .destructive) {
                confirmSignOut = true
            }
        }
    }

    private func permissionText(_ permissions: CollectionPermissions) -> String {
        var parts: [String] = []
        if permissions.read { parts.append("lesen") }
        if permissions.create { parts.append("anlegen") }
        if permissions.update { parts.append("ändern") }
        if permissions.delete { parts.append("löschen") }
        return parts.isEmpty ? "keine" : parts.joined(separator: ", ")
    }

    private var tubingPolicyMode: Binding<Int> {
        Binding(
            get: {
                switch service.state.settings.tubingPolicy {
                case .olderThan: 0
                case .always: 1
                case .never: 2
                }
            },
            set: { mode in
                service.updateSettings { settings in
                    switch mode {
                    case 1: settings.tubingPolicy = .always
                    case 2: settings.tubingPolicy = .never
                    default: settings.tubingPolicy = .standard
                    }
                }
            }
        )
    }

    private var tubingHours: Binding<Double> {
        Binding(
            get: {
                if case .olderThan(let hours) = service.state.settings.tubingPolicy { return hours }
                return 96
            },
            set: { hours in service.updateSettings { $0.tubingPolicy = .olderThan(hours: hours) } }
        )
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: { Formatting.date(fromMinuteOfDay: service.state.settings[keyPath: keyPath]) },
            set: { date in
                let minute = Formatting.minuteOfDay(from: date)
                service.updateSettings { $0[keyPath: keyPath] = minute }
            }
        )
    }
}

/// Einstellungen eines Timers: an/aus, Schwellen, Erinnerungsstufen.
struct TimerSettingsView: View {
    let kind: TimerKind
    private var service = ChangeService.shared

    init(kind: TimerKind) {
        self.kind = kind
    }

    var body: some View {
        let settings = service.state.settings
        let thresholds = settings.thresholds(for: kind)
        Form {
            Section {
                Toggle("Anzeigen und erinnern", isOn: Binding(
                    get: { settings.enabledTimers.contains(kind) },
                    set: { isOn in
                        service.updateSettings { settings in
                            if isOn { settings.enabledTimers.insert(kind) } else { settings.enabledTimers.remove(kind) }
                        }
                    }
                ))
            }

            if kind == .sensor {
                Section("Laufzeit") {
                    Picker("Sensor", selection: Binding(
                        get: { settings.sensorLifetimeHours ?? 0 },
                        set: { hours in
                            guard hours > 0 else { return }
                            service.updateSettings { settings in
                                settings.sensorLifetimeHours = hours
                                settings.thresholds[.sensor] = .sensor(lifetimeHours: hours)
                            }
                        }
                    )) {
                        Text("eigene Schwellen").tag(0.0)
                        ForEach(Thresholds.sensorLifetimeSuggestions, id: \.self) { hours in
                            Text(Formatting.duration(hours * 3600)).tag(hours)
                        }
                    }
                }
            }

            Section {
                thresholdStepper("Info", value: thresholds.info, keyPath: \.info)
                thresholdStepper("Warnung", value: thresholds.warn, keyPath: \.warn)
                thresholdStepper("Dringend", value: thresholds.urgent, keyPath: \.urgent)
                Button("Standardwerte") {
                    service.updateSettings { settings in
                        settings.thresholds[kind] = nil
                        if kind == .sensor { settings.sensorLifetimeHours = nil }
                    }
                }
            } header: {
                Text("Schwellen (Zeit seit dem Wechsel)")
            } footer: {
                if !thresholds.isValid {
                    Text("Die Schwellen müssen aufsteigen: Info ≤ Warnung ≤ Dringend.")
                        .foregroundStyle(.red)
                }
            }

            Section("Erinnerungen") {
                ForEach([TimerLevel.info, .warn, .urgent], id: \.self) { level in
                    Toggle(level.displayName, isOn: Binding(
                        get: { settings.levels(for: kind).contains(level) },
                        set: { isOn in
                            service.updateSettings { settings in
                                var levels = settings.levels(for: kind)
                                if isOn { levels.insert(level) } else { levels.remove(level) }
                                settings.enabledLevels[kind] = levels
                            }
                        }
                    ))
                }
            }
        }
        .navigationTitle(kind.displayName)
    }

    private func thresholdStepper(_ title: String, value: TimeInterval, keyPath: WritableKeyPath<Thresholds, TimeInterval>) -> some View {
        Stepper(value: Binding(
            get: { value / 3600 },
            set: { hours in
                service.updateSettings { settings in
                    var thresholds = settings.thresholds(for: kind)
                    thresholds[keyPath: keyPath] = hours * 3600
                    settings.thresholds[kind] = thresholds
                }
            }
        ), in: 1...720, step: 1) {
            LabeledContent(title, value: Formatting.duration(value))
        }
    }
}
