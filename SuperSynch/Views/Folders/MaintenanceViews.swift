import QuickLook
import SwiftUI
import SyncthingKit

/// Edit a folder's `.stignore` patterns. Also the way to sync only part of a
/// folder ("selective sync"): ignored files are never downloaded.
struct IgnorePatternsView: View {
    let session: SyncSession
    let folderID: FolderID

    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var loadError: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 200)
                    .accessibilityLabel(Text("Ignore patterns"))
            } header: {
                Text("One pattern per line")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ignored files aren't synced. To sync only part of a folder, ignore everything else:")
                    Text("!/Photos\n*").font(.caption.monospaced())
                    Text("Other examples: `*.tmp`, `(?d).DS_Store`, `/build`. Patterns are shared with other devices only if you sync the .stignore file yourself.")
                }
            }
            Section {
                Button("Insert Common Patterns") {
                    let common = ["(?d).DS_Store", "(?d)Thumbs.db", "(?d)._*", "*.tmp", "*.part"]
                    let existing = Set(text.split(separator: "\n").map(String.init))
                    let additions = common.filter { !existing.contains($0) }
                    text = (text.isEmpty ? "" : text + "\n") + additions.joined(separator: "\n")
                }
            }
        }
        .navigationTitle("Ignore Patterns")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading { ProgressView() }
            if let loadError {
                ContentUnavailableView("Can't Load Patterns", systemImage: "exclamationmark.triangle", description: Text(loadError))
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saving = true
                    Task {
                        let lines = text.split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        if await session.saveIgnores(folderID, lines: lines) { original = text }
                        saving = false
                    }
                }
                .disabled(saving || loading || text == original)
            }
        }
        .task {
            do {
                let patterns = try await session.loadIgnores(folderID)
                text = patterns.lines.joined(separator: "\n")
                original = text
            } catch {
                loadError = SyncthingError(error).localizedDescription
            }
            loading = false
        }
    }
}

/// Browse archived file versions (folder versioning) and restore them.
struct VersionsView: View {
    let session: SyncSession
    let folderID: FolderID

    @State private var versions: [String: [FileVersion]] = [:]
    @State private var loading = true
    @State private var loadError: String?
    @State private var restoring: String?
    @State private var restored: Set<String> = []

    private var paths: [String] { versions.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    var body: some View {
        List {
            ForEach(paths, id: \.self) { path in
                Section(path) {
                    ForEach(versions[path] ?? [], id: \.self) { version in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(version.versionTime, format: .dateTime)
                                Text("\(Format.bytes(version.size))\(version.modTime.map { " · " + String(localized: "modified \($0.formatted(.dateTime))") } ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if restoring == path + version.versionTimeRaw {
                                ProgressView()
                            } else {
                                Button("Restore") {
                                    restoring = path + version.versionTimeRaw
                                    Task {
                                        if await session.restore(path, version: version, in: folderID) {
                                            restored.insert(path)
                                            await load()
                                        }
                                        restoring = nil
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    if restored.contains(path) {
                        Label("Restored", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    }
                }
            }
        }
        .overlay {
            if loading {
                ProgressView()
            } else if let loadError {
                ContentUnavailableView("Can't Load Versions", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if versions.isEmpty {
                ContentUnavailableView("No Old Versions", systemImage: "clock.arrow.circlepath",
                                       description: Text("When files are changed or deleted by other devices, previous versions appear here."))
            }
        }
        .navigationTitle("File Versions")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            versions = try await session.loadVersions(folderID)
            loadError = nil
        } catch {
            loadError = SyncthingError(error).localizedDescription
        }
        loading = false
    }
}

/// Lists sync conflicts (`*.sync-conflict-*` copies) and resolves them by
/// keeping either version.
struct ConflictsView: View {
    let session: SyncSession
    let folderID: FolderID

    @State private var conflicts: [Conflict] = []
    @State private var previewURL: URL?
    @State private var error: String?

    struct Conflict: Identifiable, Hashable {
        let conflictURL: URL
        let originalURL: URL
        let relativePath: String
        var id: URL { conflictURL }
    }

    var body: some View {
        List {
            ForEach(conflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Text(conflict.relativePath).font(.callout.monospaced()).lineLimit(3)
                    HStack {
                        Button("Preview Conflict") { previewURL = conflict.conflictURL }
                        Spacer()
                        Menu("Resolve") {
                            Button("Keep This Device's Version") { resolve(conflict, keepConflict: false) }
                            Button("Keep Conflicting Version") { resolve(conflict, keepConflict: true) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .overlay {
            if conflicts.isEmpty {
                ContentUnavailableView("No Conflicts", systemImage: "checkmark.circle",
                                       description: Text("When a file is changed on two devices at once, Syncthing keeps both and the copy appears here."))
            }
        }
        .navigationTitle("Conflicts")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't Resolve", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .refreshable { load() }
        .onAppear(perform: load)
        .quickLookPreview($previewURL)
    }

    private func load() {
        guard let folder = session.state.folder(folderID) else { return }
        conflicts = Self.find(in: URL(filePath: folder.path, directoryHint: .isDirectory))
    }

    static func find(in root: URL) -> [Conflict] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var found: [Conflict] = []
        for case let url as URL in enumerator where ConflictName.isConflict(url.lastPathComponent) {
            guard let originalName = ConflictName.original(of: url.lastPathComponent) else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            found.append(Conflict(conflictURL: url, originalURL: url.deletingLastPathComponent().appending(path: originalName),
                                  relativePath: relative))
        }
        return found.sorted { $0.relativePath < $1.relativePath }
    }

    private func resolve(_ conflict: Conflict, keepConflict: Bool) {
        do {
            let fm = FileManager.default
            if keepConflict {
                if fm.fileExists(atPath: conflict.originalURL.path) {
                    _ = try fm.replaceItemAt(conflict.originalURL, withItemAt: conflict.conflictURL)
                } else {
                    try fm.moveItem(at: conflict.conflictURL, to: conflict.originalURL)
                }
            } else {
                try fm.removeItem(at: conflict.conflictURL)
            }
            Task { await session.rescan(folder: folderID) }
            load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Recent warnings and errors from Syncthing's log.
struct LogView: View {
    let session: SyncSession
    @State private var entries: [LogEntry] = []

    var body: some View {
        List(entries.reversed(), id: \.self) { entry in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Image(systemName: entry.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(entry.isError ? .red : .orange)
                        .accessibilityLabel(entry.isError ? Text("Error") : Text("Warning"))
                    if let when = entry.when {
                        Text(when, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(entry.message).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No Warnings", systemImage: "checkmark.circle",
                                       description: Text("Warnings and errors from Syncthing appear here."))
            }
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: entries.map { "\($0.when?.formatted(.iso8601) ?? "") \($0.message)" }.joined(separator: "\n"))
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        entries = (try? await session.client.systemLog()) ?? []
    }
}
