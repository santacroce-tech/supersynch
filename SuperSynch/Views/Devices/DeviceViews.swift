import SwiftUI
import SyncthingKit

struct DeviceListView: View {
    let session: ServerSession
    var selection: Binding<Route?>?

    var body: some View {
        SelectableList(selection: selection) {
            ForEach(session.state.remoteDevices) { device in
                NavigationLink(value: Route.device(device.deviceID)) {
                    DeviceRow(device: device, session: session)
                }
                .swipeActions {
                    Button {
                        Task { await session.setDevicePaused(device.deviceID, paused: !device.paused) }
                    } label: {
                        device.paused
                            ? Label("Resume", systemImage: "play.fill")
                            : Label("Pause", systemImage: "pause.fill")
                    }
                    .tint(.gray)
                }
            }
        }
        .navigationTitle("Devices")
        .refreshable { await session.refresh() }
        .overlay {
            if session.state.remoteDevices.isEmpty {
                if session.state.status == nil {
                    ProgressView()
                } else {
                    ContentUnavailableView("No Remote Devices", systemImage: "laptopcomputer.and.iphone",
                                           description: Text("This Syncthing instance isn't paired with any other devices."))
                }
            }
        }
    }
}

struct DeviceRow: View {
    let device: DeviceConfig
    let session: ServerSession

    var body: some View {
        let state = session.state.deviceState(device.deviceID)
        let connection = session.state.connections[device.deviceID]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(device.displayName).font(.headline)
                Spacer()
                StateBadge(state)
            }
            if case .syncing(let percent) = state {
                CompletionBar(percent: percent, color: StateStyle(state).color)
            }
            HStack(spacing: 12) {
                if let connection, connection.connected {
                    Text(connection.address).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let rates = session.state.deviceRates[device.deviceID] {
                        Label(Format.rate(rates.inBps), systemImage: "arrow.down")
                        Label(Format.rate(rates.outBps), systemImage: "arrow.up")
                    }
                } else if !device.paused {
                    Text("Last seen \(Format.relative(session.state.deviceStats[device.deviceID]?.lastSeen))")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct DeviceDetailView: View {
    let session: ServerSession
    let deviceID: DeviceID

    var body: some View {
        if let device = session.state.device(deviceID) {
            content(device)
        } else {
            ContentUnavailableView("Device Not Found", systemImage: "questionmark.circle",
                                   description: Text("It may have been removed from this server."))
        }
    }

    @ViewBuilder
    private func content(_ device: DeviceConfig) -> some View {
        let state = session.state.deviceState(deviceID)
        let connection = session.state.connections[deviceID]
        let completion = session.state.deviceCompletion[deviceID]
        List {
            Section {
                HStack {
                    StateBadge(state).font(.title3)
                    Spacer()
                    if let completion, connection?.connected == true {
                        Text(Format.percent(completion.completion)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let completion, connection?.connected == true, completion.completion < 100 {
                    CompletionBar(percent: completion.completion, color: StateStyle(state).color)
                    Text("\(Format.bytes(completion.needBytes)) remaining")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Actions") {
                Button {
                    Task { await session.setDevicePaused(deviceID, paused: !device.paused) }
                } label: {
                    device.paused
                        ? Label("Resume Device", systemImage: "play.fill")
                        : Label("Pause Device", systemImage: "pause.fill")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            Section("Connection") {
                if let connection, connection.connected {
                    InfoRow(title: "Address", value: connection.address, monospaced: true)
                    if !connection.type.isEmpty { InfoRow(title: "Type", value: connection.type) }
                    if !connection.clientVersion.isEmpty { InfoRow(title: "Version", value: connection.clientVersion) }
                    if let rates = session.state.deviceRates[deviceID] {
                        InfoRow(title: "Download", value: Format.rate(rates.inBps))
                        InfoRow(title: "Upload", value: Format.rate(rates.outBps))
                    }
                    InfoRow(title: "Received", value: Format.bytes(connection.inBytesTotal))
                    InfoRow(title: "Sent", value: Format.bytes(connection.outBytesTotal))
                    if let started = connection.startedAt {
                        InfoRow(title: "Connected Since", value: Format.relative(started))
                    }
                } else {
                    InfoRow(title: "Last Seen", value: Format.relative(session.state.deviceStats[deviceID]?.lastSeen))
                }
                InfoRow(title: "Configured Addresses", value: device.addresses.joined(separator: "\n"))
            }

            let folders = session.state.folders(sharedWith: deviceID)
            Section("Shared Folders") {
                if folders.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(folders) { folder in
                    HStack {
                        Text(folder.displayName)
                        Spacer()
                        if let c = session.state.remoteFolderCompletion[deviceID]?[folder.id] {
                            Text(Format.percent(c.completion)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Identity") {
                DeviceIDRow(deviceID: deviceID)
                InfoRow(title: "Compression", value: device.compression)
                InfoRow(title: "Introducer", value: device.introducer ? String(localized: "Yes") : String(localized: "No"))
            }
        }
        .navigationTitle(device.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await session.refresh() }
    }
}
