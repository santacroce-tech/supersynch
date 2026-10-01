import SwiftUI
import SyncthingKit

/// Chooses the presentation by horizontal size class (not device idiom), so
/// iPad Split View / Slide Over / Stage Manager narrow windows get the stack
/// layout automatically. Everything below this file is shared.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var section: AppSection? = .dashboard
    @State private var route: Route?
    @State private var sectionRequest: SectionRequest?

    var body: some View {
        let session = app.session
        Group {
            if sizeClass == .regular {
                PadRootView(session: session, section: $section, route: $route)
            } else {
                PhoneRootView(session: session, sectionRequest: sectionRequest)
            }
        }
        .focusedSceneValue(\.serverCommands, commands(for: session))
        .alert(isPresented: actionErrorBinding(session), error: session.actionError) {
            Button("OK") { session.actionError = nil }
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
    }

    private func commands(for session: SyncSession) -> ServerCommandActions {
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

    private func actionErrorBinding(_ session: SyncSession) -> Binding<Bool> {
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
    let session: SyncSession
    var selection: Binding<Route?>?

    var body: some View {
        Group {
            switch section {
            case .dashboard: DashboardView(session: session, selection: selection)
            case .folders: FolderListView(session: session, selection: selection)
            case .devices: DeviceListView(session: session, selection: selection)
            case .pending: PendingView(session: session)
            case .settings: SettingsView(session: session)
            }
        }
        .connectionBanner()
    }
}
