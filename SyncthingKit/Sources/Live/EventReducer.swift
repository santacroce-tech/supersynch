import Foundation

/// Follow-up work an event implies but cannot perform itself (the reducer is
/// pure). `SyncSession` executes these, coalescing duplicates.
public enum EventEffect: Hashable, Sendable {
    case refreshConfig
    case refreshPending
    case refreshFolderStatus(FolderID)
    case refreshDeviceCompletion(DeviceID)
    /// Events were missed (ID gap); reload everything.
    case resync
}

/// Pure reducer from Syncthing events to `NodeState`. Shared by all idioms.
public enum EventReducer {
    public static func apply(_ events: [SyncthingEvent], to state: inout NodeState) -> Set<EventEffect> {
        var effects = Set<EventEffect>()
        for event in events.sorted(by: { $0.id < $1.id }) {
            // Replays of already-applied events are ignored.
            if state.lastEventID > 0, event.id <= state.lastEventID { continue }
            if state.lastEventID > 0, event.id > state.lastEventID + 1 {
                effects.insert(.resync)
            }
            effects.formUnion(apply(event, to: &state))
            state.lastEventID = event.id
        }
        return effects
    }

    public static func apply(_ event: SyncthingEvent, to state: inout NodeState) -> Set<EventEffect> {
        switch event.payload {
        case let .stateChanged(folder, from, to):
            guard !folder.isEmpty else { return [] }
            state.folderStatuses[folder, default: FolderStatus()].state = to
            state.folderStatuses[folder]?.stateChanged = event.time
            if from == "scanning" { state.scanProgress[folder] = nil }
            // Per the docs, the error list is obsolete once syncing restarts.
            if to == "syncing" { state.folderErrors[folder] = nil }
            return []

        case let .folderSummary(folder, summary):
            guard !folder.isEmpty else { return [] }
            state.folderStatuses[folder] = summary
            if summary.state != "scanning" { state.scanProgress[folder] = nil }
            return []

        case let .folderCompletion(folder, device, completion):
            guard !folder.isEmpty, !device.isEmpty else { return [] }
            state.remoteFolderCompletion[device, default: [:]][folder] = completion
            let shared = Set(state.folders(sharedWith: device).map(\.id))
            let known = state.remoteFolderCompletion[device] ?? [:]
            if !shared.isEmpty, shared.isSubset(of: Set(known.keys)) {
                state.deviceCompletion[device] = aggregate(known.filter { shared.contains($0.key) }.map(\.value))
                return []
            }
            return [.refreshDeviceCompletion(device)]

        case let .folderErrors(folder, errors):
            guard !folder.isEmpty else { return [] }
            state.folderErrors[folder] = errors.isEmpty ? nil : errors
            return []

        case let .folderScanProgress(folder, current, total, rate):
            guard !folder.isEmpty else { return [] }
            state.scanProgress[folder] = ScanProgress(current: current, total: total, rate: rate)
            return []

        case let .folderPaused(folder):
            setFolderPaused(folder, true, in: &state)
            return []

        case let .folderResumed(folder):
            setFolderPaused(folder, false, in: &state)
            return [.refreshFolderStatus(folder)]

        case let .deviceConnected(device, address, clientVersion, connectionType):
            guard !device.isEmpty else { return [] }
            var info = state.connections[device] ?? ConnectionInfo()
            info.connected = true
            if !address.isEmpty { info.address = address }
            if !clientVersion.isEmpty { info.clientVersion = clientVersion }
            if !connectionType.isEmpty { info.type = connectionType }
            info.startedAt = event.time
            state.connections[device] = info
            return [.refreshDeviceCompletion(device)]

        case let .deviceDisconnected(device, _):
            guard !device.isEmpty else { return [] }
            state.connections[device]?.connected = false
            state.deviceRates[device] = nil
            if let time = event.time {
                state.deviceStats[device, default: DeviceStatistics()].lastSeen = time
            }
            return []

        case let .devicePaused(device):
            setDevicePaused(device, true, in: &state)
            return []

        case let .deviceResumed(device):
            setDevicePaused(device, false, in: &state)
            return []

        case let .configSaved(folders, devices):
            guard let folders, let devices else { return [.refreshConfig] }
            state.applyDevices(devices)
            let added = state.applyFolders(folders)
            return Set(added.map { EventEffect.refreshFolderStatus($0) })

        case .pendingDevicesChanged, .pendingFoldersChanged:
            return [.refreshPending]

        case .other:
            return []
        }
    }

    /// Byte-weighted completion across folders, as the Syncthing GUI computes it.
    public static func aggregate(_ completions: [Completion]) -> Completion {
        let global = completions.reduce(Int64(0)) { $0 + $1.globalBytes }
        let need = completions.reduce(Int64(0)) { $0 + $1.needBytes }
        let items = completions.reduce(0) { $0 + $1.globalItems }
        let needItems = completions.reduce(0) { $0 + $1.needItems }
        let deletes = completions.reduce(0) { $0 + $1.needDeletes }
        let pct: Double
        if global > 0 {
            pct = max(0, min(100, 100 * (1 - Double(need) / Double(global))))
        } else {
            pct = (needItems + deletes) > 0 ? 95 : 100
        }
        return Completion(completion: pct, globalBytes: global, needBytes: need, globalItems: items,
                          needItems: needItems, needDeletes: deletes, remoteState: "valid")
    }

    private static func setFolderPaused(_ id: FolderID, _ paused: Bool, in state: inout NodeState) {
        guard let index = state.folders.firstIndex(where: { $0.id == id }) else { return }
        state.folders[index].paused = paused
        if paused { state.scanProgress[id] = nil }
    }

    private static func setDevicePaused(_ id: DeviceID, _ paused: Bool, in state: inout NodeState) {
        if let index = state.devices.firstIndex(where: { $0.deviceID == id }) {
            state.devices[index].paused = paused
        }
        state.connections[id]?.paused = paused
        if paused {
            state.connections[id]?.connected = false
            state.deviceRates[id] = nil
        }
    }
}
