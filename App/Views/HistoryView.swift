import Persistence
import SwiftUI
import TimerCore

/// Verlauf eines Timers mit Tragedauer, Korrigieren und Löschen eigener Einträge.
struct HistoryView: View {
    let kind: TimerKind

    private var service = ChangeService.shared
    @State private var editing: ChangeEvent?
    @State private var showPermissionAlert = false

    init(kind: TimerKind) {
        self.kind = kind
    }

    var body: some View {
        let events = service.state.history(for: kind)
        List {
            if let average = events.averageWearDuration() {
                Section {
                    LabeledContent("Durchschnittliche Tragedauer", value: Formatting.duration(average))
                } footer: {
                    Text("Aus den letzten \(min(10, events.count - 1)) Wechseln.")
                }
            }
            Section("Wechsel") {
                if events.isEmpty {
                    Text("Noch keine Wechsel bekannt.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    let worn = index > 0 ? events[index - 1].date.timeIntervalSince(event.date) : nil
                    EventRow(event: event, wornDuration: worn, isPending: service.state.isPending(eventID: event.id))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if event.isOwn { editing = event }
                        }
                        .swipeActions {
                            if event.isOwn {
                                Button("Löschen", role: .destructive) {
                                    if !service.remove(event) {
                                        showPermissionAlert = true
                                    }
                                }
                            }
                        }
                }
            }
        }
        .navigationTitle(kind.displayName)
        .sheet(item: $editing) { event in
            EditEventSheet(event: event) { date, note in
                if !service.edit(event, date: date, note: note) {
                    showPermissionAlert = true
                }
            }
        }
        .alert("Nicht erlaubt", isPresented: $showPermissionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Der Eintrag ist schon an Nightscout gesendet, und dein Zugriffstoken darf ihn nicht ändern oder löschen. Gib der Rolle die Rechte api:treatments:update und api:treatments:delete.")
        }
    }
}

struct EventRow: View {
    let event: ChangeEvent
    let wornDuration: TimeInterval?
    let isPending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Formatting.dateTime(event.date))
                    .font(.body.weight(.medium))
                Spacer()
                if isPending {
                    Label("wartet", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 8) {
                if let wornDuration {
                    Text("getragen \(Formatting.duration(wornDuration))")
                } else {
                    Text("aktuell")
                }
                Text("·")
                Text(event.isOwn ? "DiabTimer" : (event.source ?? "unbekannt"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let note = event.note {
                Text(note)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

struct EditEventSheet: View {
    let event: ChangeEvent
    let onSave: (Date, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var note: String

    init(event: ChangeEvent, onSave: @escaping (Date, String?) -> Void) {
        self.event = event
        self.onSave = onSave
        _date = State(initialValue: event.date)
        _note = State(initialValue: event.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Zeitpunkt", selection: $date, in: ...Date().addingTimeInterval(60), displayedComponents: [.date, .hourAndMinute])
                TextField("Notiz", text: $note, axis: .vertical)
            }
            .navigationTitle("Eintrag korrigieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        onSave(date, note.isEmpty ? nil : note)
                        dismiss()
                    }
                }
            }
        }
    }
}
