import Foundation
import Observation

/// How the UI is currently receiving data from the embedded node.
public enum ConnectionPhase: Equatable, Sendable {
    case idle
    case connecting
    /// Event stream is healthy.
    case live
    /// Event stream dropped; data is refreshed by timed polling while retrying.
    case polling(SyncthingError)
    /// The node can't be reached (e.g. not running).
    case failed(SyncthingError)

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

/// Live model of the local Syncthing node: follows its event stream (with a
/// polling fallback) into `NodeState`, and exposes every user action.
/// Identical on all idioms.
@MainActor
@Observable
public final class SyncSession {
    public internal(set) var state = NodeState()
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
        /// Long-poll timeout. Kept short so a stopped node releases its
        /// blocked thread quickly.
        public var eventTimeout = 20
        public var maxBackoff: Double = 10
        public var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

        public init() {}
    }

    public init(client: SyncthingAPIClient, configuration: Configuration = .init(), initialState: NodeState = .init()) {
        self.client = client
        self.configuration = configuration
        self.state = initialState
    }

    // MARK: - Lifecycle

    public var isRunning: Bool { eventTask != nil }

    /// Starts following the node. Safe to call repeatedly.
    public func start() {
        guard eventTask == nil else { return }
        if phase == .idle || phase.error != nil { phase = .connecting }
        needsResync = true
        eventTask = Task { [weak self] in await self?.runEventLoop() }
        pollTask = Task { [weak self] in await self?.runPollLoop() }
    }

    /// Stops following the node (keeps the last known state for display).
    public func stop() {
        eventTask?.cancel(); eventTask = nil
        pollTask?.cancel(); pollTask = nil
        phase = .idle
    }

    /// User-initiated full reload (pull to refresh).
    public func refresh() async {
        do {
            try await fullRefresh()
        } catch {
            let e = SyncthingError(error)
            if e != .cancelled { actionError = e }
        }
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
        if let stats = try? await client.folderStats() {
            state.folderStats.merge(stats) { _, new in new }
        }
    }

    private func refreshPending() async {
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
        var backoff: Double = 0.5
        while !Task.isCancelled {
            do {
                if needsResync {
                    // Take the current event ID first so nothing that happens
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
                backoff = 0.5
            } catch {
                if Task.isCancelled { return }
                let e = SyncthingError(error)
                if e == .cancelled { return }
                needsResync = true
                phase = (state.status == nil || e == .notRunning) ? .failed(e) : .polling(e)
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
            state.status = try await client.systemStatus()
            lastUpdated = .now

            let streamDown = phase != .live
            if slow || streamDown {
                await refreshSlowData()
            }
            if streamDown && slow {
                await refreshConfig()
                await refreshFolderStatuses(state.folders.filter { !$0.paused }.map(\.id))
                await refreshPending()
            }
        } catch {
            // The event loop owns connection-state reporting.
        }
    }

    // MARK: - Detail data

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
        await run { try await client.scan(folder: nil) }
    }

    public func setFolderPaused(_ folderID: FolderID, paused: Bool) async {
        let ok = await run { try await client.setFolderPaused(folderID, paused: paused) }
        if ok, let i = state.folders.firstIndex(where: { $0.id == folderID }) {
            state.folders[i].paused = paused
        }
    }

    public func setDevicePaused(_ deviceID: DeviceID, paused: Bool) async {
        let ok = await run { try await client.setDevicePaused(deviceID, paused: paused) }
        if ok { setLocalDevicePaused(deviceID, paused) }
    }

    public func pauseAll() async {
        let ok = await run { try await client.setDevicePaused(nil, paused: true) }
        if ok { for d in state.remoteDevices { setLocalDevicePaused(d.deviceID, true) } }
    }

    public func resumeAll() async {
        let ok = await run { try await client.setDevicePaused(nil, paused: false) }
        if ok { for d in state.remoteDevices { setLocalDevicePaused(d.deviceID, false) } }
    }

    private func setLocalDevicePaused(_ id: DeviceID, _ paused: Bool) {
        _ = EventReducer.apply(SyncthingEvent(id: 0, type: paused ? "DevicePaused" : "DeviceResumed",
                                              data: .object(["device": .string(id)])), to: &state)
    }

    // MARK: - Folder & device management

    /// Adds or updates a folder and refreshes config.
    @discardableResult
    public func saveFolder(_ draft: FolderDraft) async -> Bool {
        let ok = await run { try await client.setFolder(draft.json) }
        if ok { await refreshConfig() }
        return ok
    }

    @discardableResult
    public func removeFolder(_ folderID: FolderID) async -> Bool {
        let ok = await run { try await client.removeFolder(folderID) }
        if ok { await refreshConfig() }
        return ok
    }

    /// Adds or updates a remote device, optionally sharing folders with it.
    @discardableResult
    public func saveDevice(_ draft: DeviceDraft, sharing folderIDs: Set<FolderID> = []) async -> Bool {
        let ok = await run {
            try await client.setDevice(draft.json)
            for folder in state.folders {
                let shared = folder.deviceIDs.contains(draft.deviceID)
                let wanted = folderIDs.contains(folder.id)
                guard shared != wanted else { continue }
                let devices = wanted ? folder.deviceIDs + [draft.deviceID] : folder.deviceIDs.filter { $0 != draft.deviceID }
                try await client.setFolder(FolderDraft.sharing(folder, with: devices))
            }
        }
        if ok {
            state.pendingDevices.removeAll { $0.deviceID == draft.deviceID }
            await refreshConfig()
        }
        return ok
    }

    @discardableResult
    public func removeDevice(_ deviceID: DeviceID) async -> Bool {
        let ok = await run { try await client.removeDevice(deviceID) }
        if ok { await refreshConfig() }
        return ok
    }

    /// Sets the devices a folder is shared with.
    @discardableResult
    public func setSharing(folder folderID: FolderID, devices: Set<DeviceID>) async -> Bool {
        guard let folder = state.folder(folderID) else { return false }
        let ok = await run { try await client.setFolder(FolderDraft.sharing(folder, with: Array(devices))) }
        if ok { await refreshConfig() }
        return ok
    }

    @discardableResult
    public func renameThisDevice(_ name: String) async -> Bool {
        let ok = await run { try await client.setDeviceName(name) }
        if ok { await refreshConfig() }
        return ok
    }

    // MARK: - Pending requests

    public func dismiss(_ device: PendingDevice) async {
        let ok = await run { try await client.dismissPendingDevice(device.deviceID) }
        if ok { state.pendingDevices.removeAll { $0.id == device.id } }
    }

    public func dismiss(_ folder: PendingFolder) async {
        let ok = await run { try await client.dismissPendingFolder(folder) }
        if ok { state.pendingFolders.removeAll { $0.id == folder.id } }
    }

    // MARK: - Maintenance

    public func clearSystemErrors() async {
        let ok = await run { try await client.clearSystemErrors() }
        if ok { state.systemErrors = [] }
    }

    public func loadVersions(_ folderID: FolderID) async throws -> [String: [FileVersion]] {
        try await client.folderVersions(folderID)
    }

    /// Restores one file version; returns false (and sets `actionError`) on failure.
    @discardableResult
    public func restore(_ path: String, version: FileVersion, in folderID: FolderID) async -> Bool {
        var failure: String?
        let ok = await run { failure = try await client.restoreVersions(folderID, [path: version])[path] }
        if let failure { actionError = .engine(failure); return false }
        return ok
    }

    public func loadIgnores(_ folderID: FolderID) async throws -> IgnorePatterns {
        try await client.ignores(folderID)
    }

    @discardableResult
    public func saveIgnores(_ folderID: FolderID, lines: [String]) async -> Bool {
        let ok = await run { try await client.setIgnores(folderID, lines: lines) }
        if ok { await rescan(folder: folderID) }
        return ok
    }

    public func overrideRemoteChanges(_ folderID: FolderID) async {
        await run { try await client.override(folderID) }
    }

    public func revertLocalChanges(_ folderID: FolderID) async {
        await run { try await client.revert(folderID) }
    }

    public func ignore(_ device: PendingDevice) async {
        let ok = await run { try await client.ignorePendingDevice(device.deviceID) }
        if ok { state.pendingDevices.removeAll { $0.id == device.id } }
    }

    public func ignore(_ folder: PendingFolder) async {
        let ok = await run { try await client.ignorePendingFolder(folder) }
        if ok { state.pendingFolders.removeAll { $0.id == folder.id } }
    }

    /// Default location for a newly accepted or created folder.
    public func suggestedPath(forLabel label: String, id: FolderID) async -> String {
        let defaults = try? await client.folderDefaults()
        let name = label.isEmpty ? id : label
        return PathSuggestion.make(defaultPath: defaults?["path"]?.stringValue, name: name,
                                   separator: state.status?.pathSeparator ?? "/")
    }
}

public enum PathSuggestion {
    public static func make(defaultPath: String?, name: String, separator: String) -> String {
        let base = (defaultPath?.isEmpty == false ? defaultPath! : "~")
        let safe = name.replacingOccurrences(of: separator, with: "-")
        return base.hasSuffix(separator) ? base + safe : base + separator + safe
    }
}
