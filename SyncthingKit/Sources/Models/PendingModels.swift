import Foundation

/// A remote device that tried to connect but is not configured
/// (`GET /rest/cluster/pending/devices`).
public struct PendingDevice: Sendable, Equatable, Identifiable, Hashable {
    public var deviceID: DeviceID
    public var name: String
    public var address: String
    public var time: Date?

    public var id: DeviceID { deviceID }

    public init(deviceID: DeviceID, name: String = "", address: String = "", time: Date? = nil) {
        self.deviceID = deviceID; self.name = name; self.address = address; self.time = time
    }
}

/// A folder offered by a remote device but not shared back
/// (`GET /rest/cluster/pending/folders`), flattened to one entry per offer.
public struct PendingFolder: Sendable, Equatable, Identifiable, Hashable {
    public var folderID: FolderID
    public var offeredBy: DeviceID
    public var label: String
    public var time: Date?
    public var receiveEncrypted: Bool
    public var remoteEncrypted: Bool

    public var id: String { "\(folderID)|\(offeredBy)" }

    public init(folderID: FolderID, offeredBy: DeviceID, label: String = "", time: Date? = nil,
                receiveEncrypted: Bool = false, remoteEncrypted: Bool = false) {
        self.folderID = folderID; self.offeredBy = offeredBy; self.label = label; self.time = time
        self.receiveEncrypted = receiveEncrypted; self.remoteEncrypted = remoteEncrypted
    }

    public var displayName: String { label.isEmpty ? folderID : label }
}

enum PendingDecoding {
    private struct DeviceEntry: Decodable {
        var name: String
        var address: String
        var time: Date?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            name = c.lenient(AnyKey("name"), "")
            address = c.lenient(AnyKey("address"), "")
            time = c.lenientDate(AnyKey("time"))
        }
    }

    private struct Offer: Decodable {
        var label: String
        var time: Date?
        var receiveEncrypted: Bool
        var remoteEncrypted: Bool
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            label = c.lenient(AnyKey("label"), "")
            time = c.lenientDate(AnyKey("time"))
            receiveEncrypted = c.lenientBool(AnyKey("receiveEncrypted"))
            remoteEncrypted = c.lenientBool(AnyKey("remoteEncrypted"))
        }
    }

    private struct FolderEntry: Decodable {
        var offeredBy: [String: Offer]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            offeredBy = c.lenient(AnyKey("offeredBy"), [:])
        }
    }

    static func devices(from data: Data) throws -> [PendingDevice] {
        // An empty result may be `null` or `{}`.
        let raw = try JSONDecoder().decode([String: DeviceEntry]?.self, from: data) ?? [:]
        return raw.map { PendingDevice(deviceID: $0.key, name: $0.value.name, address: $0.value.address, time: $0.value.time) }
            .sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
    }

    static func folders(from data: Data) throws -> [PendingFolder] {
        let raw = try JSONDecoder().decode([String: FolderEntry]?.self, from: data) ?? [:]
        return raw.flatMap { folderID, entry in
            entry.offeredBy.map { deviceID, offer in
                PendingFolder(folderID: folderID, offeredBy: deviceID, label: offer.label, time: offer.time,
                              receiveEncrypted: offer.receiveEncrypted, remoteEncrypted: offer.remoteEncrypted)
            }
        }
        .sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
    }
}
