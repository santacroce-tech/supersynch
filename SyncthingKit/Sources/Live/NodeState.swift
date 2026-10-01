import Foundation

public struct TransferRates: Sendable, Equatable {
    /// Bytes per second received.
    public var inBps: Double
    /// Bytes per second sent.
    public var outBps: Double

    public init(inBps: Double, outBps: Double) { self.inBps = inBps; self.outBps = outBps }
    public static let zero = TransferRates(inBps: 0, outBps: 0)
}

/// A value snapshot of everything known about one Syncthing instance. It is
/// mutated only by `EventReducer` and the `apply…` functions below, which
/// keeps live-update logic pure and unit-testable.
public struct ServerState: Sendable, Equatable {
    public var status: SystemStatus?
    public var version: SystemVersion?

    public var folders: [FolderConfig] = []
    public var devices: [DeviceConfig] = []

    public var folderStatuses: [FolderID: FolderStatus] = [:]
    public var folderStats: [FolderID: FolderStatistics] = [:]
    public var folderErrors: [FolderID: [FileError]] = [:]
    public var scanProgress: [FolderID: ScanProgress] = [:]

    public var connections: [DeviceID: ConnectionInfo] = [:]
    public var totals: TransferTotals?
    public var totalRates: TransferRates = .zero
    public var deviceRates: [DeviceID: TransferRates] = [:]
    public var deviceStats: [DeviceID: DeviceStatistics] = [:]
    /// Aggregate completion of each remote device across shared folders.
    public var deviceCompletion: [DeviceID: Completion] = [:]
    /// Completion of each folder on each remote device, from `FolderCompletion` events.
    public var remoteFolderCompletion: [DeviceID: [FolderID: Completion]] = [:]

    public var systemErrors: [SystemError] = []
    public var pendingDevices: [PendingDevice] = []
    public var pendingFolders: [PendingFolder] = []

    /// ID of the last event applied; the next long-poll uses `since=lastEventID`.
    public var lastEventID: Int = 0

    public init() {}

    // MARK: - Derived

    public var myID: DeviceID? { status?.myID }

    /// Configured devices excluding this instance itself.
    public var remoteDevices: [DeviceConfig] {
        devices.filter { $0.deviceID != myID }
    }

    public var connectedDeviceCount: Int {
        remoteDevices.filter { connections[$0.deviceID]?.connected == true }.count
    }

    public var pendingCount: Int { pendingDevices.count + pendingFolders.count }

    public func folder(_ id: FolderID) -> FolderConfig? { folders.first { $0.id == id } }
    public func device(_ id: DeviceID) -> DeviceConfig? { devices.first { $0.deviceID == id } }

    public func folders(sharedWith device: DeviceID) -> [FolderConfig] {
        folders.filter { $0.deviceIDs.contains(device) }
    }

    public func folderState(_ id: FolderID) -> FolderSyncState {
        guard let folder = folder(id) else { return .unknown }
        return FolderSyncState.derive(paused: folder.paused, status: folderStatuses[id], scanProgress: scanProgress[id])
    }

    public func deviceState(_ id: DeviceID) -> DeviceSyncState {
        let config = device(id)
        let connection = connections[id]
        return DeviceSyncState.derive(
            paused: config?.paused ?? connection?.paused ?? false,
            connected: connection?.connected ?? false,
            completion: deviceCompletion[id],
            sharedFolderCount: folders(sharedWith: id).count
        )
    }

    public func deviceName(_ id: DeviceID) -> String {
        device(id)?.displayName ?? DeviceIDFormat.short(id)
    }

    // MARK: - Mutations from polled endpoints

    /// Applies a `/rest/system/connections` snapshot and derives transfer
    /// rates from the byte-counter deltas since the previous snapshot.
    public mutating func applyConnections(_ response: ConnectionsResponse) {
        let previousTotals = totals
        let previousConnections = connections

        totalRates = RateCalculator.rates(
            previous: previousTotals.map { ($0.inBytesTotal, $0.outBytesTotal, $0.at) },
            current: (response.total.inBytesTotal, response.total.outBytesTotal, response.total.at)
        )
        var rates: [DeviceID: TransferRates] = [:]
        for (id, current) in response.connections where current.connected {
            guard let previous = previousConnections[id], previous.connected else { continue }
            rates[id] = RateCalculator.rates(
                previous: (previous.inBytesTotal, previous.outBytesTotal, previous.at),
                current: (current.inBytesTotal, current.outBytesTotal, current.at)
            )
        }
        deviceRates = rates
        connections = response.connections
        totals = response.total
    }

    /// Replaces folder config, pruning per-folder state for removed folders.
    /// Returns the IDs of folders that are new.
    @discardableResult
    public mutating func applyFolders(_ newFolders: [FolderConfig]) -> [FolderID] {
        let oldIDs = Set(folders.map(\.id))
        let newIDs = Set(newFolders.map(\.id))
        folders = newFolders.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        for removed in oldIDs.subtracting(newIDs) {
            folderStatuses[removed] = nil
            folderStats[removed] = nil
            folderErrors[removed] = nil
            scanProgress[removed] = nil
        }
        return newFolders.map(\.id).filter { !oldIDs.contains($0) }
    }

    public mutating func applyDevices(_ newDevices: [DeviceConfig]) {
        devices = newDevices.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let ids = Set(newDevices.map(\.deviceID))
        deviceCompletion = deviceCompletion.filter { ids.contains($0.key) }
        remoteFolderCompletion = remoteFolderCompletion.filter { ids.contains($0.key) }
    }
}

public enum RateCalculator {
    public typealias Sample = (inBytes: Int64, outBytes: Int64, at: Date?)

    /// Bytes/second between two counter samples. Counter resets (restart) and
    /// missing or non-increasing timestamps yield zero rather than garbage.
    public static func rates(previous: Sample?, current: Sample) -> TransferRates {
        guard let previous, let t0 = previous.at, let t1 = current.at else { return .zero }
        let dt = t1.timeIntervalSince(t0)
        guard dt > 0 else { return .zero }
        let dIn = current.inBytes - previous.inBytes
        let dOut = current.outBytes - previous.outBytes
        return TransferRates(inBps: dIn > 0 ? Double(dIn) / dt : 0, outBps: dOut > 0 ? Double(dOut) / dt : 0)
    }
}
