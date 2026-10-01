import SwiftUI
import SyncthingKit

/// Devices that tried to connect and folders offered by remote devices,
/// with accept/dismiss actions.
struct PendingView: View {
    let session: SyncSession

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
                                    dismiss: { Task { await session.dismiss(device) } },
                                    ignore: { Task { await session.ignore(device) } })
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
                                    dismiss: { Task { await session.dismiss(folder) } },
                                    ignore: { Task { await session.ignore(folder) } })
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
                                       description: Text("When your Mac adds this device or shares a folder with it, the request appears here."))
            }
        }
        .sheet(item: $acceptingDevice) { device in
            DeviceEditorView(session: session, existing: nil, prefill: device)
        }
        .sheet(item: $acceptingFolder) { folder in
            FolderEditorView(session: session, accepting: folder)
        }
    }

    private func actions(accept: @escaping () -> Void, dismiss: @escaping () -> Void,
                         ignore: @escaping () -> Void) -> some View {
        HStack {
            Button("Add…", action: accept).buttonStyle(.borderedProminent)
            Button("Dismiss", action: dismiss).buttonStyle(.bordered)
            Menu {
                Button("Ignore Permanently", role: .destructive, action: ignore)
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel(Text("More"))
            }
        }
        .controlSize(.small)
        .padding(.top, 4)
    }
}
