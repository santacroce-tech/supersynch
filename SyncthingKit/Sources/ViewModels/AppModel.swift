import Foundation
import Observation

/// Root model: saved servers, the selected one, and one `ServerSession` per
/// server. Only the selected session runs, and only while the app is active.
@MainActor
@Observable
public final class AppModel {
    public let store: ServerStore
    public typealias ClientFactory = @Sendable (ServerEndpoint) -> SyncthingAPIClient

    public var selectedServerID: UUID? {
        didSet {
            guard selectedServerID != oldValue else { return }
            defaults.set(selectedServerID?.uuidString, forKey: selectionKey)
            activateSelection(previous: oldValue)
        }
    }

    public private(set) var isActive = false

    private var sessions: [UUID: ServerSession] = [:]
    private let clientFactory: ClientFactory
    private let defaults: UserDefaults
    private let selectionKey = "selectedServer.v1"

    public init(
        store: ServerStore,
        defaults: UserDefaults = .standard,
        clientFactory: @escaping ClientFactory = { SyncthingHTTPClient(endpoint: $0) }
    ) {
        self.store = store
        self.defaults = defaults
        self.clientFactory = clientFactory
        let saved = defaults.string(forKey: selectionKey).flatMap(UUID.init(uuidString:))
        selectedServerID = saved.flatMap { store.server(id: $0) != nil ? $0 : nil } ?? store.servers.first?.id
    }

    public var selectedSession: ServerSession? {
        selectedServerID.flatMap(session(for:))
    }

    public func session(for id: UUID) -> ServerSession? {
        if let existing = sessions[id] { return existing }
        guard let server = store.server(id: id), let endpoint = store.endpoint(for: id) else { return nil }
        let session = ServerSession(server: server, client: clientFactory(endpoint))
        sessions[id] = session
        return session
    }

    /// Call from the scene-phase observer: live updates stop in the background.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { selectedSession?.start() } else { sessions.values.forEach { $0.stop() } }
    }

    /// Invalidate a server's session after its URL, key or pin changed.
    public func serverDidChange(_ id: UUID) {
        sessions[id]?.stop()
        sessions[id] = nil
        if id == selectedServerID, isActive { selectedSession?.start() }
    }

    public func removeServer(_ id: UUID) {
        sessions[id]?.stop()
        sessions[id] = nil
        store.remove(id: id)
        if selectedServerID == id { selectedServerID = store.servers.first?.id }
    }

    private func activateSelection(previous: UUID?) {
        if let previous { sessions[previous]?.stop() }
        if isActive { selectedSession?.start() }
    }
}
