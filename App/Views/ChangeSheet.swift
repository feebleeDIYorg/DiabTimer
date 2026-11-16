import SwiftUI
import TimerCore

/// Kombi-Dialog: mehrere Teile mit gemeinsamem Zeitpunkt eintragen.
struct ChangeSheet: View {
    let preselected: TimerKind?

    private var service = ChangeService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<TimerKind> = []
    @State private var date = Date()
    @State private var note = ""
    @State private var didPrepare = false

    init(preselected: TimerKind?) {
        self.preselected = preselected
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Was wurde gewechselt?") {
                    ForEach(service.state.settings.orderedEnabledTimers, id: \.self) { kind in
                        Toggle(isOn: binding(for: kind)) {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                        .accessibilityIdentifier("toggle-\(kind.rawValue)")
                    }
                }
                Section {
                    DatePicker("Zeitpunkt", selection: $date, in: ...Date().addingTimeInterval(60), displayedComponents: [.date, .hourAndMinute])
                    TextField("Notiz (optional)", text: $note, axis: .vertical)
                } footer: {
                    Text(footerText)
                }
            }
            .navigationTitle("Wechsel eintragen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Eintragen") {
                        service.record(kinds: selection, at: date, note: note)
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("confirmChange")
                }
            }
            .onAppear(perform: prepare)
        }
    }

    private var footerText: String {
        var parts: [String] = []
        if selection.contains(where: \.isNightscoutBacked) {
            let delay = Int(service.state.settings.sendDelay)
            parts.append("Wird nach \(delay) Sekunden an Nightscout gesendet. Bis dahin lässt sich der Eintrag rückgängig machen.")
        }
        if selection.contains(.tubing) {
            parts.append("Der Schlauchwechsel wird nur über iCloud zwischen deinen Geräten abgeglichen.")
        }
        return parts.joined(separator: " ")
    }

    private func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        if let preselected {
            selection = service.suggestedKinds(for: preselected)
        }
    }

    private func binding(for kind: TimerKind) -> Binding<Bool> {
        Binding(
            get: { selection.contains(kind) },
            set: { isOn in
                if isOn {
                    selection.insert(kind)
                    if kind == .cannula {
                        selection.formUnion(service.suggestedKinds(for: .cannula, at: date))
                    }
                } else {
                    selection.remove(kind)
                }
            }
        )
    }
}
