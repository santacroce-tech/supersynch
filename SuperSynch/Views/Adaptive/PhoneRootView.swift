import SwiftUI
import SyncthingKit

/// Compact width (iPhone, narrow iPad multitasking windows): a single
/// navigation stack. Thin adapter over shared views.
struct PhoneRootView: View {
    let session: ServerSession
    let sectionRequest: SectionRequest?
    let onManageServers: () -> Void
    let onEditServer: () -> Void

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            SidebarView(session: session, selection: nil, onManageServers: onManageServers)
                .connectionBanner(session, onEditServer: onEditServer)
                .refreshable { await session.refresh() }
                .navigationDestination(for: AppSection.self) { section in
                    SectionView(section: section, session: session, onEditServer: onEditServer)
                }
                .navigationDestination(for: Route.self) { RouteDestination(route: $0, session: session) }
                .navigationDestination(for: DetailRoute.self) { DetailRouteDestination(route: $0, session: session) }
        }
        .onChange(of: sectionRequest) {
            guard let sectionRequest else { return }
            path = NavigationPath([sectionRequest.section])
        }
    }
}
