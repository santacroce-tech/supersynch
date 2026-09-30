import Foundation

/// The single abstraction over Syncthing's REST API. iPhone and iPad use the
/// same implementation (`SyncthingHTTPClient`); tests use `MockSyncthingAPIClient`.
///
/// Shapes follow https://docs.syncthing.net/dev/rest.html (verified against
/// the docs source for Syncthing v1.x/v2.x). All decoding is lenient.
public protocol SyncthingAPIClient: Sendable {
    // Health & identity
    func health() async throws -> HealthResponse
    func ping() async throws
    func systemStatus() async throws -> SystemStatus
    func systemVersion() async throws -> SystemVersion

    // Connections & stats
    func connections() async throws -> ConnectionsResponse
    func deviceStats() async throws -> [DeviceID: DeviceStatistics]
    func folderStats() async throws -> [FolderID: FolderStatistics]

    // Config (`/rest/config`, not the deprecated `/rest/system/config`)
    func folders() async throws -> [FolderConfig]
    func devices() async throws -> [DeviceConfig]
    func setFolderPaused(_ folderID: FolderID, paused: Bool) async throws
    func folderDefaults() async throws -> JSONValue
    func deviceDefaults() async throws -> JSONValue
    func addFolder(_ folder: JSONValue) async throws
    func addDevice(_ device: JSONValue) async throws

    // Folder state
    func folderStatus(_ folderID: FolderID) async throws -> FolderStatus
    func completion(folder: FolderID?, device: DeviceID?) async throws -> Completion
    func need(folder: FolderID, page: Int, perPage: Int) async throws -> NeedResponse
    func folderErrors(_ folderID: FolderID) async throws -> [FileError]
    func scan(folder: FolderID) async throws

    // Errors
    func systemErrors() async throws -> [SystemError]
    func clearSystemErrors() async throws

    // Pending
    func pendingDevices() async throws -> [PendingDevice]
    func pendingFolders() async throws -> [PendingFolder]
    func dismissPendingDevice(_ deviceID: DeviceID) async throws
    func dismissPendingFolder(_ folderID: FolderID, device: DeviceID?) async throws

    // Lifecycle. `device == nil` means all devices.
    func pause(device: DeviceID?) async throws
    func resume(device: DeviceID?) async throws
    func restart() async throws
    func shutdown() async throws

    // Events (long-poll). Blocks server-side up to `timeout` seconds.
    func events(since: Int, limit: Int?, timeout: Int) async throws -> [SyncthingEvent]
}
