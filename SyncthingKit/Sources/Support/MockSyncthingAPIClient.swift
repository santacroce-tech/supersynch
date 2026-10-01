import Foundation

/// In-memory `SyncthingAPIClient` for unit tests, previews and demo mode.
/// Records every call; responses are configurable.
public actor MockSyncthingAPIClient: SyncthingAPIClient {
    public var statusResponse: Result<SystemStatus, SyncthingError> = .success(SystemStatus(myID: MockData.myID, uptime: 93_784))
    public var versionResponse: Result<SystemVersion, SyncthingError> = .success(SystemVersion(version: "v2.1.5", os: "ios", arch: "arm64"))
    public var connectionsResponse = ConnectionsResponse()
    public var folderList: [FolderConfig] = []
    public var deviceList: [DeviceConfig] = []
    public var folderStatuses: [FolderID: FolderStatus] = [:]
    public var deviceCompletions: [DeviceID: Completion] = [:]
    public var needResponse = NeedResponse()
    public var fileErrors: [FolderID: [FileError]] = [:]
    public var devStats: [DeviceID: DeviceStatistics] = [:]
    public var fldStats: [FolderID: FolderStatistics] = [:]
    public var pendingDeviceList: [PendingDevice] = []
    public var pendingFolderList: [PendingFolder] = []
    public var defaultsFolder: JSONValue = ["path": "/tmp/folders", "devices": []]
    public var defaultsDevice: JSONValue = ["addresses": ["dynamic"]]
    public var optionsValue: JSONValue = ["globalAnnounceEnabled": true, "localAnnounceEnabled": true, "relaysEnabled": true]
    /// Queue of long-poll results; when empty, `events` suspends until cancelled.
    public var eventBatches: [Result<[SyncthingEvent], SyncthingError>] = []
    public var actionError: SyncthingError?

    public private(set) var calls: [String] = []
    public private(set) var savedFolders: [JSONValue] = []
    public private(set) var savedDevices: [JSONValue] = []

    public init() {}

    /// A mock that serves `state` (for demo mode and previews).
    public init(preloaded state: NodeState) {
        if let status = state.status { statusResponse = .success(status) }
        if let version = state.version { versionResponse = .success(version) }
        folderList = state.folders
        deviceList = state.devices
        folderStatuses = state.folderStatuses
        connectionsResponse = ConnectionsResponse(connections: state.connections, total: state.totals ?? TransferTotals())
        deviceCompletions = state.deviceCompletion
        devStats = state.deviceStats
        fldStats = state.folderStats
        pendingDeviceList = state.pendingDevices
        pendingFolderList = state.pendingFolders
    }

    public func configure(_ body: @Sendable (isolated MockSyncthingAPIClient) -> Void) {
        body(self)
    }

    private func record(_ call: String) { calls.append(call) }

    private func action(_ call: String) throws {
        record(call)
        if let actionError { throw actionError }
    }

    public func systemStatus() async throws -> SystemStatus { record("status"); return try statusResponse.get() }
    public func systemVersion() async throws -> SystemVersion { record("version"); return try versionResponse.get() }
    public func connections() async throws -> ConnectionsResponse { record("connections"); return connectionsResponse }
    public func deviceStats() async throws -> [DeviceID: DeviceStatistics] { record("deviceStats"); return devStats }
    public func folderStats() async throws -> [FolderID: FolderStatistics] { record("folderStats"); return fldStats }
    public func folders() async throws -> [FolderConfig] { record("folders"); return folderList }
    public func devices() async throws -> [DeviceConfig] { record("devices"); return deviceList }
    public func folderDefaults() async throws -> JSONValue { record("folderDefaults"); return defaultsFolder }
    public func deviceDefaults() async throws -> JSONValue { record("deviceDefaults"); return defaultsDevice }

    public func setFolder(_ folder: JSONValue) async throws {
        let id = folder["id"]?.stringValue ?? ""
        try action("setFolder \(id)")
        savedFolders.append(folder)
        let deviceIDs = folder["devices"]?.arrayValue?.compactMap { $0["deviceID"]?.stringValue }
        if let i = folderList.firstIndex(where: { $0.id == id }) {
            if let label = folder["label"]?.stringValue { folderList[i].label = label }
            if let path = folder["path"]?.stringValue { folderList[i].path = path }
            if let deviceIDs { folderList[i].deviceIDs = deviceIDs }
        } else {
            folderList.append(FolderConfig(id: id, label: folder["label"]?.stringValue ?? "",
                                           path: folder["path"]?.stringValue ?? "", deviceIDs: deviceIDs ?? []))
        }
    }

    public func setDevice(_ device: JSONValue) async throws {
        let id = device["deviceID"]?.stringValue ?? ""
        try action("setDevice \(id)")
        savedDevices.append(device)
        let name = device["name"]?.stringValue ?? ""
        if let i = deviceList.firstIndex(where: { $0.deviceID == id }) {
            deviceList[i].name = name
        } else {
            deviceList.append(DeviceConfig(deviceID: id, name: name))
        }
        pendingDeviceList.removeAll { $0.deviceID == id }
    }

    public func removeFolder(_ folderID: FolderID) async throws {
        try action("removeFolder \(folderID)")
        folderList.removeAll { $0.id == folderID }
    }

    public func removeDevice(_ deviceID: DeviceID) async throws {
        try action("removeDevice \(deviceID)")
        deviceList.removeAll { $0.deviceID == deviceID }
    }

    public func setFolderPaused(_ folderID: FolderID, paused: Bool) async throws {
        try action("setFolderPaused \(folderID) \(paused)")
        if let i = folderList.firstIndex(where: { $0.id == folderID }) { folderList[i].paused = paused }
    }

    public func setDevicePaused(_ deviceID: DeviceID?, paused: Bool) async throws {
        try action("\(paused ? "pause" : "resume") \(deviceID ?? "all")")
    }

    public func setDeviceName(_ name: String) async throws { try action("setDeviceName \(name)") }
    public func options() async throws -> JSONValue { record("options"); return optionsValue }

    public func setOptions(_ options: JSONValue) async throws {
        try action("setOptions")
        if case .object(let patch) = options, case .object(var current) = optionsValue {
            current.merge(patch) { $1 }
            optionsValue = .object(current)
        }
    }

    public func folderStatus(_ folderID: FolderID) async throws -> FolderStatus {
        record("folderStatus \(folderID)")
        guard let s = folderStatuses[folderID] else { throw SyncthingError.engine("no such folder") }
        return s
    }

    public func completion(folder: FolderID?, device: DeviceID?) async throws -> Completion {
        record("completion \(folder ?? "*") \(device ?? "local")")
        return device.flatMap { deviceCompletions[$0] } ?? Completion()
    }

    public func need(folder: FolderID, page: Int, perPage: Int) async throws -> NeedResponse { record("need \(folder)"); return needResponse }
    public func folderErrors(_ folderID: FolderID) async throws -> [FileError] { record("folderErrors \(folderID)"); return fileErrors[folderID] ?? [] }
    public func scan(folder: FolderID?) async throws { try action("scan \(folder ?? "all")") }
    public func pendingDevices() async throws -> [PendingDevice] { record("pendingDevices"); return pendingDeviceList }
    public func pendingFolders() async throws -> [PendingFolder] { record("pendingFolders"); return pendingFolderList }
    public func ignorePendingDevice(_ deviceID: DeviceID) async throws { try action("ignoreDevice \(deviceID)") }
    public func ignorePendingFolder(_ folder: PendingFolder) async throws { try action("ignoreFolder \(folder.folderID)") }

    public func events(since: Int, limit: Int?, timeout: Int) async throws -> [SyncthingEvent] {
        record("events since=\(since)\(limit.map { " limit=\($0)" } ?? "")")
        if limit == 1 && since == 0 { return [SyncthingEvent(id: 1, type: "Starting")] }
        if !eventBatches.isEmpty { return try eventBatches.removeFirst().get() }
        // Behave like an idle long-poll: wait until cancelled.
        try await Task.sleep(for: .seconds(3600))
        return []
    }
}

/// Sample data for previews, tests and demo mode.
public enum MockData {
    public static let myID = "P56IOI7-MZJNU2Y-IQGDREY-DM2MGTI-MGL3BXN-PQ6W5BM-TBBZ4TJ-XZWICQ2"
    public static let laptopID = "NFGKEKE-7Z6RTH7-I3PRZXS-DEJF3UJ-FRWJBFO-VBBTDND-4SGNGVZ-QUQHJAG"
    public static let phoneID = "DOVII4U-SQEEESM-VZ2CVTC-CJM4YN5-QNV7DCU-5U3ASRL-YVFG6TH-W5DV5AA"

    public static let folders = [
        FolderConfig(id: "photos", label: "Photos", path: "/data/photos", deviceIDs: [myID, laptopID, phoneID]),
        FolderConfig(id: "docs", label: "Documents", path: "/data/docs", deviceIDs: [myID, laptopID]),
        FolderConfig(id: "music", label: "Music", path: "/data/music", paused: true, deviceIDs: [myID, phoneID]),
    ]

    public static let devices = [
        DeviceConfig(deviceID: myID, name: "iPhone"),
        DeviceConfig(deviceID: laptopID, name: "MacBook"),
        DeviceConfig(deviceID: phoneID, name: "iPad"),
    ]

    /// A populated state for SwiftUI previews and demo mode.
    public static var state: NodeState {
        var s = NodeState()
        s.status = SystemStatus(myID: myID, uptime: 93_784)
        s.version = SystemVersion(version: "v2.1.5", os: "ios", arch: "arm64")
        s.applyFolders(folders)
        s.applyDevices(devices)
        s.folderStatuses = [
            "photos": FolderStatus(state: "syncing", globalBytes: 10_000_000_000, globalFiles: 12_034, globalDirectories: 312,
                                   localBytes: 8_200_000_000, needBytes: 1_800_000_000, needFiles: 1_200, needTotalItems: 1_200),
            "docs": FolderStatus(state: "idle", globalBytes: 420_000_000, globalFiles: 3_210, globalDirectories: 150,
                                 localBytes: 420_000_000, localFiles: 3_210, localDirectories: 150, inSyncBytes: 420_000_000),
        ]
        s.connections = [
            laptopID: ConnectionInfo(connected: true, address: "192.168.1.20:22000", clientVersion: "v2.1.5", type: "tcp-client"),
            phoneID: ConnectionInfo(connected: false),
        ]
        s.totalRates = TransferRates(inBps: 1_250_000, outBps: 84_000)
        s.deviceCompletion = [laptopID: Completion(completion: 82)]
        s.deviceStats = [phoneID: DeviceStatistics(lastSeen: Date().addingTimeInterval(-7200))]
        s.pendingFolders = [PendingFolder(folderID: "work-notes", offeredBy: laptopID, label: "Work Notes", time: .now)]
        return s
    }
}
