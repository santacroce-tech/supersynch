import SwiftUI
import SyncthingKit

/// Status summary + section list. The sidebar column on iPad and the root
/// screen on iPhone.
struct SidebarView: View {
    let session: SyncSession
    /// Non-nil in the split view (drives the content column).
    var selection: Binding<AppSection?>?

    var body: some View {
        SelectableList(selection: selection) {
            Section {
                NodeSummaryRow(session: session)
            }
            Section {
                ForEach(AppSection.allCases) { section in
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.systemImage)
                            .badge(section == .pending ? session.state.pendingCount : 0)
                    }
                }
            }
        }
        .navigationTitle("SuperSynch")
    }
}

/// Compact status: engine state, connected devices and transfer rates.
struct NodeSummaryRow: View {
    let session: SyncSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                EngineIndicator()
                Spacer()
                Text("\(session.state.connectedDeviceCount) of \(session.state.remoteDevices.count) devices")
                    .font(.caption).foregroundStyle(.secondary)
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

/// Dot + label for the embedded engine's state.
struct EngineIndicator: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(text)
        }
        .font(.subheadline.weight(.medium))
        .fixedSize()
    }

    private var syncing: Bool {
        !app.session.state.isSyncIdle && app.session.phase == .live
    }

    private var text: LocalizedStringKey {
        switch app.engine?.status {
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .stopped: "Stopped"
        case .failed: "Failed"
        default: app.session.phase == .live ? (syncing ? "Syncing" : "Up to Date") : "Connecting…"
        }
    }

    private var color: Color {
        switch app.engine?.status {
        case .failed: .red
        case .starting, .stopping: .orange
        case .stopped: .gray
        default: app.session.phase == .live ? (syncing ? .blue : .green) : .orange
        }
    }
}
