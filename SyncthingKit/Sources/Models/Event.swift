import Foundation

/// One event from `GET /rest/events`. The `data` payload depends on `type`
/// and is kept as raw JSON; `payload` decodes the types the app reacts to.
public struct SyncthingEvent: Decodable, Sendable, Equatable {
    public var id: Int
    public var globalID: Int
    public var type: String
    public var time: Date?
    public var data: JSONValue

    public init(id: Int, type: String, time: Date? = nil, data: JSONValue = .null, globalID: Int? = nil) {
        self.id = id; self.type = type; self.time = time; self.data = data; self.globalID = globalID ?? id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.lenientInt(AnyKey("id"))
        globalID = c.lenientInt(AnyKey("globalID"))
        type = c.lenient(AnyKey("type"), "")
        time = c.lenientDate(AnyKey("time"))
        data = c.lenient(AnyKey("data"), .null)
    }

    public var payload: EventPayload { EventPayload(type: type, data: data) }
}

/// Typed view of the event payloads the reducer understands. Unknown or
/// malformed payloads become `.other` rather than failing.
public enum EventPayload: Sendable, Equatable {
    case stateChanged(folder: FolderID, from: String, to: String)
    case folderSummary(folder: FolderID, summary: FolderStatus)
    case folderCompletion(folder: FolderID, device: DeviceID, completion: Completion)
    case folderErrors(folder: FolderID, errors: [FileError])
    case folderScanProgress(folder: FolderID, current: Int64, total: Int64, rate: Double)
    case folderPaused(folder: FolderID)
    case folderResumed(folder: FolderID)
    case deviceConnected(device: DeviceID, address: String, clientVersion: String, connectionType: String)
    case deviceDisconnected(device: DeviceID, error: String)
    case devicePaused(device: DeviceID)
    case deviceResumed(device: DeviceID)
    case configSaved(folders: [FolderConfig]?, devices: [DeviceConfig]?)
    case pendingDevicesChanged
    case pendingFoldersChanged
    case other(type: String)

    init(type: String, data: JSONValue) {
        func str(_ key: String) -> String { data[key]?.stringValue ?? "" }
        func num(_ key: String) -> Double {
            if case .number(let n)? = data[key] { return n }
            return Double(str(key)) ?? 0
        }

        switch type {
        case "StateChanged":
            self = .stateChanged(folder: str("folder"), from: str("from"), to: str("to"))
        case "FolderSummary":
            let summary = (try? data["summary"]?.decode(FolderStatus.self)) ?? FolderStatus()
            self = .folderSummary(folder: str("folder"), summary: summary)
        case "FolderCompletion":
            let completion = (try? data.decode(Completion.self)) ?? Completion()
            self = .folderCompletion(folder: str("folder"), device: str("device"), completion: completion)
        case "FolderErrors":
            let errors = (try? data["errors"]?.decode([FileError].self)) ?? []
            self = .folderErrors(folder: str("folder"), errors: errors)
        case "FolderScanProgress":
            self = .folderScanProgress(folder: str("folder"), current: Int64(num("current")),
                                       total: Int64(num("total")), rate: num("rate"))
        case "FolderPaused":
            self = .folderPaused(folder: str("id"))
        case "FolderResumed":
            self = .folderResumed(folder: str("id"))
        case "DeviceConnected":
            self = .deviceConnected(device: str("id"), address: str("addr"),
                                    clientVersion: str("clientVersion"), connectionType: str("type"))
        case "DeviceDisconnected":
            self = .deviceDisconnected(device: str("id"), error: str("error"))
        case "DevicePaused":
            self = .devicePaused(device: str("device"))
        case "DeviceResumed":
            self = .deviceResumed(device: str("device"))
        case "ConfigSaved":
            let folders = try? data["folders"]?.decode([FolderConfig].self)
            let devices = try? data["devices"]?.decode([DeviceConfig].self)
            self = .configSaved(folders: folders, devices: devices)
        case "PendingDevicesChanged":
            self = .pendingDevicesChanged
        case "PendingFoldersChanged":
            self = .pendingFoldersChanged
        default:
            self = .other(type: type)
        }
    }
}
