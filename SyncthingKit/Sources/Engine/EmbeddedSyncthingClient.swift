import Foundation
import Stbridge

/// Wraps the gomobile-generated node so it can cross concurrency domains.
/// The Go side guards its own state, so concurrent calls are safe.
final class NodeHandle: @unchecked Sendable {
    let node: StbridgeNode
    init(_ node: StbridgeNode) { self.node = node }
}

/// `SyncthingAPIClient` backed by the in-process Syncthing node.
///
/// Go calls block the calling thread (event long-polls block for up to the
/// timeout), so they run on a dedicated concurrent queue rather than the
/// Swift cooperative pool. Cancelling the awaiting task returns immediately;
/// the Go call finishes in the background and its result is discarded.
public final class EmbeddedSyncthingClient: SyncthingAPIClient {
    let handle: NodeHandle
    private static let queue = DispatchQueue(label: "SuperSynch.stbridge", qos: .userInitiated, attributes: .concurrent)

    init(handle: NodeHandle) { self.handle = handle }

    // MARK: - Plumbing

    private final class OneShot<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        init(_ c: CheckedContinuation<T, Error>) { continuation = c }
        func resume(_ result: Result<T, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
        }
    }

    private func call<T: Sendable>(_ body: @escaping @Sendable (StbridgeNode) throws -> T) async throws -> T {
        let handle = self.handle
        let box = LockedBox<OneShot<T>?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shot = OneShot(continuation)
                box.value = shot
                if Task.isCancelled { shot.resume(.failure(CancellationError())); return }
                Self.queue.async {
                    do { shot.resume(.success(try body(handle.node))) } catch { shot.resume(.failure(Self.map(error))) }
                }
            }
        } onCancel: {
            box.value?.resume(.failure(CancellationError()))
        }
    }

    static func map(_ error: Error) -> SyncthingError {
        let message = (error as NSError).localizedDescription
        if message.contains("is not running") { return .notRunning }
        return .engine(message)
    }

    /// Calls a gomobile method that returns a string with an NSError**
    /// out-parameter (these don't import as `throws`).
    private func string(_ body: @escaping @Sendable (StbridgeNode, NSErrorPointer) -> String) async throws -> String {
        try await call { node in
            var error: NSError?
            let text = body(node, &error)
            if let error { throw error }
            return text
        }
    }

    private func json<T: Decodable>(_ type: T.Type = T.self, _ body: @escaping @Sendable (StbridgeNode, NSErrorPointer) -> String) async throws -> T {
        let text = try await string(body)
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw SyncthingError.decoding(String(describing: error))
        }
    }

    private static func encode(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    // MARK: - Identity

    public func systemStatus() async throws -> SystemStatus { try await json { $0.statusJSON($1) } }
    public func systemVersion() async throws -> SystemVersion { try await json { $0.versionJSON($1) } }

    // MARK: - Connections & stats

    public func connections() async throws -> ConnectionsResponse { try await json { $0.connectionsJSON($1) } }

    public func deviceStats() async throws -> [DeviceID: DeviceStatistics] {
        try await json([DeviceID: DeviceStatistics]?.self) { $0.deviceStatsJSON($1) } ?? [:]
    }

    public func folderStats() async throws -> [FolderID: FolderStatistics] {
        try await json([FolderID: FolderStatistics]?.self) { $0.folderStatsJSON($1) } ?? [:]
    }

    // MARK: - Config

    public func folders() async throws -> [FolderConfig] {
        try await json([FolderConfig]?.self) { $0.foldersJSON($1) } ?? []
    }

    public func devices() async throws -> [DeviceConfig] {
        try await json([DeviceConfig]?.self) { $0.devicesJSON($1) } ?? []
    }

    public func folderDefaults() async throws -> JSONValue { try await json { $0.defaultFolderJSON($1) } }
    public func deviceDefaults() async throws -> JSONValue { try await json { $0.defaultDeviceJSON($1) } }

    public func setFolder(_ folder: JSONValue) async throws {
        let text = try Self.encode(folder)
        try await call { try $0.setFolderJSON(text) }
    }

    public func setDevice(_ device: JSONValue) async throws {
        let text = try Self.encode(device)
        try await call { try $0.setDeviceJSON(text) }
    }

    public func removeFolder(_ folderID: FolderID) async throws { try await call { try $0.removeFolder(folderID) } }
    public func removeDevice(_ deviceID: DeviceID) async throws { try await call { try $0.removeDevice(deviceID) } }

    public func setFolderPaused(_ folderID: FolderID, paused: Bool) async throws {
        try await call { try $0.setFolderPaused(folderID, paused: paused) }
    }

    public func setDevicePaused(_ deviceID: DeviceID?, paused: Bool) async throws {
        try await call { try $0.setDevicePaused(deviceID ?? "", paused: paused) }
    }

    public func setDeviceName(_ name: String) async throws { try await call { try $0.setDeviceName(name) } }

    public func options() async throws -> JSONValue { try await json { $0.optionsJSON($1) } }

    public func setOptions(_ options: JSONValue) async throws {
        let text = try Self.encode(options)
        try await call { try $0.setOptionsJSON(text) }
    }

    // MARK: - Folder state

    public func folderStatus(_ folderID: FolderID) async throws -> FolderStatus {
        try await json { $0.folderStatusJSON(folderID, error: $1) }
    }

    public func completion(folder: FolderID?, device: DeviceID?) async throws -> Completion {
        try await json { $0.completionJSON(folder ?? "", device: device ?? "", error: $1) }
    }

    public func need(folder: FolderID, page: Int, perPage: Int) async throws -> NeedResponse {
        try await json { $0.needJSON(folder, page: page, perPage: perPage, error: $1) }
    }

    public func folderErrors(_ folderID: FolderID) async throws -> [FileError] {
        let r: FolderErrorsResponse = try await json { $0.folderErrorsJSON(folderID, error: $1) }
        return r.errors
    }

    public func scan(folder: FolderID?) async throws { try await call { try $0.scan(folder ?? "") } }

    // MARK: - Pending

    public func pendingDevices() async throws -> [PendingDevice] {
        let text = try await string { $0.pendingDevicesJSON($1) }
        return try PendingDecoding.devices(from: Data(text.utf8))
    }

    public func pendingFolders() async throws -> [PendingFolder] {
        let text = try await string { $0.pendingFoldersJSON($1) }
        return try PendingDecoding.folders(from: Data(text.utf8))
    }

    public func ignorePendingDevice(_ deviceID: DeviceID) async throws { try await call { try $0.ignoreDevice(deviceID) } }

    public func ignorePendingFolder(_ folder: PendingFolder) async throws {
        try await call { try $0.ignoreFolder(folder.folderID, label: folder.label, deviceID: folder.offeredBy) }
    }

    // MARK: - Events

    public func events(since: Int, limit: Int?, timeout: Int) async throws -> [SyncthingEvent] {
        try await json([SyncthingEvent]?.self) { $0.events(since, limit: limit ?? 0, timeoutSeconds: timeout, error: $1) } ?? []
    }
}

/// Minimal lock-protected box for passing state between a task and its
/// cancellation handler.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
