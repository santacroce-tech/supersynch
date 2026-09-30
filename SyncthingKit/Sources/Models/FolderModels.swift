import Foundation

/// `GET /rest/db/status`, also the `summary` payload of `FolderSummary` events.
public struct FolderStatus: Decodable, Sendable, Equatable {
    public var state: String
    public var stateChanged: Date?
    public var error: String

    public var globalBytes: Int64
    public var globalFiles: Int
    public var globalDirectories: Int
    public var globalDeleted: Int
    public var globalTotalItems: Int

    public var localBytes: Int64
    public var localFiles: Int
    public var localDirectories: Int
    public var localDeleted: Int
    public var localTotalItems: Int

    public var inSyncBytes: Int64
    public var inSyncFiles: Int

    public var needBytes: Int64
    public var needFiles: Int
    public var needDirectories: Int
    public var needDeletes: Int
    public var needTotalItems: Int

    public var receiveOnlyTotalItems: Int
    public var pullErrors: Int
    public var sequence: Int64

    public init(
        state: String = "unknown", stateChanged: Date? = nil, error: String = "",
        globalBytes: Int64 = 0, globalFiles: Int = 0, globalDirectories: Int = 0, globalDeleted: Int = 0,
        globalTotalItems: Int = 0, localBytes: Int64 = 0, localFiles: Int = 0, localDirectories: Int = 0,
        localDeleted: Int = 0, localTotalItems: Int = 0, inSyncBytes: Int64 = 0, inSyncFiles: Int = 0,
        needBytes: Int64 = 0, needFiles: Int = 0, needDirectories: Int = 0, needDeletes: Int = 0,
        needTotalItems: Int = 0, receiveOnlyTotalItems: Int = 0, pullErrors: Int = 0, sequence: Int64 = 0
    ) {
        self.state = state; self.stateChanged = stateChanged; self.error = error
        self.globalBytes = globalBytes; self.globalFiles = globalFiles
        self.globalDirectories = globalDirectories; self.globalDeleted = globalDeleted
        self.globalTotalItems = globalTotalItems; self.localBytes = localBytes; self.localFiles = localFiles
        self.localDirectories = localDirectories; self.localDeleted = localDeleted
        self.localTotalItems = localTotalItems; self.inSyncBytes = inSyncBytes; self.inSyncFiles = inSyncFiles
        self.needBytes = needBytes; self.needFiles = needFiles; self.needDirectories = needDirectories
        self.needDeletes = needDeletes; self.needTotalItems = needTotalItems
        self.receiveOnlyTotalItems = receiveOnlyTotalItems; self.pullErrors = pullErrors
        self.sequence = sequence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        state = c.lenient(AnyKey("state"), "unknown")
        stateChanged = c.lenientDate(AnyKey("stateChanged"))
        error = c.lenient(AnyKey("error"), "")
        globalBytes = c.lenientInt64(AnyKey("globalBytes"))
        globalFiles = c.lenientInt(AnyKey("globalFiles"))
        globalDirectories = c.lenientInt(AnyKey("globalDirectories"))
        globalDeleted = c.lenientInt(AnyKey("globalDeleted"))
        globalTotalItems = c.lenientInt(AnyKey("globalTotalItems"))
        localBytes = c.lenientInt64(AnyKey("localBytes"))
        localFiles = c.lenientInt(AnyKey("localFiles"))
        localDirectories = c.lenientInt(AnyKey("localDirectories"))
        localDeleted = c.lenientInt(AnyKey("localDeleted"))
        localTotalItems = c.lenientInt(AnyKey("localTotalItems"))
        inSyncBytes = c.lenientInt64(AnyKey("inSyncBytes"))
        inSyncFiles = c.lenientInt(AnyKey("inSyncFiles"))
        needBytes = c.lenientInt64(AnyKey("needBytes"))
        needFiles = c.lenientInt(AnyKey("needFiles"))
        needDirectories = c.lenientInt(AnyKey("needDirectories"))
        needDeletes = c.lenientInt(AnyKey("needDeletes"))
        needTotalItems = c.lenientInt(AnyKey("needTotalItems"))
        receiveOnlyTotalItems = c.lenientInt(AnyKey("receiveOnlyTotalItems"))
        pullErrors = c.lenientInt(AnyKey("pullErrors"))
        sequence = c.lenientInt64(AnyKey("sequence"))
    }

    /// Local completion in percent (0...100), from global vs. needed bytes.
    public var completion: Double {
        guard globalBytes > 0 else { return needTotalItems > 0 ? 0 : 100 }
        let done = Double(max(0, globalBytes - needBytes)) / Double(globalBytes) * 100
        return min(100, max(0, done))
    }
}

/// `GET /rest/db/completion`, also the payload of `FolderCompletion` events.
public struct Completion: Decodable, Sendable, Equatable {
    public var completion: Double
    public var globalBytes: Int64
    public var needBytes: Int64
    public var globalItems: Int
    public var needItems: Int
    public var needDeletes: Int
    /// `valid`, `paused`, `notSharing` or `unknown` (Syncthing ≥ 1.20).
    public var remoteState: String

    public init(
        completion: Double = 100, globalBytes: Int64 = 0, needBytes: Int64 = 0, globalItems: Int = 0,
        needItems: Int = 0, needDeletes: Int = 0, remoteState: String = "unknown"
    ) {
        self.completion = completion; self.globalBytes = globalBytes; self.needBytes = needBytes
        self.globalItems = globalItems; self.needItems = needItems; self.needDeletes = needDeletes
        self.remoteState = remoteState
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        completion = c.lenientDouble(AnyKey("completion"))
        globalBytes = c.lenientInt64(AnyKey("globalBytes"))
        needBytes = c.lenientInt64(AnyKey("needBytes"))
        globalItems = c.lenientInt(AnyKey("globalItems"))
        needItems = c.lenientInt(AnyKey("needItems"))
        needDeletes = c.lenientInt(AnyKey("needDeletes"))
        remoteState = c.lenient(AnyKey("remoteState"), "unknown")
    }
}

/// A file entry from `GET /rest/db/need`.
public struct NeededFile: Decodable, Sendable, Equatable, Hashable {
    public var name: String
    public var size: Int64
    public var modified: Date?
    public var deleted: Bool

    public init(name: String, size: Int64 = 0, modified: Date? = nil, deleted: Bool = false) {
        self.name = name; self.size = size; self.modified = modified; self.deleted = deleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = c.lenient(AnyKey("name"), "")
        size = c.lenientInt64(AnyKey("size"))
        modified = c.lenientDate(AnyKey("modified"))
        deleted = c.lenientBool(AnyKey("deleted"))
    }
}

/// `GET /rest/db/need`
public struct NeedResponse: Decodable, Sendable, Equatable {
    public var progress: [NeededFile]
    public var queued: [NeededFile]
    public var rest: [NeededFile]
    public var page: Int
    public var perpage: Int

    public init(progress: [NeededFile] = [], queued: [NeededFile] = [], rest: [NeededFile] = [],
                page: Int = 1, perpage: Int = 100) {
        self.progress = progress; self.queued = queued; self.rest = rest
        self.page = page; self.perpage = perpage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        progress = c.lenient(AnyKey("progress"), [])
        queued = c.lenient(AnyKey("queued"), [])
        rest = c.lenient(AnyKey("rest"), [])
        page = c.lenientInt(AnyKey("page"))
        perpage = c.lenientInt(AnyKey("perpage"))
    }

    public var all: [NeededFile] { progress + queued + rest }
}

/// A per-file error from `GET /rest/folder/errors` or `FolderErrors` events.
public struct FileError: Decodable, Sendable, Equatable, Hashable {
    public var path: String
    public var error: String

    public init(path: String, error: String) { self.path = path; self.error = error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        path = c.lenient(AnyKey("path"), "")
        error = c.lenient(AnyKey("error"), "")
    }
}

/// `GET /rest/folder/errors`
struct FolderErrorsResponse: Decodable {
    var folder: String
    var errors: [FileError]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        folder = c.lenient(AnyKey("folder"), "")
        errors = c.lenient(AnyKey("errors"), [])
    }
}
