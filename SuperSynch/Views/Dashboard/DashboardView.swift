import SwiftUI
import SyncthingKit

/// This device: identity (with QR for pairing), status, transfer, folders
/// needing attention and global controls.
struct DashboardView: View {
    @Environment(AppModel.self) private var app
    let session: SyncSession
    var selection: Binding<Route?>?

    @State private var showingID = false

    private var state: NodeState { session.state }

    var body: some View {
        SelectableList(selection: selection) {
            identitySection
            transferSection
            attentionSection
            controlsSection
        }
        .navigationTitle("This Device")
        .refreshable { await session.refresh() }
        .sheet(isPresented: $showingID) {
            if let id = app.deviceID { DeviceIDSheet(deviceID: id, name: thisDeviceName) }
        }
    }

    private var thisDeviceName: String {
        state.myID.flatMap { state.device($0)?.name } ?? ""
    }

    @ViewBuilder private var identitySection: some View {
        Section {
            if let id = app.deviceID {
                Button { showingID = true } label: {
                    HStack(spacing: 14) {
                        QRCodeView(text: id).frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(thisDeviceName.isEmpty ? String(localized: "This Device") : thisDeviceName)
                                .font(.headline).foregroundStyle(.primary)
                            Text(DeviceIDFormat.short(id)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("Show Device ID").font(.caption).foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityHint(Text("Shows this device's ID and QR code for pairing"))
            }
            LabeledContent("Status") { EngineIndicator() }
            if let status = state.status {
                InfoRow(title: "Running For", value: Format.uptime(seconds: status.uptime))
            }
            if let version = state.version {
                InfoRow(title: "Syncthing", value: version.version)
            }
        } footer: {
            Text("Add this device on your Mac's Syncthing (Add Remote Device) using its ID or QR code.")
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
        }
    }

    @ViewBuilder private var attentionSection: some View {
        let folders = state.folders.filter { folder in
            switch state.folderState(folder.id) {
            case .upToDate, .paused: false
            default: true
            }
        }
        Section("Folder Activity") {
            if state.folders.isEmpty {
                Label("No folders yet", systemImage: "folder.badge.plus").foregroundStyle(.secondary)
            } else if folders.isEmpty {
                Label("All folders are up to date", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            ForEach(folders) { folder in
                NavigationLink(value: Route.folder(folder.id)) {
                    FolderRow(folder: folder, session: session)
                }
            }
        }
    }

    @ViewBuilder private var controlsSection: some View {
        Section("Controls") {
            Button { Task { await session.rescanAll() } } label: {
                Label("Rescan All Folders", systemImage: "arrow.clockwise.circle")
            }
            Button { Task { await session.pauseAll() } } label: {
                Label("Pause All Devices", systemImage: "pause.circle")
            }
            Button { Task { await session.resumeAll() } } label: {
                Label("Resume All Devices", systemImage: "play.circle")
            }
        }
        .disabled(session.phase != .live)
    }
}

/// Full device ID with QR code, copy and share, for pairing with the Mac.
struct DeviceIDSheet: View {
    let deviceID: DeviceID
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    QRCodeView(text: deviceID)
                        .frame(maxWidth: 280)
                    Text(deviceID)
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    HStack {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = deviceID }
                        ShareLink(item: deviceID) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    .buttonStyle(.bordered)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("To pair with your Mac").font(.headline)
                        Text("1. Open Syncthing on your Mac (http://127.0.0.1:8384).")
                        Text("2. Click Add Remote Device and paste or scan this ID.")
                        Text("3. Add your Mac here too (Devices → Add Device), then share folders.")
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle(name.isEmpty ? String(localized: "Device ID") : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
