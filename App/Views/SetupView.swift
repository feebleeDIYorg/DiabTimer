import NightscoutKit
import SwiftUI
import TimerCore

/// Einrichtung: Server und Token, Prüfung von Version und Rechten, Startwerte, Mitteilungen.
struct SetupView: View {
    private enum Step {
        case server
        case sensor
        case tubing
        case notifications
    }

    private var service = ChangeService.shared
    @State private var step: Step = .server
    @State private var urlText = ""
    @State private var token = ""
    @State private var isChecking = false
    @State private var message: String?
    @State private var credentials: ServerCredentials?
    @State private var serverThresholds: [TimerKind: Thresholds] = [:]
    @State private var sensorLifetime: Double = 10 * 24
    @State private var knowsTubingChange = true
    @State private var lastTubingChange = Date()
    @State private var isFinishing = false

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .server: serverStep
                case .sensor: sensorStep
                case .tubing: tubingStep
                case .notifications: notificationStep
                }
            }
            .navigationTitle("Willkommen")
            .accessibilityIdentifier("setup")
        }
    }

    // MARK: - Schritte

    private var serverStep: some View {
        Group {
            Section {
                Text("DiabTimer zeigt, wie lange Kanüle, Schlauch, Insulin, Sensor und Pumpenbatterie in Gebrauch sind, und erinnert an den Wechsel.")
                Text("Kein Medizinprodukt. Keine Dosisberechnung, keine BZ-Alarme.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("https://mein-nightscout.example.com", text: $urlText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("serverURL")
                SecureField("Zugriffstoken", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("token")
            } header: {
                Text("Nightscout")
            } footer: {
                Text("Lege in Nightscout unter Admin-Werkzeuge eine Rolle „diabtimer“ mit den Rechten api:status:read, api:treatments:read, api:treatments:create, api:treatments:update und api:treatments:delete an, dazu ein Subject mit dieser Rolle. Dessen Zugriffstoken gehört hier hinein.")
            }
            if let message {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button {
                    Task { await checkServer() }
                } label: {
                    HStack {
                        Text("Verbinden")
                        if isChecking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isChecking || urlText.isEmpty || token.isEmpty)
                .accessibilityIdentifier("connect")
            }
        }
    }

    private var sensorStep: some View {
        Group {
            Section {
                Picker("Laufzeit des Sensors", selection: $sensorLifetime) {
                    ForEach(Thresholds.sensorLifetimeSuggestions, id: \.self) { hours in
                        Text(Formatting.duration(hours * 3600)).tag(hours)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Sensor")
            } footer: {
                Text("Dein Server hat keine eigenen Sensor-Schwellen. DiabTimer erinnert 24 h, 6 h und 2 h vor Ablauf. Später in den Einstellungen änderbar.")
            }
            Section {
                Button("Weiter") { step = .tubing }
            }
        }
    }

    private var tubingStep: some View {
        Group {
            Section {
                Toggle("Letzten Schlauchwechsel kenne ich", isOn: $knowsTubingChange)
                if knowsTubingChange {
                    DatePicker("Gewechselt am", selection: $lastTubingChange, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                }
            } header: {
                Text("Schlauch")
            } footer: {
                Text("Nightscout kennt keinen Schlauchwechsel. DiabTimer speichert ihn in deiner iCloud und gleicht ihn zwischen deinen Geräten ab.")
            }
            Section {
                Button("Weiter") { step = .notifications }
            }
        }
    }

    private var notificationStep: some View {
        Group {
            Section {
                Text("DiabTimer erinnert mit Mitteilungen an fällige Wechsel. Ohne Erlaubnis gibt es keine Erinnerungen.")
            }
            Section {
                Button {
                    Task { await finish(askForNotifications: true) }
                } label: {
                    HStack {
                        Text("Mitteilungen erlauben und starten")
                        if isFinishing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isFinishing)
                Button("Ohne Mitteilungen starten") {
                    Task { await finish(askForNotifications: false) }
                }
                .disabled(isFinishing)
            }
            if let message {
                Section {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Aktionen

    private func checkServer() async {
        message = nil
        guard let url = NightscoutClient.normalizedURL(from: urlText) else {
            message = "Die Adresse ist ungültig."
            return
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        isChecking = true
        defer { isChecking = false }

        let client = NightscoutClient(baseURL: url, accessToken: trimmedToken)
        do {
            let status = try await client.status()
            if let major = status.majorVersion, major < 15 {
                message = "Nightscout \(status.version) ist zu alt. DiabTimer braucht Version 15 oder neuer (API v3)."
                return
            }
            guard status.treatments.isSufficient else {
                message = "Dem Token fehlen Rechte: Es braucht mindestens api:treatments:read und api:treatments:create."
                return
            }
            serverThresholds = (try? await client.serverThresholds()) ?? [:]
            credentials = ServerCredentials(url: url, token: trimmedToken)
            step = serverThresholds[.sensor] == nil ? .sensor : .tubing
            if step == .tubing, !service.state.tubing.entries.isEmpty {
                step = .notifications
            }
        } catch NightscoutError.unauthorized {
            message = "Der Zugriffstoken wurde nicht akzeptiert."
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func finish(askForNotifications: Bool) async {
        guard let credentials else {
            step = .server
            return
        }
        isFinishing = true
        defer { isFinishing = false }
        if askForNotifications {
            _ = await ReminderScheduler.requestAuthorization()
        }
        do {
            try await service.completeSetup(
                credentials: credentials,
                serverThresholds: serverThresholds,
                sensorLifetimeHours: serverThresholds[.sensor] == nil ? sensorLifetime : nil,
                lastTubingChange: knowsTubingChange ? lastTubingChange : nil
            )
        } catch {
            message = "Zugangsdaten konnten nicht gespeichert werden: \(error.localizedDescription)"
        }
    }
}
