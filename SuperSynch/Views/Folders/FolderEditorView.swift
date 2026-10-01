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
    @State private var passwords: [DeviceID: String] = [:]
    @State private var untrusted: Set<DeviceID> = []
    @State private var versioning = VersioningOption.off
    @State private var keep = 30
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
                        if shared.contains(device.deviceID) && type != "receiveencrypted" {
                            Toggle("Untrusted (Encrypt)", isOn: Binding(
                                get: { untrusted.contains(device.deviceID) },
                                set: { on in if on { untrusted.insert(device.deviceID) } else { untrusted.remove(device.deviceID) } }
                            ))
                            .font(.callout)
                            .padding(.leading)
                            if untrusted.contains(device.deviceID) {
                                SecureField("Encryption Password", text: Binding(
                                    get: { passwords[device.deviceID] ?? "" },
                                    set: { passwords[device.deviceID] = $0 }
                                ))
                                .padding(.leading)
                            }
                        }
                    }
                } header: {
                    Text("Share With")
                } footer: {
                    Text("An untrusted device only stores an encrypted copy it can't read. Use the same password on every device that should be able to decrypt the folder.")
                }

                Section {
                    Picker("Keep Old Versions", selection: $versioning) {
                        ForEach(VersioningOption.allCases) { option in Text(option.title).tag(option) }
                    }
                    if let label = versioning.keepLabel {
                        Stepper(value: $keep, in: 1...365) { Text(label(keep)) }
                    }
                } header: {
                    Text("File Versioning")
                } footer: {
                    Text(versioning.explanation)
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
        // Untrusted devices need a password.
        if untrusted.contains(where: { shared.contains($0) && (passwords[$0] ?? "").isEmpty }) { return false }
        return true
    }

    private func load() {
        if let existing {
            label = existing.label
            folderID = existing.id
            type = existing.type
            shared = Set(existing.deviceIDs.filter { $0 != session.state.myID })
            passwords = existing.encryptionPasswords
            untrusted = Set(existing.encryptionPasswords.keys)
            versioning = VersioningOption(existing.versioning)
            keep = versioning.keepValue(from: existing.versioning) ?? keep
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
        let sharedPasswords = passwords.filter { shared.contains($0.key) && untrusted.contains($0.key) }
        if let existing {
            let draft = FolderDraft(id: existing.id, label: label, path: existing.path, type: existing.type,
                                    deviceIDs: Array(shared), encryptionPasswords: sharedPasswords,
                                    versioning: versioning.config(keep: keep))
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
        let draft = FolderDraft(id: id, label: label, path: path, type: type, deviceIDs: Array(shared),
                                encryptionPasswords: sharedPasswords, versioning: versioning.config(keep: keep))
        if await session.saveFolder(draft) {
            dismiss()
        } else if location == .external {
            app.engine?.externalFolders.unregister(id)
        }
    }
}

/// User-facing versioning choices mapped to Syncthing's versioning config.
enum VersioningOption: String, CaseIterable, Identifiable, Hashable {
    case off, trashcan, simple, staggered

    var id: String { rawValue }

    init(_ versioning: Versioning) {
        self = VersioningOption(rawValue: versioning.type) ?? (versioning.type.isEmpty ? .off : .staggered)
    }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .trashcan: String(localized: "Trash Can")
        case .simple: String(localized: "Simple")
        case .staggered: String(localized: "Staggered")
        }
    }

    var explanation: String {
        switch self {
        case .off: String(localized: "Files changed or deleted by other devices are replaced without keeping a copy.")
        case .trashcan: String(localized: "Deleted or replaced files are kept in .stversions for the chosen number of days.")
        case .simple: String(localized: "Keeps the chosen number of old versions of each file.")
        case .staggered: String(localized: "Keeps versions with decreasing frequency (hourly, daily, weekly) for the chosen number of days.")
        }
    }

    /// Label for the stepper value, if this option has one.
    var keepLabel: ((Int) -> String)? {
        switch self {
        case .off: nil
        case .trashcan, .staggered: { String(localized: "Keep for \($0) days") }
        case .simple: { String(localized: "Keep \($0) versions") }
        }
    }

    func config(keep: Int) -> Versioning {
        switch self {
        case .off: .off
        case .trashcan: Versioning(type: "trashcan", params: ["cleanoutDays": String(keep)])
        case .simple: Versioning(type: "simple", params: ["keep": String(keep)])
        case .staggered: Versioning(type: "staggered", params: ["maxAge": String(keep * 86_400)])
        }
    }

    func keepValue(from versioning: Versioning) -> Int? {
        switch self {
        case .off: nil
        case .trashcan: versioning.params["cleanoutDays"].flatMap(Int.init)
        case .simple: versioning.params["keep"].flatMap(Int.init)
        case .staggered: versioning.params["maxAge"].flatMap(Int.init).map { max(1, $0 / 86_400) }
        }
    }
}
