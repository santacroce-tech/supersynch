import Foundation
import Observation

/// Root model: the embedded Syncthing engine, the live session that follows
/// it, and the network policy that can pause it. In demo/preview mode there
/// is no engine, only a mock session.
@MainActor
@Observable
public final class AppModel {
    public let engine: SyncEngine?
    public let session: SyncSession
    public let network: NetworkPolicy
    /// Set when the engine couldn't be created at all (e.g. disk full).
    public let setupError: String?

    public private(set) var isActive = false
    /// True while a background sync window is open.
    public private(set) var isBackgroundSyncing = false

    public init(engine: SyncEngine, network: NetworkPolicy = NetworkPolicy()) {
        self.engine = engine
        self.session = SyncSession(client: engine.client)
        self.network = network
        self.setupError = nil
        network.onChange = { [weak self] in
            Task { await self?.applyNetworkPolicy() }
        }
    }

    /// Without an engine (demo mode, previews, or a setup failure).
    public init(session: SyncSession, setupError: String? = nil,
                network: NetworkPolicy = NetworkPolicy(monitorPath: false)) {
        self.engine = nil
        self.session = session
        self.network = network
        self.setupError = setupError
    }

    public var deviceID: DeviceID? { engine?.deviceID ?? session.state.myID }

    /// Whether the engine should be running right now.
    private var wantsRunning: Bool { (isActive || isBackgroundSyncing) && network.allowsSync }

    /// Foreground: start the engine (if the network allows) and follow it.
    public func setActive(_ active: Bool) async {
        guard active != isActive else { return }
        isActive = active
        if active {
            await startIfAllowed()
        }
        // Going inactive is handled by the background coordinator, which
        // lets sync finish before calling `suspend()`.
    }

    /// Stops following and shuts the engine down (sockets closed, DB flushed).
    public func suspend() async {
        session.stop()
        await engine?.stop()
    }

    private func startIfAllowed() async {
        guard wantsRunning else { return }
        await engine?.start()
        if engine == nil || engine?.isRunning == true { session.start() }
    }

    func applyNetworkPolicy() async {
        if network.allowsSync {
            await startIfAllowed()
        } else if engine?.isRunning == true {
            await suspend()
        }
    }

    /// Starts the engine for a background sync window and waits until
    /// everything is in sync or `deadline` passes. Returns whether it reached idle.
    public func syncInBackground(until deadline: Date, settle: Duration = .seconds(5)) async -> Bool {
        guard network.allowsSync else { return false }
        isBackgroundSyncing = true
        defer { isBackgroundSyncing = false }
        if engine?.isRunning != true { await engine?.start() }
        session.start()
        // Give peers time to connect and exchange indexes before trusting "idle".
        try? await Task.sleep(for: settle)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if session.phase == .live, session.state.isSyncIdle, !session.state.folders.isEmpty { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }
}
