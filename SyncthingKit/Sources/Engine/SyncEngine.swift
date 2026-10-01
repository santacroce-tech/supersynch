import Foundation
import Observation
import Stbridge

/// Where the embedded node keeps its state.
public struct EnginePaths: Sendable {
    /// config.xml, device certificate and key (backed up, so a restored
    /// phone keeps its device ID).
    public var configDir: URL
    /// Index database (rebuildable; excluded from backup).
    public var dataDir: URL
    /// Default parent for new folders. `Documents` makes them visible in the
    /// Files app under "On My iPhone › SuperSynch".
    public var folderRoot: URL

    public init(configDir: URL, dataDir: URL, folderRoot: URL) {
        self.configDir = configDir; self.dataDir = dataDir; self.folderRoot = folderRoot
    }

    public static var appDefault: EnginePaths {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Syncthing")
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return EnginePaths(configDir: support.appending(path: "config"),
                           dataDir: support.appending(path: "data"),
                           folderRoot: documents)
    }
}

/// Owns the embedded Syncthing node's lifecycle. Starting/stopping blocks
/// (database open, graceful shutdown), so it runs off the main actor.
@MainActor
@Observable
public final class SyncEngine {
    public enum Status: Equatable, Sendable {
        case stopped
        case starting
        case running
        case stopping
        case failed(String)
    }

    public private(set) var status: Status = .stopped
    public let deviceID: DeviceID
    public let paths: EnginePaths
    public let client: SyncthingAPIClient
    public let externalFolders: ExternalFolderAccess

    private let handle: NodeHandle
    private let deviceName: String
    private static let queue = DispatchQueue(label: "SuperSynch.engine")

    /// - Parameter startupOptions: options applied before each start, before
    ///   Syncthing opens any listener (tests use it to avoid default ports).
    public init(paths: EnginePaths = .appDefault, deviceName: String,
                externalFolders: ExternalFolderAccess = ExternalFolderAccess(),
                startupOptions: JSONValue? = nil) throws {
        var error: NSError?
        guard let node = StbridgeNewNode(paths.configDir.path, paths.dataDir.path, paths.folderRoot.path, &error) else {
            throw SyncthingError.engine(error?.localizedDescription ?? "Couldn't create the Syncthing node.")
        }
        if let startupOptions, let data = try? JSONEncoder().encode(startupOptions) {
            node.setStartupOptionsJSON(String(decoding: data, as: UTF8.self))
        }
        var dataDir = paths.dataDir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dataDir.setResourceValues(values)

        self.paths = paths
        self.deviceName = deviceName
        self.externalFolders = externalFolders
        handle = NodeHandle(node)
        deviceID = node.deviceID()
        client = EmbeddedSyncthingClient(handle: handle)
    }

    public var isRunning: Bool { status == .running }

    /// Starts syncing. External (security-scoped) folders are opened first so
    /// Syncthing can reach them.
    public func start() async {
        guard status == .stopped || status.isFailure else { return }
        status = .starting
        externalFolders.beginAccess()
        let handle = self.handle
        let name = deviceName
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            Self.queue.async {
                do {
                    try handle.node.start(name)
                    continuation.resume(returning: .success(()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        switch result {
        case .success:
            status = .running
        case .failure(let error):
            externalFolders.endAccess()
            status = .failed((error as NSError).localizedDescription)
        }
    }

    /// Stops syncing and closes the database. Safe to call when stopped.
    public func stop() async {
        guard status == .running || status == .starting else { return }
        status = .stopping
        let handle = self.handle
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Self.queue.async {
                handle.node.stop()
                continuation.resume()
            }
        }
        externalFolders.endAccess()
        status = .stopped
    }
}

extension SyncEngine.Status {
    public var isFailure: Bool { if case .failed = self { true } else { false } }
}
