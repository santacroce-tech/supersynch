import SwiftUI
import SyncthingKit

/// What the server sheet is presenting.
enum ServerSheet: Identifiable {
    case manage
    case add
    case edit(ServerConfig)

    var id: String {
        switch self {
        case .manage: "manage"
        case .add: "add"
        case .edit(let s): "edit-\(s.id)"
        }
    }
}

/// Add, edit, reorder, remove and select servers.
struct ServerListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ServerSheet?
    @State private var pendingRemoval: ServerConfig?

    var body: some View {
        NavigationStack {
            List {
                ForEach(app.store.servers) { server in
                    Button {
                        app.selectedServerID = server.id
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.displayName).font(.headline).foregroundStyle(.primary)
                                Text(server.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary)
                                if server.pinnedFingerprint != nil {
                                    Label("Trusted self-signed certificate", systemImage: "lock.shield")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if server.id == app.selectedServerID {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                                    .accessibilityLabel(Text("Selected"))
                            }
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { pendingRemoval = server }
                        Button("Edit") { editing = .edit(server) }.tint(.blue)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = .edit(server) }
                        Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = server }
                    }
                }
                .onMove { app.store.move(fromOffsets: $0, toOffset: $1) }
            }
            .overlay {
                if app.store.servers.isEmpty {
                    ContentUnavailableView("No Servers", systemImage: "server.rack",
                                           description: Text("Add a Syncthing instance to get started."))
                }
            }
            .navigationTitle("Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Server", systemImage: "plus") { editing = .add }
                        .keyboardShortcut("n", modifiers: .command)
                }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            .sheet(item: $editing) { sheet in
                switch sheet {
                case .edit(let server): ServerEditorView(server: server)
                default: ServerEditorView(server: nil)
                }
            }
            .confirmationDialog("Remove Server?", isPresented: Binding(get: { pendingRemoval != nil },
                                                                     set: { if !$0 { pendingRemoval = nil } }),
                                titleVisibility: .visible, presenting: pendingRemoval) { server in
                Button("Remove \(server.displayName)", role: .destructive) { app.removeServer(server.id) }
            } message: { _ in
                Text("The server and its API key are removed from this device. Syncthing itself is not affected.")
            }
        }
    }
}

/// Form for adding or editing a server, with connection validation and the
/// certificate trust flow.
struct ServerEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: ServerEditorModel
    @State private var showKey = false
    @FocusState private var focus: Field?

    enum Field { case name, url, key }

    init(server: ServerConfig?) {
        _model = State(initialValue: ServerEditorModel(editing: server))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $model.name)
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .url }
                    TextField("https://192.168.1.10:8384", text: $model.urlText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .url)
                        .submitLabel(.next)
                        .onSubmit { focus = .key }
                        .accessibilityLabel(Text("Server Address"))
                } header: {
                    Text("Server")
                } footer: {
                    Text("The address of Syncthing's web GUI, including the port (usually 8384). Plain http:// is allowed only on the local network.")
                }

                Section {
                    HStack {
                        Group {
                            if showKey {
                                TextField("API Key", text: $model.apiKey)
                            } else {
                                SecureField("API Key", text: $model.apiKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .focused($focus, equals: .key)
                        .submitLabel(.done)
                        .onSubmit { Task { await save() } }
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showKey ? Text("Hide API Key") : Text("Show API Key"))
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("In the Syncthing web GUI, open Actions → Settings → General and copy the API Key. It is stored only in this device's Keychain.")
                }

                Section {
                    Button("Paste Configuration", systemImage: "doc.on.clipboard") {
                        if let text = UIPasteboard.general.string { _ = model.apply(importPayload: text) }
                    }
                } footer: {
                    Text("Pastes a JSON object like {\"name\": …, \"url\": …, \"apiKey\": …}.")
                }

                if let fingerprint = model.trustedFingerprint {
                    Section("Trusted Certificate") {
                        Text(CertificateInfo(sha256: fingerprint, subject: "", host: "").formattedFingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if let error = model.error {
                    Section {
                        Label {
                            Text(error.localizedDescription)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                        .font(.callout)
                    }
                }

                if let validated = model.validated {
                    Section {
                        Label("Connected to Syncthing \(validated.version.version)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle(model.isEditing ? "Edit Server" : "Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isValidating {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(!model.canSubmit)
                    }
                }
            }
            .disabled(model.isValidating)
            .sheet(item: $model.certificateToReview) { info in
                CertificateTrustSheet(info: info, changed: model.certificateChanged) {
                    Task {
                        if let saved = await model.trust(info, andSaveTo: app.store) { finish(saved) }
                    }
                } onReject: {
                    model.rejectReviewedCertificate()
                }
                .interactiveDismissDisabled()
            }
            .onAppear {
                if let id = model.existingID { model.apiKey = app.store.apiKey(for: id) ?? "" }
                if !model.isEditing { focus = .url }
            }
        }
    }

    private func save() async {
        guard model.canSubmit else { return }
        if let saved = await model.validateAndSave(to: app.store) { finish(saved) }
    }

    private func finish(_ server: ServerConfig) {
        app.serverDidChange(server.id)
        app.selectedServerID = server.id
        dismiss()
    }
}

/// Shows a server's certificate fingerprint and asks the user to trust it.
struct CertificateTrustSheet: View {
    let info: CertificateInfo
    let changed: Bool
    let onTrust: () -> Void
    let onReject: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(changed
                             ? "The certificate presented by \(info.host) is different from the one you trusted before. Only continue if you know it was regenerated."
                             : "\(info.host) uses a certificate that isn't signed by a trusted authority. Syncthing generates a self-signed certificate for its GUI by default.")
                    } icon: {
                        Image(systemName: changed ? "exclamationmark.shield.fill" : "lock.shield")
                            .foregroundStyle(changed ? .red : .orange)
                    }
                }
                Section("Certificate") {
                    InfoRow(title: "Host", value: info.host)
                    if !info.subject.isEmpty { InfoRow(title: "Subject", value: info.subject) }
                }
                Section {
                    Text(info.formattedFingerprint)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .accessibilityLabel(Text("SHA-256 fingerprint"))
                } header: {
                    Text("SHA-256 Fingerprint")
                } footer: {
                    Text("Compare with the fingerprint on the server: openssl x509 -noout -fingerprint -sha256 -in https-cert.pem (in Syncthing's config directory).")
                }
            }
            .navigationTitle(changed ? "Certificate Changed" : "Trust Certificate?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Don't Trust") { onReject(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust") { onTrust(); dismiss() }
                        .tint(changed ? .red : nil)
                }
            }
        }
    }
}
