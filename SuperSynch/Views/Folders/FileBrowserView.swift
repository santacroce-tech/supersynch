import QuickLook
import SwiftUI
import SyncthingKit

/// Browses the local copy of a synced folder: navigate directories, preview
/// files with Quick Look, share them, or open them in the Files app.
struct FileBrowserView: View {
    let session: SyncSession
    let folderID: FolderID
    let subpath: String

    @State private var entries: [Entry] = []
    @State private var loadError: String?
    @State private var previewURL: URL?

    struct Entry: Identifiable, Hashable {
        let url: URL
        let isDirectory: Bool
        let size: Int64
        let modified: Date?
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    /// Syncthing's own bookkeeping files aren't shown.
    static let hidden: Set<String> = [".stfolder", ".stversions", ".stignore", ".stglobalignore"]

    private var directory: URL? {
        guard let folder = session.state.folder(folderID) else { return nil }
        let root = URL(filePath: folder.path, directoryHint: .isDirectory)
        return subpath.isEmpty ? root : root.appending(path: subpath, directoryHint: .isDirectory)
    }

    var body: some View {
        List {
            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink(value: DetailRoute.browse(folderID, subpath: childPath(entry.name))) {
                        row(entry)
                    }
                } else {
                    Button { previewURL = entry.url } label: { row(entry) }
                        .contextMenu {
                            ShareLink(item: entry.url)
                        }
                }
            }
        }
        .overlay {
            if let loadError {
                ContentUnavailableView("Can't Open Folder", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else if entries.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder",
                                       description: Text("Files appear here once they've synced."))
            }
        }
        .navigationTitle(subpath.isEmpty ? (session.state.folder(folderID)?.displayName ?? "") : (subpath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { load() }
        .onAppear(perform: load)
        .onChange(of: session.state.folderStatuses[folderID]?.localTotalItems) { load() }
        .quickLookPreview($previewURL, in: entries.filter { !$0.isDirectory }.map(\.url))
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : icon(for: entry.name))
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).foregroundStyle(.primary).lineLimit(2)
                HStack(spacing: 6) {
                    if !entry.isDirectory { Text(Format.bytes(entry.size)) }
                    if let modified = entry.modified { Text(modified, format: .dateTime.day().month().year()) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func childPath(_ name: String) -> String {
        subpath.isEmpty ? name : subpath + "/" + name
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": "photo"
        case "mov", "mp4", "m4v": "film"
        case "mp3", "m4a", "wav", "flac", "aac": "music.note"
        case "pdf": "doc.richtext"
        case "zip", "gz", "tar", "7z": "doc.zipper"
        case "txt", "md", "rtf": "doc.text"
        default: "doc"
        }
    }

    private func load() {
        guard let directory else {
            loadError = String(localized: "This folder no longer exists.")
            return
        }
        do {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
            entries = urls.compactMap { url -> Entry? in
                guard !Self.hidden.contains(url.lastPathComponent),
                      !url.lastPathComponent.hasPrefix(".syncthing.") else { return nil }
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Entry(url: url, isDirectory: values?.isDirectory ?? false,
                             size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
