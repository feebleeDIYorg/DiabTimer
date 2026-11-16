import Persistence
import SwiftUI
import TimerCore

/// Startseite: je Timer eine Karte, Banner für „Rückgängig“ und Fehler.
struct OverviewView: View {
    private var service = ChangeService.shared
    @State private var changeRequest: ChangeRequest?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollView {
                    VStack(spacing: 16) {
                        PendingBanner(state: service.state, now: context.date) { ids in
                            service.undo(eventIDs: ids)
                        }
                        if let error = service.state.lastSyncError {
                            ErrorBanner(message: error)
                        }
                        ForEach(service.state.statuses(now: context.date), id: \.kind) { status in
                            NavigationLink(value: status.kind) {
                                TimerCard(status: status) {
                                    changeRequest = ChangeRequest(kind: status.kind)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        SyncFooter(state: service.state, isSyncing: service.isSyncing)
                    }
                    .padding()
                }
            }
            .refreshable { await service.sync() }
            .navigationTitle("DiabTimer")
            .navigationDestination(for: TimerKind.self) { kind in
                HistoryView(kind: kind)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Einstellungen", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        changeRequest = ChangeRequest(kind: nil)
                    } label: {
                        Label("Wechsel eintragen", systemImage: "plus")
                    }
                    .accessibilityIdentifier("addChange")
                }
            }
            .sheet(item: $changeRequest) { request in
                ChangeSheet(preselected: request.kind)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }
}

struct ChangeRequest: Identifiable {
    let id = UUID()
    let kind: TimerKind?
}

/// Karte eines Timers.
struct TimerCard: View {
    let status: TimerStatus
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(status.level.color.opacity(0.2), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: status.progress)
                    .stroke(status.level.color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: status.kind.symbolName)
                    .font(.title3)
                    .foregroundStyle(status.level.color)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(status.kind.displayName)
                        .font(.headline)
                    if status.kind == .tubing {
                        Image(systemName: FileManager.default.ubiquityIdentityToken == nil ? "icloud.slash" : "icloud")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Über iCloud abgeglichen")
                    }
                }
                Text(Formatting.ageText(status))
                    .font(.title2.monospacedDigit().weight(.semibold))
                HStack(spacing: 4) {
                    Image(systemName: status.level.symbolName)
                        .foregroundStyle(status.level.color)
                    Text(Formatting.dueText(status))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button("Gewechselt", action: onChange)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("change-\(status.kind.rawValue)")
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.kind.displayName), \(Formatting.ageText(status)), \(status.level.displayName), \(Formatting.dueText(status))")
    }
}

/// „Wird in 12 s gesendet – Rückgängig“.
struct PendingBanner: View {
    let state: AppState
    let now: Date
    let onUndo: ([String]) -> Void

    var body: some View {
        let pending = state.outbox.filter { $0.isCreate && $0.sendAfter > now && $0.attempts == 0 }
        if let latest = pending.map(\.sendAfter).max() {
            HStack {
                Image(systemName: "paperplane")
                Text("Wird in \(Int(latest.timeIntervalSince(now).rounded(.up))) s an Nightscout gesendet")
                    .font(.subheadline)
                Spacer()
                Button("Rückgängig") {
                    onUndo(pending.map(\.id))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("undo")
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.icloud")
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct SyncFooter: View {
    let state: AppState
    let isSyncing: Bool

    var body: some View {
        VStack(spacing: 4) {
            if isSyncing {
                ProgressView()
            } else if let lastSync = state.lastSync {
                Text("Zuletzt abgeglichen: \(Formatting.dateTime(lastSync))")
            } else {
                Text("Noch nicht abgeglichen")
            }
            let waiting = state.outbox.filter { $0.attempts > 0 }.count
            if waiting > 0 {
                Text("\(waiting) Einträge warten auf das Senden")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
    }
}
