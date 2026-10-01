import Foundation

/// A folder to create or update. Encodes to the partial config object the
/// engine applies on top of the folder defaults.
public struct FolderDraft: Sendable, Equatable {
    public var id: FolderID
    public var label: String
    public var path: String
    public var type: String
    public var deviceIDs: [DeviceID]

    public init(id: FolderID = FolderDraft.generateID(), label: String = "", path: String = "",
                type: String = "sendreceive", deviceIDs: [DeviceID] = []) {
        self.id = id; self.label = label; self.path = path; self.type = type; self.deviceIDs = deviceIDs
    }

    /// Accepting a folder offered by a remote device.
    public init(accepting pending: PendingFolder, path: String) {
        self.init(id: pending.folderID, label: pending.label, path: path,
                  type: pending.receiveEncrypted ? "receiveencrypted" : "sendreceive",
                  deviceIDs: [pending.offeredBy])
    }

    public var json: JSONValue {
        [
            "id": .string(id),
            "label": .string(label),
            "path": .string(path),
            "type": .string(type),
            "devices": .array(deviceIDs.map { ["deviceID": .string($0)] }),
        ]
    }

    /// Partial object that only changes a folder's device list.
    public static func sharing(_ folderID: FolderID, with devices: [DeviceID]) -> JSONValue {
        ["id": .string(folderID), "devices": .array(devices.map { ["deviceID": .string($0)] })]
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

    public init(deviceID: DeviceID, name: String = "", addresses: [String] = ["dynamic"]) {
        self.deviceID = deviceID; self.name = name; self.addresses = addresses
    }

    public var json: JSONValue {
        [
            "deviceID": .string(deviceID),
            "name": .string(name),
            "addresses": .array((addresses.isEmpty ? ["dynamic"] : addresses).map { .string($0) }),
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
