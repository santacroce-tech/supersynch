import SwiftUI
import SyncthingKit

/// Per-server overview: identity, transfer, devices, folders needing
/// attention, system errors and global controls.
struct DashboardView: View {
    let session: ServerSession
    var selection: Binding<Route?>?

    @State private var confirmation: DestructiveAction?

    enum DestructiveAction: Identifiable {
        case restart, shutdown
        var id: Self { self }
    }

    private var state: ServerState { session.state }

    var body: some View {
        SelectableList(selection: selection) {
            identitySection
            transferSection
            attentionSection
            errorsSection
            controlsSection
        }
        .navigationTitle("Dashboard")
        .refreshable { await session.refresh() }
        .overlay {
            if state.status == nil, session.phase == .connecting {
                ProgressView("Loading…")
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: isConfirming, titleVisibility: .visible,
                            presenting: confirmation) { action in
            switch action {
            case .restart:
                Button("Restart", role: .destructive) { Task { await session.restart() } }
            case .shutdown:
                Button("Shut Down", role: .destructive) { Task { await session.shutdown() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            switch action {
            case .restart:
                Text("Syncthing will restart on \(session.server.displayName). Transfers in progress will resume afterwards.")
            case .shutdown:
                Text("Syncthing will stop on \(session.server.displayName). You can't start it again from this app.")
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var identitySection: some View {
        Section("This Device") {
            if let status = state.status {
                if let me = state.device(status.myID), !me.name.isEmpty {
                    InfoRow(title: "Name", value: me.name)
                }
                DeviceIDRow(deviceID: status.myID)
                InfoRow(title: "Uptime", value: Format.uptime(seconds: status.uptime))
            }
            if let version = state.version {
                InfoRow(title: "Version", value: version.version)
                if !version.os.isEmpty {
                    InfoRow(title: "Platform", value: "\(version.os) / \(version.arch)")
                }
            }
            LabeledContent("Connection") { PhaseIndicator(phase: session.phase) }
        }
    }

    @ViewBuilder private var transferSection: some View {
        Section("Transfer") {
            LabeledContent {
                Text(Format.rate(state.totalRates.inBps)).monospacedDigit()
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            LabeledContent {
                Text(Format.rate(state.totalRates.outBps)).monospacedDigit()
            } label: {
                Label("Upload", systemImage: "arrow.up.circle")
            }
            LabeledContent {
                Text("\(state.connectedDeviceCount) of \(state.remoteDevices.count)")
            } label: {
                Label("Connected Devices", systemImage: "laptopcomputer.and.iphone")
            }
            if let totals = state.totals {
                InfoRow(title: "Total Received", value: Format.bytes(totals.inBytesTotal))
                InfoRow(title: "Total Sent", value: Format.bytes(totals.outBytesTotal))
            }
        }
    }

    @ViewBuilder private var attentionSection: some View {
        let folders = state.folders.filter { folder in
            switch state.folderState(folder.id) {
            case .upToDate, .paused: false
            default: true
            }
        }
        Section {
            if folders.isEmpty {
                Label("All folders are up to date", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(folders) { folder in
                NavigationLink(value: Route.folder(folder.id)) {
                    FolderRow(folder: folder, session: session)
                }
            }
        } header: {
            Text("Folder Activity")
        }
    }

    @ViewBuilder private var errorsSection: some View {
        if !state.systemErrors.isEmpty {
            Section {
                ForEach(state.systemErrors, id: \.self) { error in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(error.message).font(.callout)
                        if let when = error.when {
                            Text(when, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Clear Errors", role: .destructive) { Task { await session.clearSystemErrors() } }
            } header: {
                Label("System Errors", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var controlsSection: some View {
        Section("Controls") {
            Button { Task { await session.pauseAll() } } label: {
                Label("Pause All Devices", systemImage: "pause.circle")
            }
            Button { Task { await session.resumeAll() } } label: {
                Label("Resume All Devices", systemImage: "play.circle")
            }
            Button { Task { await session.rescanAll() } } label: {
                Label("Rescan All Folders", systemImage: "arrow.clockwise.circle")
            }
            Button(role: .destructive) { confirmation = .restart } label: {
                Label("Restart Syncthing…", systemImage: "restart.circle")
            }
            Button(role: .destructive) { confirmation = .shutdown } label: {
                Label("Shut Down Syncthing…", systemImage: "power.circle")
            }
        }
        .disabled(session.phase == .shutDown)
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }

    private var confirmationTitle: Text {
        switch confirmation {
        case .shutdown: Text("Shut down Syncthing?")
        default: Text("Restart Syncthing?")
        }
    }
}

/// Device ID with short display and a copy action.
struct DeviceIDRow: View {
    let deviceID: DeviceID

    var body: some View {
        LabeledContent("Device ID") {
            Text(deviceID)
                .font(.caption.monospaced())
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .contextMenu {
            Button("Copy Device ID", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = deviceID
            }
        }
    }
}
