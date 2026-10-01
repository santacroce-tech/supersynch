import SwiftUI
import SyncthingKit

struct FolderDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let session: SyncSession
    let folderID: FolderID
    @State private var editing = false
    @State private var confirmRemove = false

    var body: some View {
        if let folder = session.state.folder(folderID) {
            content(folder)
        } else {
            ContentUnavailableView("Folder Not Found", systemImage: "folder.badge.questionmark",
                                   description: Text("It may have been removed from this server."))
        }
    }

    @ViewBuilder
    private func content(_ folder: FolderConfig) -> some View {
        let state = session.state.folderState(folderID)
        let status = session.state.folderStatuses[folderID]
        let stats = session.state.folderStats[folderID]
        List {
            Section {
                HStack {
                    StateBadge(state).font(.title3)
                    Spacer()
                    if let status { Text(Format.percent(status.completion)).monospacedDigit().foregroundStyle(.secondary) }
                }
                if let status, !folder.paused {
                    CompletionBar(percent: status.completion, color: StateStyle(state).color)
                }
                if case .scanning(let p?) = state, let progress = session.state.scanProgress[folderID] {
                    Text("Scanning \(Format.percent(p)) at \(Format.rate(progress.rate))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = status?.error, !error.isEmpty {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }

            Section("Actions") {
                NavigationLink(value: DetailRoute.browse(folderID, subpath: "")) {
                    Label("Browse Files", systemImage: "folder")
                }
                Button {
                    Task { await session.rescan(folder: folderID) }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(folder.paused)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Button {
                    Task { await session.setFolderPaused(folderID, paused: !folder.paused) }
                } label: {
                    folder.paused
                        ? Label("Resume Folder", systemImage: "play.fill")
                        : Label("Pause Folder", systemImage: "pause.fill")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            if let status {
                Section("Contents") {
                    InfoRow(title: "Global", value: summary(files: status.globalFiles, dirs: status.globalDirectories, bytes: status.globalBytes))
                    InfoRow(title: "Local", value: summary(files: status.localFiles, dirs: status.localDirectories, bytes: status.localBytes))
                    if status.needTotalItems > 0 || status.needBytes > 0 {
                        NavigationLink(value: DetailRoute.outOfSync(folderID)) {
                            LabeledContent("Out of Sync") {
                                Text("\(Format.count(status.needTotalItems)) items, \(Format.bytes(status.needBytes))")
                                    .foregroundStyle(.orange)
                            }
                        }
                    } else {
                        InfoRow(title: "Out of Sync", value: String(localized: "None"))
                    }
                    if status.receiveOnlyTotalItems > 0 {
                        InfoRow(title: "Locally Changed", value: Format.count(status.receiveOnlyTotalItems))
                    }
                }
            }

            let errors = session.state.folderErrors[folderID] ?? []
            if !errors.isEmpty {
                Section {
                    ForEach(errors, id: \.self) { error in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(error.path).font(.callout.monospaced())
                            Text(error.error).font(.caption).foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                    }
                } header: {
                    Label("Failed Items (\(errors.count))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Manage") {
                NavigationLink(value: DetailRoute.ignores(folderID)) {
                    Label("Ignore Patterns", systemImage: "eye.slash")
                }
                .disabled(folder.paused)
                if !folder.versioning.type.isEmpty {
                    NavigationLink(value: DetailRoute.versions(folderID)) {
                        Label("File Versions", systemImage: "clock.arrow.circlepath")
                    }
                }
                NavigationLink(value: DetailRoute.conflicts(folderID)) {
                    Label("Conflicts", systemImage: "exclamationmark.2")
                }
                if folder.type == "sendonly", let status, status.needTotalItems > 0 {
                    Button {
                        Task { await session.overrideRemoteChanges(folderID) }
                    } label: {
                        Label("Override Changes", systemImage: "arrow.up.circle")
                    }
                }
                if folder.type == "receiveonly", let status, status.receiveOnlyTotalItems > 0 {
                    Button(role: .destructive) {
                        Task { await session.revertLocalChanges(folderID) }
                    } label: {
                        Label("Revert Local Changes", systemImage: "arrow.uturn.backward.circle")
                    }
                }
            }

            Section("Details") {
                InfoRow(title: "Folder ID", value: folder.id, monospaced: true)
                InfoRow(title: "Path", value: folder.path, monospaced: true)
                InfoRow(title: "Type", value: folder.typeDescription)
                InfoRow(title: "Last Scan", value: Format.relative(stats?.lastScan))
                if let name = stats?.lastFileName {
                    InfoRow(title: "Last File", value: name)
                }
                InfoRow(title: "Rescan Interval", value: Format.uptime(seconds: folder.rescanIntervalS))
                InfoRow(title: "File Watcher", value: folder.fsWatcherEnabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                InfoRow(title: "Versioning", value: VersioningOption(folder.versioning).title)
            }

            let shared = folder.deviceIDs.filter { $0 != session.state.myID }
            if !shared.isEmpty {
                Section("Shared With") {
                    ForEach(shared, id: \.self) { deviceID in
                        RemoteCompletionRow(session: session, deviceID: deviceID,
                                            completion: session.state.remoteFolderCompletion[deviceID]?[folderID])
                    }
                }
            }
            Section {
                Button("Remove Folder", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(folder.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task(id: folderID) { await reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
        }
        .sheet(isPresented: $editing) { FolderEditorView(session: session, existing: folder) }
        .confirmationDialog("Remove \(folder.displayName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Folder", role: .destructive) {
                Task {
                    if await session.removeFolder(folderID) {
                        app.engine?.externalFolders.unregister(folderID)
                        dismiss()
                    }
                }
            }
        } message: {
            Text("The folder stops syncing. Its files stay on this device and can be deleted in the Files app.")
        }
    }

    private func reload() async {
        await session.loadFolderErrors(folderID)
        await session.loadRemoteCompletion(folder: folderID)
    }

    private func summary(files: Int, dirs: Int, bytes: Int64) -> String {
        String(localized: "\(Format.count(files)) files, \(Format.count(dirs)) folders, \(Format.bytes(bytes))")
    }
}

struct RemoteCompletionRow: View {
    let session: SyncSession
    let deviceID: DeviceID
    let completion: Completion?

    var body: some View {
        let connected = session.state.connections[deviceID]?.connected == true
        HStack {
            Text(session.state.deviceName(deviceID))
            Spacer()
            if !connected {
                Text("Disconnected").foregroundStyle(.secondary)
            } else if let completion {
                switch completion.remoteState {
                case "notSharing": Text("Not Shared Back").foregroundStyle(.orange)
                case "paused": Text("Paused").foregroundStyle(.secondary)
                default: Text(Format.percent(completion.completion)).monospacedDigit()
                }
            }
        }
        .font(.callout)
    }
}

struct OutOfSyncView: View {
    let session: SyncSession
    let folderID: FolderID

    @State private var need: NeedResponse?
    @State private var error: SyncthingError?

    var body: some View {
        List {
            if let need {
                section("In Progress", need.progress)
                section("Queued", need.queued)
                section("Remaining", need.rest)
                if need.all.count >= need.perpage, need.perpage > 0 {
                    Text("Showing the first \(need.perpage) items.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if let error {
                ContentUnavailableView("Couldn't Load Items", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            } else if need == nil {
                ProgressView()
            } else if need?.all.isEmpty == true {
                ContentUnavailableView("Nothing Out of Sync", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("Out of Sync")
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ files: [NeededFile]) -> some View {
        if !files.isEmpty {
            Section(title) {
                ForEach(files, id: \.self) { file in
                    HStack {
                        Image(systemName: file.deleted ? "trash" : "doc").foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(file.name).font(.callout).lineLimit(2).truncationMode(.middle)
                        Spacer()
                        Text(Format.bytes(file.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func load() async {
        do {
            need = try await session.loadNeed(folderID)
            error = nil
        } catch {
            self.error = SyncthingError(error)
        }
    }
}
