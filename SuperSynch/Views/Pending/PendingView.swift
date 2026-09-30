import SwiftUI
import SyncthingKit

/// Devices that tried to connect and folders offered by remote devices,
/// with accept/dismiss actions.
struct PendingView: View {
    let session: ServerSession

    @State private var acceptingDevice: PendingDevice?
    @State private var acceptingFolder: PendingFolder?

    var body: some View {
        List {
            if !session.state.pendingDevices.isEmpty {
                Section("Devices") {
                    ForEach(session.state.pendingDevices) { device in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name.isEmpty ? DeviceIDFormat.short(device.deviceID) : device.name).font(.headline)
                            Text(device.deviceID).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if !device.address.isEmpty {
                                Text(device.address).font(.caption).foregroundStyle(.secondary)
                            }
                            if let time = device.time {
                                Text("Requested \(Format.relative(time))").font(.caption).foregroundStyle(.secondary)
                            }
                            actions(accept: { acceptingDevice = device },
                                    dismiss: { Task { await session.dismiss(device) } })
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            if !session.state.pendingFolders.isEmpty {
                Section("Folders") {
                    ForEach(session.state.pendingFolders) { folder in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folder.displayName).font(.headline)
                            Text("Offered by \(session.state.deviceName(folder.offeredBy))")
                                .font(.caption).foregroundStyle(.secondary)
                            if folder.receiveEncrypted {
                                Label("Encrypted", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            }
                            actions(accept: { acceptingFolder = folder },
                                    dismiss: { Task { await session.dismiss(folder) } })
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Pending Requests")
        .refreshable { await session.refresh() }
        .overlay {
            if session.state.pendingCount == 0 {
                ContentUnavailableView("No Pending Requests", systemImage: "tray",
                                       description: Text("New devices and shared folders waiting for approval appear here."))
            }
        }
        .sheet(item: $acceptingDevice) { device in
            AcceptDeviceSheet(session: session, device: device)
        }
        .sheet(item: $acceptingFolder) { folder in
            AcceptFolderSheet(session: session, folder: folder)
        }
    }

    private func actions(accept: @escaping () -> Void, dismiss: @escaping () -> Void) -> some View {
        HStack {
            Button("Add…", action: accept).buttonStyle(.borderedProminent)
            Button("Dismiss", role: .destructive, action: dismiss).buttonStyle(.bordered)
        }
        .controlSize(.small)
        .padding(.top, 4)
    }
}

private struct AcceptDeviceSheet: View {
    let session: ServerSession
    let device: PendingDevice
    @State private var name = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Device Name", text: $name)
                } footer: {
                    Text(device.deviceID).font(.caption.monospaced())
                }
                Section {
                    Text("The device will be added with the server's default device settings. Share folders with it from the Syncthing web GUI.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saving = true
                        Task {
                            if await session.accept(device, name: name) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(saving)
                }
            }
            .onAppear { name = device.name }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct AcceptFolderSheet: View {
    let session: ServerSession
    let folder: PendingFolder
    @State private var path = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    InfoRow(title: "Label", value: folder.displayName)
                    InfoRow(title: "Folder ID", value: folder.folderID, monospaced: true)
                    InfoRow(title: "Offered By", value: session.state.deviceName(folder.offeredBy))
                }
                Section {
                    TextField("Folder Path", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Folder Path on Server")
                } footer: {
                    Text("The path on the Syncthing host where this folder will be stored.")
                }
            }
            .navigationTitle("Add Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saving = true
                        Task {
                            if await session.accept(folder, path: path) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(saving || path.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { path = await session.suggestedPath(for: folder) }
        }
        .presentationDetents([.medium, .large])
    }
}
