import SwiftUI
import SyncthingKit
import UniformTypeIdentifiers

/// Create a folder (or accept one offered by a device), or edit an existing
/// folder's label and sharing.
struct FolderEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let session: SyncSession
    var existing: FolderConfig?
    var accepting: PendingFolder?

    @State private var label = ""
    @State private var folderID = FolderDraft.generateID()
    @State private var type = "sendreceive"
    @State private var location = Location.inApp
    @State private var externalURL: URL?
    @State private var picking = false
    @State private var shared: Set<DeviceID> = []
    @State private var saving = false
    @State private var error: String?

    enum Location: Hashable { case inApp, external }

    private var isEditing: Bool { existing != nil }

    private var inAppPath: String {
        let name = label.isEmpty ? folderID : label
        return PathSuggestion.make(defaultPath: app.engine?.paths.folderRoot.path ?? "~", name: name, separator: "/")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Folder") {
                    TextField("Label", text: $label)
                    if isEditing || accepting != nil {
                        InfoRow(title: "Folder ID", value: folderID, monospaced: true)
                    } else {
                        TextField("Folder ID", text: $folderID)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if let existing {
                    Section("Location") {
                        Text(existing.path).font(.caption.monospaced()).textSelection(.enabled)
                    }
                } else {
                    Section {
                        Picker("Store In", selection: $location) {
                            Text("SuperSynch").tag(Location.inApp)
                            Text("Other Folder…").tag(Location.external)
                        }
                        .pickerStyle(.segmented)
                        switch location {
                        case .inApp:
                            Text("Files app › On My iPhone › SuperSynch › \(label.isEmpty ? folderID : label)")
                                .font(.caption).foregroundStyle(.secondary)
                        case .external:
                            Button(externalURL?.lastPathComponent ?? String(localized: "Choose Folder…"),
                                   systemImage: "folder.badge.gearshape") { picking = true }
                        }
                    } header: {
                        Text("Location")
                    } footer: {
                        if location == .external {
                            Text("Pick a folder from another app's storage. Cloud locations such as iCloud Drive may not work reliably, because iOS can remove downloaded copies at any time.")
                        }
                    }

                    Section("Folder Type") {
                        Picker("Type", selection: $type) {
                            Text("Send & Receive").tag("sendreceive")
                            Text("Send Only").tag("sendonly")
                            Text("Receive Only").tag("receiveonly")
                        }
                        .disabled(accepting?.receiveEncrypted == true)
                    }
                }

                let devices = session.state.remoteDevices
                Section {
                    if devices.isEmpty {
                        Text("Add a device first to share this folder with it.").foregroundStyle(.secondary)
                    }
                    ForEach(devices) { device in
                        Toggle(device.displayName, isOn: Binding(
                            get: { shared.contains(device.deviceID) },
                            set: { on in if on { shared.insert(device.deviceID) } else { shared.remove(device.deviceID) } }
                        ))
                    }
                } header: {
                    Text("Share With")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(isEditing ? "Edit Folder" : (accepting != nil ? "Add Shared Folder" : "New Folder"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!canSave)
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { externalURL = url }
            }
            .onAppear(perform: load)
        }
    }

    private var canSave: Bool {
        guard !saving, !folderID.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if !isEditing, location == .external, externalURL == nil { return false }
        return true
    }

    private func load() {
        if let existing {
            label = existing.label
            folderID = existing.id
            type = existing.type
            shared = Set(existing.deviceIDs.filter { $0 != session.state.myID })
        } else if let accepting {
            label = accepting.label
            folderID = accepting.folderID
            type = accepting.receiveEncrypted ? "receiveencrypted" : "sendreceive"
            shared = [accepting.offeredBy]
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        error = nil
        let id = folderID.trimmingCharacters(in: .whitespaces)
        if let existing {
            var draft = FolderDraft(id: existing.id, label: label, path: existing.path, type: existing.type)
            draft.deviceIDs = Array(shared)
            if await session.saveFolder(draft) { dismiss() }
            return
        }
        let path: String
        if location == .external, let url = externalURL {
            do {
                try app.engine?.externalFolders.register(url, for: id)
                // Open access now so Syncthing can use it immediately.
                app.engine?.externalFolders.beginAccess()
                path = url.path
            } catch {
                self.error = String(localized: "Couldn't keep access to that folder: \(error.localizedDescription)")
                return
            }
        } else {
            path = inAppPath
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let draft = FolderDraft(id: id, label: label, path: path, type: type, deviceIDs: Array(shared))
        if await session.saveFolder(draft) {
            dismiss()
        } else if location == .external {
            app.engine?.externalFolders.unregister(id)
        }
    }
}
