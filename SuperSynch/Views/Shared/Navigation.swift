import SwiftUI
import SyncthingKit

/// Top-level areas of a server. Same information architecture on all idioms.
enum AppSection: String, Hashable, CaseIterable, Identifiable {
    case dashboard, folders, devices, pending

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: "Dashboard"
        case .folders: "Folders"
        case .devices: "Devices"
        case .pending: "Pending Requests"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .folders: "folder"
        case .devices: "laptopcomputer.and.iphone"
        case .pending: "person.crop.circle.badge.questionmark"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .dashboard: "1"
        case .folders: "2"
        case .devices: "3"
        case .pending: "4"
        }
    }
}

/// Items selectable from a section list (content column on iPad).
enum Route: Hashable {
    case folder(FolderID)
    case device(DeviceID)
}

/// Screens pushed from within a detail view.
enum DetailRoute: Hashable {
    case outOfSync(FolderID)
}

/// Resolves a `Route` to its detail view. Shared by both idioms.
struct RouteDestination: View {
    let route: Route
    let session: ServerSession

    var body: some View {
        switch route {
        case .folder(let id): FolderDetailView(session: session, folderID: id)
        case .device(let id): DeviceDetailView(session: session, deviceID: id)
        }
    }
}

struct DetailRouteDestination: View {
    let route: DetailRoute
    let session: ServerSession

    var body: some View {
        switch route {
        case .outOfSync(let id): OutOfSyncView(session: session, folderID: id)
        }
    }
}

/// Renders a list either with selection (split view content column) or
/// without (stack), so row views stay identical across idioms.
struct SelectableList<SelectionValue: Hashable, Content: View>: View {
    let selection: Binding<SelectionValue?>?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let selection {
            List(selection: selection, content: content)
        } else {
            List(content: content)
        }
    }
}

// MARK: - Keyboard commands

struct ServerCommandActions {
    var refresh: () -> Void
    var rescanAll: () -> Void
    var select: (AppSection) -> Void
}

struct ServerCommandActionsKey: FocusedValueKey {
    typealias Value = ServerCommandActions
}

extension FocusedValues {
    var serverCommands: ServerCommandActions? {
        get { self[ServerCommandActionsKey.self] }
        set { self[ServerCommandActionsKey.self] = newValue }
    }
}

struct ServerCommands: Commands {
    @FocusedValue(\.serverCommands) private var actions

    var body: some Commands {
        CommandMenu("Server") {
            Button("Refresh") { actions?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions == nil)
            Button("Rescan All Folders") { actions?.rescanAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Divider()
            ForEach(AppSection.allCases) { section in
                Button(section.title) { actions?.select(section) }
                    .keyboardShortcut(section.shortcut, modifiers: .command)
                    .disabled(actions == nil)
            }
        }
    }
}
