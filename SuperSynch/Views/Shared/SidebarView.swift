import SwiftUI
import SyncthingKit

/// Server switcher + section list. The sidebar column on iPad and the root
/// screen on iPhone.
struct SidebarView: View {
    @Environment(AppModel.self) private var app
    let session: ServerSession
    /// Non-nil in the split view (drives the content column).
    var selection: Binding<AppSection?>?
    let onManageServers: () -> Void

    var body: some View {
        SelectableList(selection: selection) {
            Section {
                ServerSummaryRow(session: session)
            }
            Section {
                ForEach(AppSection.allCases) { section in
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.systemImage)
                            .badge(badge(for: section))
                    }
                }
            }
        }
        .navigationTitle(session.server.displayName)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ServerSwitcherMenu(onManageServers: onManageServers)
            }
        }
    }

    private func badge(for section: AppSection) -> Int {
        switch section {
        case .pending: session.state.pendingCount
        case .dashboard: session.state.systemErrors.count
        default: 0
        }
    }
}

/// Compact status: connection state, device count and transfer rates.
struct ServerSummaryRow: View {
    let session: ServerSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                PhaseIndicator(phase: session.phase)
                Spacer()
                if let version = session.state.version?.version {
                    Text(version).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 16) {
                Label(Format.rate(session.state.totalRates.inBps), systemImage: "arrow.down")
                Label(Format.rate(session.state.totalRates.outBps), systemImage: "arrow.up")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, 2)
    }
}

struct PhaseIndicator: View {
    let phase: ConnectionPhase

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(text)
        }
        .font(.subheadline.weight(.medium))
        .fixedSize()
    }

    private var text: LocalizedStringKey {
        switch phase {
        case .idle: "Idle"
        case .connecting: "Connecting…"
        case .live: "Connected"
        case .polling: "Reconnecting…"
        case .failed: "Offline"
        case .shutDown: "Shut Down"
        }
    }

    private var color: Color {
        switch phase {
        case .live: .green
        case .connecting, .polling: .orange
        case .failed: .red
        case .idle, .shutDown: .gray
        }
    }
}

/// Menu for switching between saved servers.
struct ServerSwitcherMenu: View {
    @Environment(AppModel.self) private var app
    let onManageServers: () -> Void

    var body: some View {
        @Bindable var app = app
        Menu {
            Picker("Server", selection: $app.selectedServerID) {
                ForEach(app.store.servers) { server in
                    Text(server.displayName).tag(Optional(server.id))
                }
            }
            Divider()
            Button("Manage Servers…", systemImage: "server.rack", action: onManageServers)
        } label: {
            Label("Servers", systemImage: "server.rack")
        }
        .accessibilityHint(Text("Switch between Syncthing servers"))
    }
}
