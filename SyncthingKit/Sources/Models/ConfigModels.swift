import Foundation

/// A folder as returned by `GET /rest/config/folders`. Only the fields the app
/// displays are modelled; edits use `PATCH` so unknown fields are preserved
/// server-side.
public struct FolderConfig: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public var id: FolderID
    public var label: String
    public var path: String
    public var type: String
    public var paused: Bool
    public var deviceIDs: [DeviceID]
    public var rescanIntervalS: Int
    public var fsWatcherEnabled: Bool

    public init(
        id: FolderID, label: String = "", path: String = "", type: String = "sendreceive",
        paused: Bool = false, deviceIDs: [DeviceID] = [], rescanIntervalS: Int = 3600,
        fsWatcherEnabled: Bool = true
    ) {
        self.id = id; self.label = label; self.path = path; self.type = type; self.paused = paused
        self.deviceIDs = deviceIDs; self.rescanIntervalS = rescanIntervalS
        self.fsWatcherEnabled = fsWatcherEnabled
    }

    private struct FolderDevice: Decodable {
        var deviceID: String
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            deviceID = c.lenient(AnyKey("deviceID"), "")
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.lenient(AnyKey("id"), "")
        label = c.lenient(AnyKey("label"), "")
        path = c.lenient(AnyKey("path"), "")
        type = c.lenient(AnyKey("type"), "sendreceive")
        paused = c.lenientBool(AnyKey("paused"))
        let devices: [FolderDevice] = c.lenient(AnyKey("devices"), [])
        deviceIDs = devices.map(\.deviceID).filter { !$0.isEmpty }
        rescanIntervalS = c.lenientInt(AnyKey("rescanIntervalS"))
        fsWatcherEnabled = c.lenientBool(AnyKey("fsWatcherEnabled"))
    }

    /// Label for display; Syncthing allows empty labels, falling back to the ID.
    public var displayName: String { label.isEmpty ? id : label }

    public var typeDescription: String {
        switch type {
        case "sendreceive": String(localized: "Send & Receive", bundle: SyncthingKit.bundle)
        case "sendonly": String(localized: "Send Only", bundle: SyncthingKit.bundle)
        case "receiveonly": String(localized: "Receive Only", bundle: SyncthingKit.bundle)
        case "receiveencrypted": String(localized: "Receive Encrypted", bundle: SyncthingKit.bundle)
        default: type
        }
    }
}

/// A device as returned by `GET /rest/config/devices`.
public struct DeviceConfig: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public var deviceID: DeviceID
    public var name: String
    public var addresses: [String]
    public var paused: Bool
    public var compression: String
    public var introducer: Bool

    public var id: DeviceID { deviceID }

    public init(
        deviceID: DeviceID, name: String = "", addresses: [String] = ["dynamic"], paused: Bool = false,
        compression: String = "metadata", introducer: Bool = false
    ) {
        self.deviceID = deviceID; self.name = name; self.addresses = addresses; self.paused = paused
        self.compression = compression; self.introducer = introducer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        deviceID = c.lenient(AnyKey("deviceID"), "")
        name = c.lenient(AnyKey("name"), "")
        addresses = c.lenient(AnyKey("addresses"), [])
        paused = c.lenientBool(AnyKey("paused"))
        compression = c.lenient(AnyKey("compression"), "")
        introducer = c.lenientBool(AnyKey("introducer"))
    }

    public var displayName: String { name.isEmpty ? DeviceIDFormat.short(deviceID) : name }
}

public enum DeviceIDFormat {
    /// First group of a device ID, as the Syncthing GUI shows it.
    public static func short(_ id: DeviceID) -> String {
        String(id.split(separator: "-").first ?? Substring(id))
    }
}
