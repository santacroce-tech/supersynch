import Foundation

public typealias DeviceID = String
public typealias FolderID = String

/// `GET /rest/noauth/health`
public struct HealthResponse: Decodable, Sendable, Equatable {
    public var status: String

    public init(status: String) { self.status = status }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        status = c.lenient(AnyKey("status"), "")
    }

    public var isOK: Bool { status.uppercased() == "OK" }
}

/// `GET /rest/system/status`
public struct SystemStatus: Decodable, Sendable, Equatable {
    public var myID: DeviceID
    public var uptime: Int
    public var startTime: Date?
    public var alloc: Int64
    public var sys: Int64
    public var goroutines: Int
    public var discoveryEnabled: Bool
    public var pathSeparator: String
    /// Keys are discovery method names, values the error (nil = healthy).
    public var discoveryStatus: [String: String?]
    /// Keys are listener addresses, values the error (nil = healthy).
    public var connectionServiceStatus: [String: String?]

    public init(
        myID: DeviceID, uptime: Int = 0, startTime: Date? = nil, alloc: Int64 = 0, sys: Int64 = 0,
        goroutines: Int = 0, discoveryEnabled: Bool = false, pathSeparator: String = "/",
        discoveryStatus: [String: String?] = [:], connectionServiceStatus: [String: String?] = [:]
    ) {
        self.myID = myID; self.uptime = uptime; self.startTime = startTime; self.alloc = alloc
        self.sys = sys; self.goroutines = goroutines; self.discoveryEnabled = discoveryEnabled
        self.pathSeparator = pathSeparator
        self.discoveryStatus = discoveryStatus; self.connectionServiceStatus = connectionServiceStatus
    }

    private struct ErrorHolder: Decodable {
        var error: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            error = c.lenient(AnyKey("error"))
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        myID = c.lenient(AnyKey("myID"), "")
        uptime = c.lenientInt(AnyKey("uptime"))
        startTime = c.lenientDate(AnyKey("startTime"))
        alloc = c.lenientInt64(AnyKey("alloc"))
        sys = c.lenientInt64(AnyKey("sys"))
        goroutines = c.lenientInt(AnyKey("goroutines"))
        discoveryEnabled = c.lenientBool(AnyKey("discoveryEnabled"))
        pathSeparator = c.lenient(AnyKey("pathSeparator"), "/")
        let disc: [String: ErrorHolder] = c.lenient(AnyKey("discoveryStatus"), [:])
        discoveryStatus = disc.mapValues { $0.error }
        let conn: [String: ErrorHolder] = c.lenient(AnyKey("connectionServiceStatus"), [:])
        connectionServiceStatus = conn.mapValues { $0.error }
    }
}

/// `GET /rest/system/version`
public struct SystemVersion: Decodable, Sendable, Equatable {
    public var version: String
    public var longVersion: String
    public var os: String
    public var arch: String

    public init(version: String, longVersion: String = "", os: String = "", arch: String = "") {
        self.version = version; self.longVersion = longVersion; self.os = os; self.arch = arch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        version = c.lenient(AnyKey("version"), "")
        longVersion = c.lenient(AnyKey("longVersion"), "")
        os = c.lenient(AnyKey("os"), "")
        arch = c.lenient(AnyKey("arch"), "")
    }
}

/// One entry of `GET /rest/system/error`.
public struct SystemError: Decodable, Sendable, Equatable, Hashable {
    public var when: Date?
    public var message: String

    public init(when: Date?, message: String) { self.when = when; self.message = message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        when = c.lenientDate(AnyKey("when"))
        message = c.lenient(AnyKey("message"), "")
    }
}

/// `GET /rest/system/error`
struct SystemErrorsResponse: Decodable {
    var errors: [SystemError]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        // `errors` is null when there are none.
        errors = c.lenient(AnyKey("errors"), [])
    }
}

/// One entry of `GET /rest/system/connections` → `connections`.
public struct ConnectionInfo: Decodable, Sendable, Equatable {
    public var connected: Bool
    public var paused: Bool
    public var address: String
    public var clientVersion: String
    public var type: String
    public var isLocal: Bool
    public var inBytesTotal: Int64
    public var outBytesTotal: Int64
    public var at: Date?
    public var startedAt: Date?

    public init(
        connected: Bool = false, paused: Bool = false, address: String = "", clientVersion: String = "",
        type: String = "", isLocal: Bool = false, inBytesTotal: Int64 = 0, outBytesTotal: Int64 = 0,
        at: Date? = nil, startedAt: Date? = nil
    ) {
        self.connected = connected; self.paused = paused; self.address = address
        self.clientVersion = clientVersion; self.type = type; self.isLocal = isLocal
        self.inBytesTotal = inBytesTotal; self.outBytesTotal = outBytesTotal
        self.at = at; self.startedAt = startedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        connected = c.lenientBool(AnyKey("connected"))
        paused = c.lenientBool(AnyKey("paused"))
        address = c.lenient(AnyKey("address"), "")
        clientVersion = c.lenient(AnyKey("clientVersion"), "")
        type = c.lenient(AnyKey("type"), "")
        isLocal = c.lenientBool(AnyKey("isLocal"))
        inBytesTotal = c.lenientInt64(AnyKey("inBytesTotal"))
        outBytesTotal = c.lenientInt64(AnyKey("outBytesTotal"))
        at = c.lenientDate(AnyKey("at"))
        startedAt = c.lenientDate(AnyKey("startedAt"))
    }
}

public struct TransferTotals: Decodable, Sendable, Equatable {
    public var inBytesTotal: Int64
    public var outBytesTotal: Int64
    public var at: Date?

    public init(inBytesTotal: Int64 = 0, outBytesTotal: Int64 = 0, at: Date? = nil) {
        self.inBytesTotal = inBytesTotal; self.outBytesTotal = outBytesTotal; self.at = at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        inBytesTotal = c.lenientInt64(AnyKey("inBytesTotal"))
        outBytesTotal = c.lenientInt64(AnyKey("outBytesTotal"))
        at = c.lenientDate(AnyKey("at"))
    }
}

/// `GET /rest/system/connections`
public struct ConnectionsResponse: Decodable, Sendable, Equatable {
    public var connections: [DeviceID: ConnectionInfo]
    public var total: TransferTotals

    public init(connections: [DeviceID: ConnectionInfo] = [:], total: TransferTotals = .init()) {
        self.connections = connections; self.total = total
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        connections = c.lenient(AnyKey("connections"), [:])
        total = c.lenient(AnyKey("total"), TransferTotals())
    }
}

/// `GET /rest/stats/device` values.
public struct DeviceStatistics: Decodable, Sendable, Equatable {
    public var lastSeen: Date?
    public var lastConnectionDurationS: Double

    public init(lastSeen: Date? = nil, lastConnectionDurationS: Double = 0) {
        self.lastSeen = lastSeen; self.lastConnectionDurationS = lastConnectionDurationS
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        lastSeen = c.lenientDate(AnyKey("lastSeen"))
        lastConnectionDurationS = c.lenientDouble(AnyKey("lastConnectionDurationS"))
    }
}

/// `GET /rest/stats/folder` values.
public struct FolderStatistics: Decodable, Sendable, Equatable {
    public var lastScan: Date?
    public var lastFileName: String?
    public var lastFileAt: Date?

    public init(lastScan: Date? = nil, lastFileName: String? = nil, lastFileAt: Date? = nil) {
        self.lastScan = lastScan; self.lastFileName = lastFileName; self.lastFileAt = lastFileAt
    }

    private struct LastFile: Decodable {
        var filename: String?
        var at: Date?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            filename = c.lenient(AnyKey("filename"))
            at = c.lenientDate(AnyKey("at"))
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        lastScan = c.lenientDate(AnyKey("lastScan"))
        let lf: LastFile? = c.lenient(AnyKey("lastFile"))
        lastFileName = (lf?.filename).flatMap { $0.isEmpty ? nil : $0 }
        lastFileAt = lf?.at
    }
}
