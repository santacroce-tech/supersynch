import Foundation

/// The single abstraction over the embedded Syncthing node. Production uses
/// `EmbeddedSyncthingClient` (the gomobile bridge); tests and previews use
/// `MockSyncthingAPIClient`.
///
/// Responses are shaped like Syncthing's REST API
/// (https://docs.syncthing.net/dev/rest.html), so the same lenient models
/// decode them.
public protocol SyncthingAPIClient: Sendable {
    // Identity
    func systemStatus() async throws -> SystemStatus
    func systemVersion() async throws -> SystemVersion

    // Connections & stats
    func connections() async throws -> ConnectionsResponse
    func deviceStats() async throws -> [DeviceID: DeviceStatistics]
    func folderStats() async throws -> [FolderID: FolderStatistics]

    // Config
    func folders() async throws -> [FolderConfig]
    func devices() async throws -> [DeviceConfig]
    func folderDefaults() async throws -> JSONValue
    func deviceDefaults() async throws -> JSONValue
    /// Adds or replaces a folder; the object is applied on top of the defaults.
    func setFolder(_ folder: JSONValue) async throws
    /// Adds or replaces a device; the object is applied on top of the defaults.
    func setDevice(_ device: JSONValue) async throws
    func removeFolder(_ folderID: FolderID) async throws
    func removeDevice(_ deviceID: DeviceID) async throws
    func setFolderPaused(_ folderID: FolderID, paused: Bool) async throws
    /// `device == nil` pauses/resumes every remote device.
    func setDevicePaused(_ deviceID: DeviceID?, paused: Bool) async throws
    func setDeviceName(_ name: String) async throws
    func options() async throws -> JSONValue
    /// Applies a partial options object.
    func setOptions(_ options: JSONValue) async throws

    // Folder state
    func folderStatus(_ folderID: FolderID) async throws -> FolderStatus
    func completion(folder: FolderID?, device: DeviceID?) async throws -> Completion
    func need(folder: FolderID, page: Int, perPage: Int) async throws -> NeedResponse
    func folderErrors(_ folderID: FolderID) async throws -> [FileError]
    /// `folder == nil` rescans every folder.
    func scan(folder: FolderID?) async throws

    // Pending
    func pendingDevices() async throws -> [PendingDevice]
    func pendingFolders() async throws -> [PendingFolder]
    /// Permanently ignores (recorded in config).
    func ignorePendingDevice(_ deviceID: DeviceID) async throws
    func ignorePendingFolder(_ folder: PendingFolder) async throws
    /// Forgets the request; it reappears if the device asks again.
    func dismissPendingDevice(_ deviceID: DeviceID) async throws
    func dismissPendingFolder(_ folder: PendingFolder) async throws

    // Maintenance
    func folderVersions(_ folderID: FolderID) async throws -> [String: [FileVersion]]
    /// Restores the given file → version; returns paths that failed with their error.
    func restoreVersions(_ folderID: FolderID, _ versions: [String: FileVersion]) async throws -> [String: String]
    func ignores(_ folderID: FolderID) async throws -> IgnorePatterns
    func setIgnores(_ folderID: FolderID, lines: [String]) async throws
    /// Send-only folders: make the local state authoritative.
    func override(_ folderID: FolderID) async throws
    /// Receive-only folders: discard local changes.
    func revert(_ folderID: FolderID) async throws

    // Log
    func systemErrors() async throws -> [LogEntry]
    func clearSystemErrors() async throws
    func systemLog() async throws -> [LogEntry]

    // Events (long-poll). Blocks up to `timeout` seconds when there are none.
    func events(since: Int, limit: Int?, timeout: Int) async throws -> [SyncthingEvent]
}
