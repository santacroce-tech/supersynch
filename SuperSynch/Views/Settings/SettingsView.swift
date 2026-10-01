import SwiftUI
import SyncthingKit

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    let session: SyncSession

    @State private var deviceName = ""
    @State private var globalDiscovery = true
    @State private var localDiscovery = true
    @State private var relays = true
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Device Name", text: $deviceName)
                    .onSubmit { Task { await session.renameThisDevice(deviceName) } }
                    .submitLabel(.done)
            } header: {
                Text("This Device")
            } footer: {
                Text("How this iPhone appears on your other devices.")
            }

            Section {
                Toggle("Global Discovery", isOn: $globalDiscovery)
                Toggle("Local Discovery", isOn: $localDiscovery)
                Toggle("Relays", isOn: $relays)
            } header: {
                Text("Network")
            } footer: {
                Text("Discovery lets your devices find each other without entering addresses. Relays connect devices that can't reach each other directly; traffic stays end-to-end encrypted.")
            }
            .onChange(of: globalDiscovery) { saveOptions() }
            .onChange(of: localDiscovery) { saveOptions() }
            .onChange(of: relays) { saveOptions() }

            Section {
                Label("Syncs while SuperSynch is open, and briefly after you leave it.", systemImage: "iphone")
                Label("iOS also wakes the app periodically to sync in the background, typically when the phone is charging and on Wi-Fi. iOS decides when.", systemImage: "clock.arrow.circlepath")
                Label("For an immediate sync, open the app.", systemImage: "arrow.triangle.2.circlepath")
            } header: {
                Text("Background Sync")
            }
            .font(.callout)

            Section("About") {
                InfoRow(title: "Syncthing", value: session.state.version?.version ?? "–")
                if let id = app.deviceID { DeviceIDRow(deviceID: id) }
                Link("Syncthing is open source (MPL-2.0)", destination: URL(string: "https://github.com/syncthing/syncthing")!)
            }
        }
        .navigationTitle("Settings")
        .task(id: session.phase == .live) { await load() }
    }

    private func load() async {
        guard session.phase == .live, !loaded else { return }
        if let id = session.state.myID { deviceName = session.state.device(id)?.name ?? "" }
        if let options = try? await session.client.options() {
            globalDiscovery = options["globalAnnounceEnabled"] == .bool(true)
            localDiscovery = options["localAnnounceEnabled"] == .bool(true)
            relays = options["relaysEnabled"] == .bool(true)
        }
        loaded = true
    }

    private func saveOptions() {
        guard loaded else { return }
        let patch: JSONValue = [
            "globalAnnounceEnabled": .bool(globalDiscovery),
            "localAnnounceEnabled": .bool(localDiscovery),
            "relaysEnabled": .bool(relays),
        ]
        Task {
            do { try await session.client.setOptions(patch) } catch { session.actionError = SyncthingError(error) }
        }
    }
}
