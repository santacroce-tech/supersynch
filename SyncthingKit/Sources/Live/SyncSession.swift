import Foundation
import Observation

/// How the app is currently receiving data from a server.
public enum ConnectionPhase: Equatable, Sendable {
    case idle
    case connecting
    /// Event long-poll is healthy.
    case live
    /// Event stream dropped; data is refreshed by timed polling while retrying.
    case polling(SyncthingError)
    /// Can't talk to the server at all (or not without user action).
    case failed(SyncthingError)
    /// The user shut the Syncthing instance down.
    case shutDown

    public var error: SyncthingError? {
        switch self {
        case .polling(let e), .failed(let e): e
        default: nil
        }
    }
}

extension SyncthingError {
    public init(_ error: Error) {
        if let e = error as? SyncthingError { self = e }
        else if error is CancellationError { self = .cancelled }
        else { self = .other(error.localizedDescription) }
    }
}

/// Live model of one Syncthing instance: owns the event long-poll and the
/// polling fallback, and exposes every user action. Identical on all idioms.
@MainActor
@Observable
public final class ServerSession: Identifiable {
    public let id: UUID
    public private(set) var server: ServerConfig
    public internal(set) var state = ServerState()
    public private(set) var phase: ConnectionPhase = .idle
    public private(set) var isRefreshing = false
    /// The most recent failed user action, for presentation as an alert.
    public var actionError: SyncthingError?
    public private(set) var lastUpdated: Date?

    public let client: SyncthingAPIClient
    private let configuration: Configuration

    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var needsResync = true

    public struct Configuration: Sendable {
        public var pollInterval: Duration = .seconds(10)
        /// Every n-th poll also refreshes slower-changing data.
        public var slowPollEvery = 3
        public var eventTimeout = 60
        public var maxBackoff: Double = 30
        public var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

        public init() {}
    }

    public init(server: ServerConfig, client: SyncthingAPIClient, configuration: Configuration = .init(),
                initialState: ServerState = .init()) {
        self.id = server.id
        self.state = initialState
        self.server = server
        self.client = client
        self.configuration = configuration
    }

    // MARK: - Lifecycle

    public var isRunning: Bool { eventTask != nil }

    /// Starts (or resumes) live updates. Safe to call repeatedly.
    public func start() {
        guard eventTask == nil else { return }
        if phase == .idle || phase == .shutDown || phase.error != nil { phase = .connecting }
        needsResync = true
        eventTask = Task { [weak self] in await self?.runEventLoop() }
        pollTask = Task { [weak self] in await self?.runPollLoop() }
    }

    /// Suspends live updates (e.g. when the app is backgrounded).
    public func stop() {
        eventTask?.cancel(); eventTask = nil
        pollTask?.cancel(); pollTask = nil
        if phase != .shutDown { phase = .idle }
    }

    public func updateServer(_ server: ServerConfig) {
        self.server = server
    }

    /// User-initiated full reload (pull to refresh).
    public func refresh() async {
        do {
            try await fullRefresh()
            if case .failed = phase { restartLoops() }
        } catch {
            let e = SyncthingError(error)
            if e != .cancelled { phase = .failed(e) }
        }
    }

    private func restartLoops() {
        stop()
        start()
    }

    // MARK: - Loading

    func fullRefresh() async throws {
        isRefreshing = true
        defer { isRefreshing = false }

        async let statusReq = client.systemStatus()
        async let versionReq = client.systemVersion()
        async let foldersReq = client.folders()
        async let devicesReq = client.devices()
        async let connectionsReq = client.connections()

        let (status, version, folders, devices, connections) =
            try await (statusReq, versionReq, foldersReq, devicesReq, connectionsReq)

        state.status = status
        state.version = version
        state.applyDevices(devices)
        state.applyFolders(folders)
        state.applyConnections(connections)
        lastUpdated = .now

        await refreshFolderStatuses(folders.filter { !$0.paused }.map(\.id))
        await refreshSlowData()
        await refreshPending()
        await refreshDeviceCompletions(state.remoteDevices.filter { connections.connections[$0.deviceID]?.connected == true }.map(\.deviceID))
    }

    private func refreshFolderStatuses(_ ids: [FolderID]) async {
        let client = self.client
        let results = await withTaskGroup(of: (FolderID, FolderStatus?).self) { group in
            for id in ids {
                group.addTask { (id, try? await client.folderStatus(id)) }
            }
            var out: [(FolderID, FolderStatus?)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (id, status) in results {
            if let status { state.folderStatuses[id] = status }
        }
    }

    private func refreshDeviceCompletions(_ ids: [DeviceID]) async {
        let client = self.client
        let results = await withTaskGroup(of: (DeviceID, Completion?).self) { group in
            for id in ids {
                group.addTask { (id, try? await client.completion(folder: nil, device: id)) }
            }
            var out: [(DeviceID, Completion?)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (id, completion) in results {
            if let completion { state.deviceCompletion[id] = completion }
        }
    }

    private func refreshSlowData() async {
        if let errors = try? await client.systemErrors() { state.systemErrors = errors }
        if let stats = try? await client.deviceStats() { state.deviceStats = stats }
        if let stats = try? await client.folderStats() { state.folderStats = stats }
    }

    private func refreshPending() async {
        // Pending endpoints need Syncthing ≥ 1.13; failures are non-fatal.
        if let devices = try? await client.pendingDevices() { state.pendingDevices = devices }
        if let folders = try? await client.pendingFolders() { state.pendingFolders = folders }
    }

    private func refreshConfig() async {
        if let devices = try? await client.devices() { state.applyDevices(devices) }
        if let folders = try? await client.folders() {
            let added = state.applyFolders(folders)
            await refreshFolderStatuses(added)
        }
    }

    func perform(_ effects: Set<EventEffect>) async {
        var folderIDs: [FolderID] = []
        var deviceIDs: [DeviceID] = []
        for effect in effects {
            switch effect {
            case .refreshConfig: await refreshConfig()
            case .refreshPending: await refreshPending()
            case .refreshFolderStatus(let id): folderIDs.append(id)
            case .refreshDeviceCompletion(let id): deviceIDs.append(id)
            case .resync: needsResync = true
            }
        }
        if !folderIDs.isEmpty { await refreshFolderStatuses(folderIDs) }
        if !deviceIDs.isEmpty { await refreshDeviceCompletions(deviceIDs) }
    }

    // MARK: - Event loop

    private func runEventLoop() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            do {
                if needsResync {
                    // Find the current event ID first so nothing that happens
                    // during the reload is missed, then reload everything.
                    let latest = try await client.events(since: 0, limit: 1, timeout: 1)
                    let cursor = latest.last?.id ?? 0
                    try await fullRefresh()
                    state.lastEventID = cursor
                    needsResync = false
                }
                phase = .live
                let events = try await client.events(since: state.lastEventID, limit: nil,
                                                     timeout: configuration.eventTimeout)
                try Task.checkCancellation()
                let effects = EventReducer.apply(events, to: &state)
                if !events.isEmpty { lastUpdated = .now }
                await perform(effects)
                backoff = 1
            } catch {
                if Task.isCancelled { return }
                let e = SyncthingError(error)
                if e == .cancelled { return }
                needsResync = true
                guard e.isTransient else {
                    // Needs user action (bad API key, untrusted certificate…).
                    phase = .failed(e)
                    pollTask?.cancel(); pollTask = nil
                    eventTask = nil
                    return
                }
                phase = (state.status == nil || e == .offline) ? .failed(e) : .polling(e)
                try? await configuration.sleep(.seconds(backoff))
                backoff = min(configuration.maxBackoff, backoff * 2)
            }
        }
    }

    // MARK: - Poll loop (rates + fallback)

    private func runPollLoop() async {
        var tick = 0
        while !Task.isCancelled {
            do { try await configuration.sleep(configuration.pollInterval) } catch { return }
            tick += 1
            await pollOnce(slow: tick % configuration.slowPollEvery == 0)
        }
    }

    func pollOnce(slow: Bool) async {
        do {
            let connections = try await client.connections()
            state.applyConnections(connections)
            let status = try await client.systemStatus()
            if let previous = state.status?.startTime, let current = status.startTime, previous != current {
                // The daemon restarted: event IDs were reset.
                needsResync = true
            }
            state.status = status
            lastUpdated = .now

            let streamDown = phase != .live
            if slow || streamDown {
                await refreshSlowData()
            }
            if streamDown && slow {
                // Fallback: without events, poll what they would have told us.
                await refreshConfig()
                await refreshFolderStatuses(state.folders.filter { !$0.paused }.map(\.id))
                await refreshPending()
            }
        } catch {
            // The event loop owns connection-state reporting.
        }
    }

    // MARK: - Folder-detail data

    public func loadFolderErrors(_ folderID: FolderID) async {
        if let errors = try? await client.folderErrors(folderID) {
            state.folderErrors[folderID] = errors.isEmpty ? nil : errors
        }
    }

    public func loadRemoteCompletion(folder folderID: FolderID) async {
        guard let folder = state.folder(folderID) else { return }
        for device in folder.deviceIDs where device != state.myID {
            if let completion = try? await client.completion(folder: folderID, device: device) {
                state.remoteFolderCompletion[device, default: [:]][folderID] = completion
            }
        }
    }

    public func loadNeed(_ folderID: FolderID, page: Int = 1, perPage: Int = 100) async throws -> NeedResponse {
        try await client.need(folder: folderID, page: page, perPage: perPage)
    }

    // MARK: - Actions

    @discardableResult
    private func run(_ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            return true
        } catch {
            actionError = SyncthingError(error)
            return false
        }
    }

    public func rescan(folder: FolderID) async {
        await run { try await client.scan(folder: folder) }
    }

    public func rescanAll() async {
        await run {
            for folder in state.folders where !folder.paused { try await client.scan(folder: folder.id) }
        }
    }

    public func setFolderPaused(_ folderID: FolderID, paused: Bool) async {
        let ok = await run { try await client.setFolderPaused(folderID, paused: paused) }
        if ok, let i = state.folders.firstIndex(where: { $0.id == folderID }) {
            state.folders[i].paused = paused
        }
    }

    public func setDevicePaused(_ deviceID: DeviceID, paused: Bool) async {
        let ok = await run {
            if paused { try await client.pause(device: deviceID) } else { try await client.resume(device: deviceID) }
        }
        if ok { setLocalDevicePaused(deviceID, paused) }
    }

    public func pauseAll() async {
        let ok = await run { try await client.pause(device: nil) }
        if ok { for d in state.remoteDevices { setLocalDevicePaused(d.deviceID, true) } }
    }

    public func resumeAll() async {
        let ok = await run { try await client.resume(device: nil) }
        if ok { for d in state.remoteDevices { setLocalDevicePaused(d.deviceID, false) } }
    }

    private func setLocalDevicePaused(_ id: DeviceID, _ paused: Bool) {
        _ = EventReducer.apply(SyncthingEvent(id: 0, type: paused ? "DevicePaused" : "DeviceResumed",
                                              data: .object(["device": .string(id)])), to: &state)
    }

    public func restart() async {
        let ok = await run { try await client.restart() }
        if ok {
            phase = .connecting
            restartLoops()
        }
    }

    public func shutdown() async {
        let ok = await run { try await client.shutdown() }
        if ok {
            stop()
            phase = .shutDown
        }
    }

    public func clearSystemErrors() async {
        let ok = await run { try await client.clearSystemErrors() }
        if ok { state.systemErrors = [] }
    }

    // MARK: - Pending requests

    public func dismiss(_ device: PendingDevice) async {
        let ok = await run { try await client.dismissPendingDevice(device.deviceID) }
        if ok { state.pendingDevices.removeAll { $0.id == device.id } }
    }

    public func dismiss(_ folder: PendingFolder) async {
        let ok = await run { try await client.dismissPendingFolder(folder.folderID, device: folder.offeredBy) }
        if ok { state.pendingFolders.removeAll { $0.id == folder.id } }
    }

    public func accept(_ device: PendingDevice, name: String) async -> Bool {
        let ok = await run {
            let config = PendingActions.deviceConfig(from: try await client.deviceDefaults(), for: device, name: name)
            try await client.addDevice(config)
        }
        if ok {
            state.pendingDevices.removeAll { $0.id == device.id }
            await refreshConfig()
        }
        return ok
    }

    /// Suggested local path for accepting a pending folder, based on the
    /// server's default folder path.
    public func suggestedPath(for folder: PendingFolder) async -> String {
        let defaults = try? await client.folderDefaults()
        return PendingActions.suggestedPath(defaultPath: defaults?["path"]?.stringValue, folder: folder,
                                            separator: state.status?.pathSeparator ?? "/")
    }

    public func accept(_ folder: PendingFolder, path: String) async -> Bool {
        let ok = await run {
            let config = PendingActions.folderConfig(from: try await client.folderDefaults(), for: folder, path: path)
            try await client.addFolder(config)
        }
        if ok {
            state.pendingFolders.removeAll { $0.folderID == folder.folderID }
            await refreshConfig()
        }
        return ok
    }
}

/// Builds config objects for accepting pending requests on top of the
/// server's own defaults, preserving fields this app doesn't model.
public enum PendingActions {
    public static func deviceConfig(from defaults: JSONValue, for device: PendingDevice, name: String) -> JSONValue {
        var config = defaults
        if case .object = config {} else { config = .object([:]) }
        config["deviceID"] = .string(device.deviceID)
        config["name"] = .string(name.isEmpty ? device.name : name)
        if config["addresses"]?.arrayValue?.isEmpty ?? true {
            config["addresses"] = .array([.string("dynamic")])
        }
        return config
    }

    public static func folderConfig(from defaults: JSONValue, for folder: PendingFolder, path: String) -> JSONValue {
        var config = defaults
        if case .object = config {} else { config = .object([:]) }
        config["id"] = .string(folder.folderID)
        config["label"] = .string(folder.label)
        config["path"] = .string(path)
        if folder.receiveEncrypted { config["type"] = .string("receiveencrypted") }
        var devices = config["devices"]?.arrayValue ?? []
        if !devices.contains(where: { $0["deviceID"]?.stringValue == folder.offeredBy }) {
            devices.append(.object(["deviceID": .string(folder.offeredBy)]))
        }
        config["devices"] = .array(devices)
        return config
    }

    public static func suggestedPath(defaultPath: String?, folder: PendingFolder, separator: String) -> String {
        let base = (defaultPath?.isEmpty == false ? defaultPath! : "~")
        let name = folder.label.isEmpty ? folder.folderID : folder.label
        return base.hasSuffix(separator) ? base + name : base + separator + name
    }
}
