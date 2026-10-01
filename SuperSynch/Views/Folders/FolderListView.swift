import SwiftUI
import SyncthingKit

struct FolderListView: View {
    let session: SyncSession
    var selection: Binding<Route?>?
    @State private var adding = false

    var body: some View {
        SelectableList(selection: selection) {
            ForEach(session.state.folders) { folder in
                NavigationLink(value: Route.folder(folder.id)) {
                    FolderRow(folder: folder, session: session)
                }
                .swipeActions {
                    Button {
                        Task { await session.rescan(folder: folder.id) }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .tint(.blue)
                    .disabled(folder.paused)
                    Button {
                        Task { await session.setFolderPaused(folder.id, paused: !folder.paused) }
                    } label: {
                        folder.paused
                            ? Label("Resume", systemImage: "play.fill")
                            : Label("Pause", systemImage: "pause.fill")
                    }
                    .tint(.gray)
                }
            }
        }
        .navigationTitle("Folders")
        .refreshable { await session.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Folder", systemImage: "plus") { adding = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        .sheet(isPresented: $adding) { FolderEditorView(session: session) }
        .overlay {
            if session.state.folders.isEmpty {
                if session.state.status == nil {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        Label("No Folders Yet", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Create a folder to share with your Mac, or accept one your Mac shares with this device.")
                    } actions: {
                        Button("New Folder") { adding = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
}

struct FolderRow: View {
    let folder: FolderConfig
    let session: SyncSession

    var body: some View {
        let state = session.state.folderState(folder.id)
        let style = StateStyle(state)
        let status = session.state.folderStatuses[folder.id]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(folder.displayName).font(.headline)
                Spacer()
                StateBadge(state)
            }
            if let percent = progress(state, status) {
                CompletionBar(percent: percent, color: style.color)
                HStack {
                    Text(Format.percent(percent))
                    Spacer()
                    if let status, status.needBytes > 0 {
                        Text("\(Format.bytes(status.needBytes)) remaining")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else if let status {
                Text("\(Format.count(status.globalFiles)) files · \(Format.bytes(status.globalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func progress(_ state: FolderSyncState, _ status: FolderStatus?) -> Double? {
        switch state {
        case .syncing(let p): p
        case .scanning(let p): p
        case .outOfSync: status?.completion
        default: nil
        }
    }
}
