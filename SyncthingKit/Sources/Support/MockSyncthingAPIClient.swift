import Foundation

/// In-memory `SyncthingAPIClient` for unit tests and SwiftUI previews.
/// Records every call; responses are configurable per endpoint.
public actor MockSyncthingAPIClient: SyncthingAPIClient {
    public var healthResponse: Result<HealthResponse, SyncthingError> = .success(HealthResponse(status: "OK"))
    public var statusResponse: Result<SystemStatus, SyncthingError> = .success(SystemStatus(myID: MockData.myID, uptime: 93_784))
    public var versionResponse: Result<SystemVersion, SyncthingError> = .success(SystemVersion(version: "v2.0.10", os: "linux", arch: "amd64"))
    public var connectionsResponse = ConnectionsResponse()
    public var folderList: [FolderConfig] = []
    public var deviceList: [DeviceConfig] = []
    public var folderStatuses: [FolderID: FolderStatus] = [:]
    public var deviceCompletions: [DeviceID: Completion] = [:]
    public var needResponse = NeedResponse()
    public var fileErrors: [FolderID: [FileError]] = [:]
    public var errors: [SystemError] = []
    public var devStats: [DeviceID: DeviceStatistics] = [:]
    public var fldStats: [FolderID: FolderStatistics] = [:]
    public var pendingDeviceList: [PendingDevice] = []
    public var pendingFolderList: [PendingFolder] = []
    public var defaultsFolder: JSONValue = .object(["path": .string("~"), "devices": .array([])])
    public var defaultsDevice: JSONValue = .object(["addresses": .array([.string("dynamic")])])
    /// Queue of long-poll results; when empty, `events` suspends until cancelled.
    public var eventBatches: [Result<[SyncthingEvent], SyncthingError>] = []
    public var actionError: SyncthingError?

    public private(set) var calls: [String] = []

    public init() {}

    /// A mock that serves `state` (for demo mode and previews).
    public init(preloaded state: ServerState) {
        if let status = state.status { statusResponse = .success(status) }
        if let version = state.version { versionResponse = .success(version) }
        folderList = state.folders
        deviceList = state.devices
        folderStatuses = state.folderStatuses
        connectionsResponse = ConnectionsResponse(connections: state.connections, total: state.totals ?? TransferTotals())
        deviceCompletions = state.deviceCompletion
        devStats = state.deviceStats
        fldStats = state.folderStats
        errors = state.systemErrors
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

    public func health() async throws -> HealthResponse { record("health"); return try healthResponse.get() }
    public func ping() async throws { record("ping") }
    public func systemStatus() async throws -> SystemStatus { record("status"); return try statusResponse.get() }
    public func systemVersion() async throws -> SystemVersion { record("version"); return try versionResponse.get() }
    public func connections() async throws -> ConnectionsResponse { record("connections"); return connectionsResponse }
    public func deviceStats() async throws -> [DeviceID: DeviceStatistics] { record("deviceStats"); return devStats }
    public func folderStats() async throws -> [FolderID: FolderStatistics] { record("folderStats"); return fldStats }
    public func folders() async throws -> [FolderConfig] { record("folders"); return folderList }
    public func devices() async throws -> [DeviceConfig] { record("devices"); return deviceList }

    public func setFolderPaused(_ folderID: FolderID, paused: Bool) async throws {
        try action("setFolderPaused \(folderID) \(paused)")
        if let i = folderList.firstIndex(where: { $0.id == folderID }) { folderList[i].paused = paused }
    }

    public func folderDefaults() async throws -> JSONValue { record("folderDefaults"); return defaultsFolder }
    public func deviceDefaults() async throws -> JSONValue { record("deviceDefaults"); return defaultsDevice }
    public func addFolder(_ folder: JSONValue) async throws { try action("addFolder \(folder["id"]?.stringValue ?? "")") }
    public func addDevice(_ device: JSONValue) async throws { try action("addDevice \(device["deviceID"]?.stringValue ?? "")") }

    public func folderStatus(_ folderID: FolderID) async throws -> FolderStatus {
        record("folderStatus \(folderID)")
        guard let s = folderStatuses[folderID] else { throw SyncthingError.notFound }
        return s
    }

    public func completion(folder: FolderID?, device: DeviceID?) async throws -> Completion {
        record("completion \(folder ?? "*") \(device ?? "local")")
        return device.flatMap { deviceCompletions[$0] } ?? Completion()
    }

    public func need(folder: FolderID, page: Int, perPage: Int) async throws -> NeedResponse { record("need \(folder)"); return needResponse }
    public func folderErrors(_ folderID: FolderID) async throws -> [FileError] { record("folderErrors \(folderID)"); return fileErrors[folderID] ?? [] }
    public func scan(folder: FolderID) async throws { try action("scan \(folder)") }
    public func systemErrors() async throws -> [SystemError] { record("systemErrors"); return errors }
    public func clearSystemErrors() async throws { try action("clearErrors"); errors = [] }
    public func pendingDevices() async throws -> [PendingDevice] { record("pendingDevices"); return pendingDeviceList }
    public func pendingFolders() async throws -> [PendingFolder] { record("pendingFolders"); return pendingFolderList }
    public func dismissPendingDevice(_ deviceID: DeviceID) async throws { try action("dismissDevice \(deviceID)") }
    public func dismissPendingFolder(_ folderID: FolderID, device: DeviceID?) async throws { try action("dismissFolder \(folderID)") }
    public func pause(device: DeviceID?) async throws { try action("pause \(device ?? "all")") }
    public func resume(device: DeviceID?) async throws { try action("resume \(device ?? "all")") }
    public func restart() async throws { try action("restart") }
    public func shutdown() async throws { try action("shutdown") }

    public func events(since: Int, limit: Int?, timeout: Int) async throws -> [SyncthingEvent] {
        record("events since=\(since)\(limit.map { " limit=\($0)" } ?? "")")
        if limit == 1 && since == 0 { return [SyncthingEvent(id: 1, type: "Starting")] }
        if !eventBatches.isEmpty { return try eventBatches.removeFirst().get() }
        // Behave like an idle long-poll: wait until cancelled.
        try await Task.sleep(for: .seconds(3600))
        return []
    }
}

/// Sample data for previews and tests.
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
        DeviceConfig(deviceID: myID, name: "nas"),
        DeviceConfig(deviceID: laptopID, name: "Laptop"),
        DeviceConfig(deviceID: phoneID, name: "Phone"),
    ]

    /// A populated state for SwiftUI previews.
    public static var state: ServerState {
        var s = ServerState()
        s.status = SystemStatus(myID: myID, uptime: 93_784)
        s.version = SystemVersion(version: "v2.0.10", os: "linux", arch: "amd64")
        s.applyFolders(folders)
        s.applyDevices(devices)
        s.folderStatuses = [
            "photos": FolderStatus(state: "syncing", globalBytes: 10_000_000_000, globalFiles: 12_034, globalDirectories: 312,
                                   localBytes: 8_200_000_000, needBytes: 1_800_000_000, needFiles: 1_200, needTotalItems: 1_200),
            "docs": FolderStatus(state: "idle", globalBytes: 420_000_000, globalFiles: 3_210, globalDirectories: 150,
                                 localBytes: 420_000_000, inSyncBytes: 420_000_000),
        ]
        s.connections = [
            laptopID: ConnectionInfo(connected: true, address: "192.168.1.20:22000", clientVersion: "v2.0.10", type: "tcp-client"),
            phoneID: ConnectionInfo(connected: false),
        ]
        s.totalRates = TransferRates(inBps: 1_250_000, outBps: 84_000)
        s.deviceRates = [laptopID: TransferRates(inBps: 1_250_000, outBps: 84_000)]
        s.deviceCompletion = [laptopID: Completion(completion: 82)]
        s.deviceStats = [phoneID: DeviceStatistics(lastSeen: Date().addingTimeInterval(-7200))]
        s.pendingDevices = [PendingDevice(deviceID: "EJHMPAQ-OGCVORE-ISB4IS3-SYYVJXF-TKJGLTU-66DIQPF-GJ5D2GX-GQ3OWQK",
                                          name: "My dusty computer", address: "192.168.1.44:51807", time: .now)]
        return s
    }
}
