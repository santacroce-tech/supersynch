import Foundation

/// A folder to create or update. Encodes to the partial config object the
/// engine applies on top of the folder defaults.
public struct FolderDraft: Sendable, Equatable {
    public var id: FolderID
    public var label: String
    public var path: String
    public var type: String
    public var deviceIDs: [DeviceID]
    /// Set for devices that should only receive encrypted data (untrusted).
    public var encryptionPasswords: [DeviceID: String]
    /// nil leaves versioning unchanged (or at the default for new folders).
    public var versioning: Versioning?

    public init(id: FolderID = FolderDraft.generateID(), label: String = "", path: String = "",
                type: String = "sendreceive", deviceIDs: [DeviceID] = [],
                encryptionPasswords: [DeviceID: String] = [:], versioning: Versioning? = nil) {
        self.id = id; self.label = label; self.path = path; self.type = type; self.deviceIDs = deviceIDs
        self.encryptionPasswords = encryptionPasswords; self.versioning = versioning
    }

    /// Accepting a folder offered by a remote device.
    public init(accepting pending: PendingFolder, path: String) {
        self.init(id: pending.folderID, label: pending.label, path: path,
                  type: pending.receiveEncrypted ? "receiveencrypted" : "sendreceive",
                  deviceIDs: [pending.offeredBy])
    }

    public var json: JSONValue {
        var object: JSONValue = [
            "id": .string(id),
            "label": .string(label),
            "path": .string(path),
            "type": .string(type),
            "devices": Self.devicesJSON(deviceIDs, passwords: encryptionPasswords),
        ]
        if let versioning { object["versioning"] = versioning.json }
        return object
    }

    static func devicesJSON(_ devices: [DeviceID], passwords: [DeviceID: String]) -> JSONValue {
        .array(devices.map { id in
            var entry: JSONValue = ["deviceID": .string(id)]
            if let password = passwords[id], !password.isEmpty { entry["encryptionPassword"] = .string(password) }
            return entry
        })
    }

    /// Partial object that only changes a folder's device list, keeping
    /// existing encryption passwords (Syncthing replaces the whole list).
    public static func sharing(_ folder: FolderConfig, with devices: [DeviceID]) -> JSONValue {
        ["id": .string(folder.id), "devices": devicesJSON(devices, passwords: folder.encryptionPasswords)]
    }

    /// Random ID in Syncthing's GUI style (`abcde-fghij`).
    public static func generateID() -> FolderID {
        let chars = Array("abcdefghijkmnopqrstuvwxyz23456789")
        func chunk() -> String { String((0..<5).map { _ in chars.randomElement()! }) }
        return "\(chunk())-\(chunk())"
    }
}

/// A remote device to add or update.
public struct DeviceDraft: Sendable, Equatable {
    public var deviceID: DeviceID
    public var name: String
    /// `dynamic` (discovery) or explicit addresses like `tcp://macbook.local:22000`.
    public var addresses: [String]
    /// Accept devices and folders this device introduces.
    public var introducer: Bool
    /// Bandwidth limits in KiB/s; 0 = unlimited.
    public var maxSendKbps: Int
    public var maxRecvKbps: Int

    public init(deviceID: DeviceID, name: String = "", addresses: [String] = ["dynamic"],
                introducer: Bool = false, maxSendKbps: Int = 0, maxRecvKbps: Int = 0) {
        self.deviceID = deviceID; self.name = name; self.addresses = addresses
        self.introducer = introducer; self.maxSendKbps = maxSendKbps; self.maxRecvKbps = maxRecvKbps
    }

    public var json: JSONValue {
        [
            "deviceID": .string(deviceID),
            "name": .string(name),
            "addresses": .array((addresses.isEmpty ? ["dynamic"] : addresses).map { .string($0) }),
            "introducer": .bool(introducer),
            "maxSendKbps": .number(Double(maxSendKbps)),
            "maxRecvKbps": .number(Double(maxRecvKbps)),
        ]
    }
}

/// Syncthing device ID validation and normalisation (Luhn base32 check
/// characters, as in lib/protocol/deviceid.go).
public enum DeviceIDValidator {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// Returns the canonical `XXXXXXX-XXXXXXX-…` form, or nil if invalid.
    /// Accepts lowercase, missing/extra dashes and spaces, and common
    /// look-alikes (0→O, 1→I, 8→B), like Syncthing does.
    public static func normalize(_ input: String) -> DeviceID? {
        var s = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        s = String(s.map { c -> Character in
            switch c {
            case "0": "O"
            case "1": "I"
            case "8": "B"
            default: c
            }
        })
        guard s.count == 56, s.allSatisfy({ alphabet.contains($0) }) else { return nil }
        let chars = Array(s)
        // 4 groups of 13 data chars + 1 check char.
        for g in 0..<4 {
            let group = chars[(g * 14)..<(g * 14 + 13)]
            guard luhn(group) == chars[g * 14 + 13] else { return nil }
        }
        return stride(from: 0, to: 56, by: 7).map { String(chars[$0..<($0 + 7)]) }.joined(separator: "-")
    }

    private static func luhn<C: Collection>(_ s: C) -> Character where C.Element == Character {
        let n = alphabet.count
        var factor = 1
        var sum = 0
        for c in s {
            guard let codepoint = alphabet.firstIndex(of: c) else { return " " }
            var addend = factor * codepoint
            factor = factor == 2 ? 1 : 2
            addend = addend / n + addend % n
            sum += addend
        }
        let remainder = sum % n
        return alphabet[(n - remainder) % n]
    }
}
