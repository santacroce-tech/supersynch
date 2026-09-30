import Foundation

/// User-facing folder state, derived from config + `db/status`. Views map
/// each case to a colour and SF Symbol.
public enum FolderSyncState: Sendable, Equatable {
    case upToDate
    case syncing(percent: Double)
    case scanning(percent: Double?)
    case waiting
    case paused
    case error
    case outOfSync
    case unknown

    public static func derive(paused: Bool, status: FolderStatus?, scanProgress: ScanProgress? = nil) -> FolderSyncState {
        if paused { return .paused }
        guard let status else { return .unknown }
        switch status.state {
        case "error":
            return .error
        case "scanning":
            return .scanning(percent: scanProgress?.percent)
        case "syncing", "sync-preparing":
            return .syncing(percent: status.completion)
        case "scan-waiting", "sync-waiting", "clean-waiting":
            return .waiting
        case "cleaning":
            return .scanning(percent: nil)
        case "idle":
            if status.pullErrors > 0 || status.needTotalItems > 0 { return .outOfSync }
            return .upToDate
        default:
            return .unknown
        }
    }

    public var label: String {
        switch self {
        case .upToDate: String(localized: "Up to Date", bundle: SyncthingKit.bundle)
        case .syncing: String(localized: "Syncing", bundle: SyncthingKit.bundle)
        case .scanning: String(localized: "Scanning", bundle: SyncthingKit.bundle)
        case .waiting: String(localized: "Waiting", bundle: SyncthingKit.bundle)
        case .paused: String(localized: "Paused", bundle: SyncthingKit.bundle)
        case .error: String(localized: "Error", bundle: SyncthingKit.bundle)
        case .outOfSync: String(localized: "Out of Sync", bundle: SyncthingKit.bundle)
        case .unknown: String(localized: "Unknown", bundle: SyncthingKit.bundle)
        }
    }
}

public enum DeviceSyncState: Sendable, Equatable {
    case upToDate
    case syncing(percent: Double)
    case disconnected
    case paused
    case unused

    public static func derive(paused: Bool, connected: Bool, completion: Completion?, sharedFolderCount: Int) -> DeviceSyncState {
        if paused { return .paused }
        if !connected { return .disconnected }
        if sharedFolderCount == 0 { return .unused }
        if let completion, completion.completion < 100 { return .syncing(percent: completion.completion) }
        return .upToDate
    }

    public var label: String {
        switch self {
        case .upToDate: String(localized: "Up to Date", bundle: SyncthingKit.bundle)
        case .syncing: String(localized: "Syncing", bundle: SyncthingKit.bundle)
        case .disconnected: String(localized: "Disconnected", bundle: SyncthingKit.bundle)
        case .paused: String(localized: "Paused", bundle: SyncthingKit.bundle)
        case .unused: String(localized: "Connected (Unused)", bundle: SyncthingKit.bundle)
        }
    }
}

public struct ScanProgress: Sendable, Equatable {
    public var current: Int64
    public var total: Int64
    public var rate: Double

    public init(current: Int64, total: Int64, rate: Double) {
        self.current = current; self.total = total; self.rate = rate
    }

    public var percent: Double? {
        guard total > 0 else { return nil }
        return min(100, Double(current) / Double(total) * 100)
    }
}
