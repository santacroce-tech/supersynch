import Foundation
import Observation

/// Root model: the embedded Syncthing engine and the live session that
/// follows it. In demo/preview mode there is no engine, only a mock session.
@MainActor
@Observable
public final class AppModel {
    public let engine: SyncEngine?
    public let session: SyncSession
    /// Set when the engine couldn't be created at all (e.g. disk full).
    public let setupError: String?

    public private(set) var isActive = false

    public init(engine: SyncEngine) {
        self.engine = engine
        self.session = SyncSession(client: engine.client)
        self.setupError = nil
    }

    /// Without an engine (demo mode, previews, or a setup failure).
    public init(session: SyncSession, setupError: String? = nil) {
        self.engine = nil
        self.session = session
        self.setupError = setupError
    }

    public var deviceID: DeviceID? { engine?.deviceID ?? session.state.myID }

    /// Foreground: start the engine and follow it.
    public func setActive(_ active: Bool) async {
        guard active != isActive else { return }
        isActive = active
        if active {
            await engine?.start()
            if engine == nil || engine?.isRunning == true { session.start() }
        }
        // Going inactive is handled by the background coordinator, which
        // lets sync finish before calling `suspend()`.
    }

    /// Stops following and shuts the engine down (sockets closed, DB flushed).
    public func suspend() async {
        session.stop()
        await engine?.stop()
    }

    /// Starts the engine for a background sync window and waits until
    /// everything is in sync or `deadline` passes. Returns whether it reached idle.
    public func syncInBackground(until deadline: Date, settle: Duration = .seconds(5)) async -> Bool {
        if engine?.isRunning != true { await engine?.start() }
        session.start()
        // Give peers time to connect and exchange indexes before trusting "idle".
        try? await Task.sleep(for: settle)
        while Date() < deadline {
            if session.phase == .live, session.state.isSyncIdle, !session.state.folders.isEmpty { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }
}
