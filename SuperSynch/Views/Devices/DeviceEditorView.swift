import SwiftUI
import SyncthingKit

/// Add a remote device (e.g. your Mac) or edit an existing one: ID, name,
/// addresses and which folders to share with it.
struct DeviceEditorView: View {
    let session: SyncSession
    /// Editing an existing device, or prefilled from a pending request.
    let existing: DeviceConfig?
    var prefill: PendingDevice?

    @Environment(\.dismiss) private var dismiss
    @State private var idText = ""
    @State private var name = ""
    @State private var addressMode = AddressMode.dynamic
    @State private var address = ""
    @State private var sharedFolders: Set<FolderID> = []
    @State private var scanning = false
    @State private var saving = false

    enum AddressMode: Hashable { case dynamic, manual }

    private var normalizedID: DeviceID? { DeviceIDValidator.normalize(idText) }
    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isEditing {
                        Text(idText).font(.caption.monospaced()).textSelection(.enabled)
                    } else {
                        TextField("Device ID", text: $idText, axis: .vertical)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        HStack {
                            Button("Paste", systemImage: "doc.on.clipboard") {
                                idText = UIPasteboard.general.string ?? idText
                            }
                            if QRScannerView.isAvailable {
                                Button("Scan QR Code", systemImage: "qrcode.viewfinder") { scanning = true }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("Device ID")
                } footer: {
                    if !isEditing {
                        if !idText.isEmpty && normalizedID == nil {
                            Text("That doesn't look like a valid Syncthing device ID.").foregroundStyle(.red)
                        } else {
                            Text("On your Mac, open Syncthing → Actions → Show ID.")
                        }
                    }
                }

                Section("Name") {
                    TextField("e.g. MacBook", text: $name)
                }

                Section {
                    Picker("Addresses", selection: $addressMode) {
                        Text("Automatic").tag(AddressMode.dynamic)
                        Text("Manual").tag(AddressMode.manual)
                    }
                    if addressMode == .manual {
                        TextField("tcp://macbook.local:22000", text: $address)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Automatic uses Syncthing's discovery. If the devices can't find each other on your network, enter the Mac's address (e.g. tcp://192.168.1.20:22000).")
                }

                if !session.state.folders.isEmpty {
                    Section("Share Folders") {
                        ForEach(session.state.folders) { folder in
                            Toggle(folder.displayName, isOn: Binding(
                                get: { sharedFolders.contains(folder.id) },
                                set: { on in if on { sharedFolders.insert(folder.id) } else { sharedFolders.remove(folder.id) } }
                            ))
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Device" : "Add Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || normalizedID == nil || (addressMode == .manual && address.isEmpty))
                }
            }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    QRScannerView(accept: { DeviceIDValidator.normalize($0) != nil }) { payload in
                        idText = DeviceIDValidator.normalize(payload) ?? payload
                        scanning = false
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan Device ID")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        if let existing {
            idText = existing.deviceID
            name = existing.name
            let manual = existing.addresses.filter { $0 != "dynamic" }
            if !manual.isEmpty {
                addressMode = .manual
                address = manual.joined(separator: ", ")
            }
            sharedFolders = Set(session.state.folders(sharedWith: existing.deviceID).map(\.id))
        } else if let prefill {
            idText = prefill.deviceID
            name = prefill.name
        }
    }

    private func save() async {
        guard let id = normalizedID else { return }
        saving = true
        defer { saving = false }
        let addresses = addressMode == .dynamic
            ? ["dynamic"]
            : address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let draft = DeviceDraft(deviceID: id, name: name.trimmingCharacters(in: .whitespaces), addresses: addresses)
        if await session.saveDevice(draft, sharing: sharedFolders) { dismiss() }
    }
}
