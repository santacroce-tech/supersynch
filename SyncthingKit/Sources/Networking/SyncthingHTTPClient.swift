import Foundation

/// Where and how to reach one Syncthing instance.
public struct ServerEndpoint: Sendable, Equatable {
    public var baseURL: URL
    public var apiKey: String
    /// SHA-256 of a user-trusted, self-signed certificate (uppercase hex).
    public var pinnedFingerprint: String?

    public init(baseURL: URL, apiKey: String, pinnedFingerprint: String? = nil) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.pinnedFingerprint = pinnedFingerprint
    }
}

/// URLSession-backed `SyncthingAPIClient`. One instance per server; it owns a
/// dedicated session so certificate pins never leak between servers.
public final class SyncthingHTTPClient: SyncthingAPIClient {
    public let endpoint: ServerEndpoint
    private let session: URLSession
    private let trust: TrustEvaluator
    private let requestTimeout: TimeInterval

    public init(endpoint: ServerEndpoint, configuration: URLSessionConfiguration = .ephemeral,
                requestTimeout: TimeInterval = 15) {
        self.endpoint = endpoint
        self.requestTimeout = requestTimeout
        let trust = TrustEvaluator(pinnedFingerprint: endpoint.pinnedFingerprint)
        self.trust = trust
        let config = configuration
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Health & identity

    public func health() async throws -> HealthResponse {
        try await get("noauth/health", authenticated: false)
    }

    public func ping() async throws {
        _ = try await send(makeRequest("GET", "system/ping"))
    }

    public func systemStatus() async throws -> SystemStatus { try await get("system/status") }
    public func systemVersion() async throws -> SystemVersion { try await get("system/version") }

    // MARK: - Connections & stats

    public func connections() async throws -> ConnectionsResponse { try await get("system/connections") }

    public func deviceStats() async throws -> [DeviceID: DeviceStatistics] {
        let r: [DeviceID: DeviceStatistics]? = try await get("stats/device")
        return r ?? [:]
    }

    public func folderStats() async throws -> [FolderID: FolderStatistics] {
        let r: [FolderID: FolderStatistics]? = try await get("stats/folder")
        return r ?? [:]
    }

    // MARK: - Config

    public func folders() async throws -> [FolderConfig] {
        let r: [FolderConfig]? = try await get("config/folders")
        return r ?? []
    }

    public func devices() async throws -> [DeviceConfig] {
        let r: [DeviceConfig]? = try await get("config/devices")
        return r ?? []
    }

    public func setFolderPaused(_ folderID: FolderID, paused: Bool) async throws {
        let body = try JSONEncoder().encode(["paused": paused])
        _ = try await send(makeRequest("PATCH", "config/folders/\(Self.pathEscape(folderID))", body: body))
    }

    public func folderDefaults() async throws -> JSONValue { try await get("config/defaults/folder") }
    public func deviceDefaults() async throws -> JSONValue { try await get("config/defaults/device") }

    public func addFolder(_ folder: JSONValue) async throws {
        _ = try await send(makeRequest("POST", "config/folders", body: JSONEncoder().encode(folder)))
    }

    public func addDevice(_ device: JSONValue) async throws {
        _ = try await send(makeRequest("POST", "config/devices", body: JSONEncoder().encode(device)))
    }

    // MARK: - Folder state

    public func folderStatus(_ folderID: FolderID) async throws -> FolderStatus {
        try await get("db/status", query: ["folder": folderID])
    }

    public func completion(folder: FolderID?, device: DeviceID?) async throws -> Completion {
        var q: [String: String] = [:]
        if let folder { q["folder"] = folder }
        if let device { q["device"] = device }
        return try await get("db/completion", query: q)
    }

    public func need(folder: FolderID, page: Int, perPage: Int) async throws -> NeedResponse {
        try await get("db/need", query: ["folder": folder, "page": String(page), "perpage": String(perPage)])
    }

    public func folderErrors(_ folderID: FolderID) async throws -> [FileError] {
        let r: FolderErrorsResponse = try await get("folder/errors", query: ["folder": folderID])
        return r.errors
    }

    public func scan(folder: FolderID) async throws {
        _ = try await send(makeRequest("POST", "db/scan", query: ["folder": folder]))
    }

    // MARK: - Errors

    public func systemErrors() async throws -> [SystemError] {
        let r: SystemErrorsResponse = try await get("system/error")
        return r.errors
    }

    public func clearSystemErrors() async throws {
        _ = try await send(makeRequest("POST", "system/error/clear"))
    }

    // MARK: - Pending

    public func pendingDevices() async throws -> [PendingDevice] {
        let data = try await send(makeRequest("GET", "cluster/pending/devices"))
        do { return try PendingDecoding.devices(from: data) } catch { throw SyncthingError.decoding(String(describing: error)) }
    }

    public func pendingFolders() async throws -> [PendingFolder] {
        let data = try await send(makeRequest("GET", "cluster/pending/folders"))
        do { return try PendingDecoding.folders(from: data) } catch { throw SyncthingError.decoding(String(describing: error)) }
    }

    public func dismissPendingDevice(_ deviceID: DeviceID) async throws {
        _ = try await send(makeRequest("DELETE", "cluster/pending/devices", query: ["device": deviceID]))
    }

    public func dismissPendingFolder(_ folderID: FolderID, device: DeviceID?) async throws {
        var q = ["folder": folderID]
        if let device { q["device"] = device }
        _ = try await send(makeRequest("DELETE", "cluster/pending/folders", query: q))
    }

    // MARK: - Lifecycle

    public func pause(device: DeviceID?) async throws {
        _ = try await send(makeRequest("POST", "system/pause", query: device.map { ["device": $0] } ?? [:]))
    }

    public func resume(device: DeviceID?) async throws {
        _ = try await send(makeRequest("POST", "system/resume", query: device.map { ["device": $0] } ?? [:]))
    }

    public func restart() async throws { _ = try await send(makeRequest("POST", "system/restart")) }
    public func shutdown() async throws { _ = try await send(makeRequest("POST", "system/shutdown")) }

    // MARK: - Events

    public func events(since: Int, limit: Int?, timeout: Int) async throws -> [SyncthingEvent] {
        var q = ["since": String(since), "timeout": String(timeout)]
        if let limit { q["limit"] = String(limit) }
        var request = try makeRequest("GET", "events", query: q)
        // The server holds the request for up to `timeout` seconds.
        request.timeoutInterval = TimeInterval(timeout) + requestTimeout
        let data = try await send(request)
        do {
            return try JSONDecoder().decode([SyncthingEvent]?.self, from: data) ?? []
        } catch {
            throw SyncthingError.decoding(String(describing: error))
        }
    }

    // MARK: - Plumbing

    static func pathEscape(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    /// Builds `<base>/rest/<path>`, preserving any path prefix on the base URL
    /// (e.g. Syncthing behind a reverse proxy at `/syncthing/`).
    func makeRequest(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil,
                     authenticated: Bool = true) throws -> URLRequest {
        guard var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            throw SyncthingError.invalidURL
        }
        let prefix = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = prefix + "/rest/" + path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // `+` is otherwise interpreted as a space by Go's query parser.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw SyncthingError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            request.setValue(endpoint.apiKey, forHTTPHeaderField: "X-API-Key")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], authenticated: Bool = true) async throws -> T {
        let data = try await send(makeRequest("GET", path, query: query, authenticated: authenticated))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SyncthingError.decoding(Self.describe(error))
        }
    }

    func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapTransportError(error)
        }
        _ = trust.takeRejection()
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw SyncthingError.unauthorized
        case 404:
            throw SyncthingError.notFound
        default:
            let text = String(data: data.prefix(300), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SyncthingError.server(status: http.statusCode, message: text)
        }
    }

    private func mapTransportError(_ error: Error) -> SyncthingError {
        if let rejection = trust.takeRejection() {
            return rejection.pinMismatch ? .certificateChanged(rejection.info) : .untrustedCertificate(rejection.info)
        }
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .other(error.localizedDescription) }
        let host = endpoint.baseURL.host ?? endpoint.baseURL.absoluteString
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timeout
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
             .resourceUnavailable:
            return .unreachable(host: host)
        case .appTransportSecurityRequiresSecureConnection:
            return .plainHTTPNotAllowed
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return .tlsFailure
        case .badURL, .unsupportedURL:
            return .invalidURL
        default:
            return .other(urlError.localizedDescription)
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx),
             DecodingError.keyNotFound(_, let ctx), DecodingError.dataCorrupted(let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? ctx.debugDescription : "\(path): \(ctx.debugDescription)"
        default:
            return String(describing: error)
        }
    }
}
