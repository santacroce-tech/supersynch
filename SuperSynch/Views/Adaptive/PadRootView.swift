import SwiftUI
import SyncthingKit

/// Regular width (iPad full screen / large Stage Manager windows):
/// three-column master-detail. Thin adapter over shared views.
struct PadRootView: View {
    let session: ServerSession
    @Binding var section: AppSection?
    @Binding var route: Route?
    let onManageServers: () -> Void
    let onEditServer: () -> Void

    @State private var detailPath = NavigationPath()

    var body: some View {
        NavigationSplitView {
            SidebarView(session: session, selection: $section, onManageServers: onManageServers)
        } content: {
            SectionView(section: section ?? .dashboard, session: session, selection: $route, onEditServer: onEditServer)
        } detail: {
            NavigationStack(path: $detailPath) {
                Group {
                    if let route {
                        RouteDestination(route: route, session: session).id(route)
                    } else {
                        ContentUnavailableView("Nothing Selected", systemImage: "sidebar.squares.left",
                                               description: Text("Select a folder or device to see its details."))
                    }
                }
                .navigationDestination(for: DetailRoute.self) { DetailRouteDestination(route: $0, session: session) }
            }
        }
        .onChange(of: route) { detailPath = NavigationPath() }
        .onChange(of: section) { route = nil }
    }
}
