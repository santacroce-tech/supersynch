import SwiftUI
import SyncthingKit

/// Chooses the presentation by horizontal size class (not device idiom), so
/// iPad Split View / Slide Over / Stage Manager narrow windows get the stack
/// layout automatically. Everything below this file is shared.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var serverSheet: ServerSheet?
    @State private var section: AppSection? = .dashboard
    @State private var route: Route?
    @State private var sectionRequest: SectionRequest?

    var body: some View {
        Group {
            if let session = app.selectedSession {
                Group {
                    if sizeClass == .regular {
                        PadRootView(session: session, section: $section, route: $route,
                                    onManageServers: { serverSheet = .manage },
                                    onEditServer: { serverSheet = .edit(session.server) })
                    } else {
                        PhoneRootView(session: session, sectionRequest: sectionRequest,
                                      onManageServers: { serverSheet = .manage },
                                      onEditServer: { serverSheet = .edit(session.server) })
                    }
                }
                .id(session.id)
                .focusedSceneValue(\.serverCommands, commands(for: session))
                .alert(isPresented: actionErrorBinding(session), error: session.actionError) {
                    Button("OK") { session.actionError = nil }
                }
            } else {
                WelcomeView { serverSheet = .add }
            }
        }
        .sheet(item: $serverSheet) { sheet in
            switch sheet {
            case .manage: ServerListView()
            case .add: ServerEditorView(server: nil)
            case .edit(let server): ServerEditorView(server: server)
            }
        }
        .task {
            // Demo-only: `-DemoSection folders` opens a section for screenshots.
            if AppEnvironment.isDemo, let raw = UserDefaults.standard.string(forKey: "DemoSection"),
               let requested = AppSection(rawValue: raw) {
                try? await Task.sleep(for: .milliseconds(300))
                section = requested
                sectionRequest = SectionRequest(section: requested)
                if let folder = UserDefaults.standard.string(forKey: "DemoFolder") {
                    try? await Task.sleep(for: .milliseconds(300))
                    route = .folder(folder)
                }
            }
        }
        .onChange(of: app.selectedServerID) {
            section = .dashboard
            route = nil
        }
    }

    private func commands(for session: ServerSession) -> ServerCommandActions {
        ServerCommandActions(
            refresh: { Task { await session.refresh() } },
            rescanAll: { Task { await session.rescanAll() } },
            select: { requested in
                section = requested
                route = nil
                sectionRequest = SectionRequest(section: requested)
            }
        )
    }

    private func actionErrorBinding(_ session: ServerSession) -> Binding<Bool> {
        Binding(get: { session.actionError != nil }, set: { if !$0 { session.actionError = nil } })
    }
}

/// A one-shot request to show a section (from a keyboard shortcut).
struct SectionRequest: Equatable {
    let section: AppSection
    let nonce = UUID()
}

/// Content for a section. Used as the content column on iPad and as a
/// pushed screen on iPhone.
struct SectionView: View {
    let section: AppSection
    let session: ServerSession
    var selection: Binding<Route?>?
    var onEditServer: (() -> Void)?

    var body: some View {
        Group {
            switch section {
            case .dashboard: DashboardView(session: session, selection: selection)
            case .folders: FolderListView(session: session, selection: selection)
            case .devices: DeviceListView(session: session, selection: selection)
            case .pending: PendingView(session: session)
            }
        }
        .connectionBanner(session, onEditServer: onEditServer)
    }
}

struct WelcomeView: View {
    let onAddServer: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Welcome to SuperSynch", systemImage: "arrow.triangle.2.circlepath.circle")
            } description: {
                Text("Monitor and control Syncthing running on your NAS, home server or VPS. Add a server using its web GUI address and API key.")
            } actions: {
                Button("Add Server", action: onAddServer)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
