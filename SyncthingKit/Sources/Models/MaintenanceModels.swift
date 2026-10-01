import Foundation

/// A warning or error from Syncthing's log (`/rest/system/error`, `/rest/system/log`).
public struct LogEntry: Decodable, Sendable, Equatable, Hashable {
    public var when: Date?
    public var message: String
    /// slog level: 4 = warning, 8 = error.
    public var level: Int

    public init(when: Date?, message: String, level: Int = 8) {
        self.when = when; self.message = message; self.level = level
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        when = c.lenientDate(AnyKey("when"))
        message = c.lenient(AnyKey("message"), "")
        level = c.lenientInt(AnyKey("level"))
    }

    public var isError: Bool { level >= 8 }
}

struct LogResponse: Decodable {
    var entries: [LogEntry]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        // `/rest/system/error` uses "errors", `/rest/system/log` uses "messages".
        let errors: [LogEntry] = c.lenient(AnyKey("errors"), [])
        let messages: [LogEntry] = c.lenient(AnyKey("messages"), [])
        entries = errors + messages
    }
}

/// One archived version of a file (`/rest/folder/versions`).
public struct FileVersion: Decodable, Sendable, Equatable, Hashable {
    public var versionTime: Date
    public var modTime: Date?
    public var size: Int64
    /// The raw timestamp string, passed back verbatim when restoring.
    public var versionTimeRaw: String

    public init(versionTime: Date, versionTimeRaw: String, modTime: Date? = nil, size: Int64 = 0) {
        self.versionTime = versionTime; self.versionTimeRaw = versionTimeRaw; self.modTime = modTime; self.size = size
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        versionTimeRaw = c.lenient(AnyKey("versionTime"), "")
        versionTime = SyncthingDate.parse(versionTimeRaw) ?? .distantPast
        modTime = c.lenientDate(AnyKey("modTime"))
        size = c.lenientInt64(AnyKey("size"))
    }
}

/// `/rest/db/ignores`
public struct IgnorePatterns: Decodable, Sendable, Equatable {
    public var lines: [String]
    public var expanded: [String]

    public init(lines: [String], expanded: [String] = []) { self.lines = lines; self.expanded = expanded }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        lines = c.lenient(AnyKey("ignore"), [])
        expanded = c.lenient(AnyKey("expanded"), [])
    }
}

/// Folder versioning settings (config `versioning`).
public struct Versioning: Sendable, Equatable, Hashable {
    /// "" (off), "trashcan", "simple", "staggered" or "external".
    public var type: String
    public var params: [String: String]

    public init(type: String = "", params: [String: String] = [:]) { self.type = type; self.params = params }

    public static let off = Versioning()

    public var json: JSONValue {
        ["type": .string(type), "params": .object(params.mapValues { .string($0) })]
    }
}

/// Sync-conflict copies Syncthing creates next to the original
/// (`name.sync-conflict-YYYYMMDD-HHMMSS-DEVICE.ext`).
public enum ConflictName {
    public static let marker = ".sync-conflict-"

    public static func isConflict(_ fileName: String) -> Bool {
        fileName.contains(marker)
    }

    /// The original file name a conflict copy belongs to.
    public static func original(of fileName: String) -> String? {
        guard let range = fileName.range(of: marker) else { return nil }
        let base = fileName[..<range.lowerBound]
        let rest = fileName[range.upperBound...]
        // rest = "20240101-120000-ABCDEFG[.ext]"
        let ext = rest.split(separator: ".", maxSplits: 1).dropFirst().first.map { "." + $0 } ?? ""
        return base + ext
    }
}
