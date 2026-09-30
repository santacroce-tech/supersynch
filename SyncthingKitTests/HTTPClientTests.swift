import XCTest
@testable import SyncthingKit

/// Intercepts requests made by a `URLSession` configured with it.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int = 200
        var body: Data = Data("{}".utf8)
        var error: URLError?
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Response)?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var req = request
        // URLSession moves bodies into a stream; restore them for assertions.
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            req.httpBody = data
        }
        Self.lock.lock()
        Self.requests.append(req)
        let response = Self.handler?(req) ?? Response()
        Self.lock.unlock()

        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset(_ handler: (@Sendable (URLRequest) -> Response)? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        requests = []
    }

    static var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.last
    }
}

final class HTTPClientTests: XCTestCase {
    private func makeClient(base: String = "https://nas.local:8384", key: String = "secret-key") -> SyncthingHTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return SyncthingHTTPClient(endpoint: ServerEndpoint(baseURL: URL(string: base)!, apiKey: key), configuration: config)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testSendsAPIKeyAndBuildsURL() async throws {
        StubURLProtocol.reset { _ in .init(body: try! Fixture.data("system-status")) }
        let status = try await makeClient().systemStatus()
        XCTAssertEqual(status.uptime, 2635)
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://nas.local:8384/rest/system/status")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-API-Key"), "secret-key")
        XCTAssertEqual(req.httpMethod, "GET")
    }

    func testHealthIsUnauthenticated() async throws {
        StubURLProtocol.reset { _ in .init(body: Data(#"{"status":"OK"}"#.utf8)) }
        let health = try await makeClient().health()
        XCTAssertTrue(health.isOK)
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.path, "/rest/noauth/health")
        XCTAssertNil(req.value(forHTTPHeaderField: "X-API-Key"))
    }

    func testPreservesReverseProxyPathPrefix() async throws {
        StubURLProtocol.reset { _ in .init(body: try! Fixture.data("system-version")) }
        _ = try await makeClient(base: "https://example.com/syncthing/").systemVersion()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, "https://example.com/syncthing/rest/system/version")
    }

    func testQueryParametersAreEncoded() async throws {
        StubURLProtocol.reset { _ in .init(body: try! Fixture.data("db-completion")) }
        _ = try await makeClient().completion(folder: "a+b c", device: "DEV-1")
        let url = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "folder" }?.value, "a+b c")
        XCTAssertTrue(url.absoluteString.contains("a%2Bb"), "plus sign must be escaped for Go's query parser")
        XCTAssertEqual(items.first { $0.name == "device" }?.value, "DEV-1")
    }

    func testFolderPauseUsesConfigPatch() async throws {
        StubURLProtocol.reset { _ in .init(body: Data()) }
        try await makeClient().setFolderPaused("abc/def", paused: true)
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "PATCH")
        XCTAssertEqual(req.url?.absoluteString, "https://nas.local:8384/rest/config/folders/abc%2Fdef")
        let body = try JSONDecoder().decode([String: Bool].self, from: try XCTUnwrap(req.httpBody))
        XCTAssertEqual(body, ["paused": true])
    }

    func testLifecycleEndpoints() async throws {
        StubURLProtocol.reset { _ in .init(body: Data()) }
        let client = makeClient()
        try await client.pause(device: nil)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, "https://nas.local:8384/rest/system/pause")
        try await client.resume(device: "XYZ")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, "https://nas.local:8384/rest/system/resume?device=XYZ")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
        try await client.scan(folder: "f1")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, "https://nas.local:8384/rest/db/scan?folder=f1")
        try await client.dismissPendingFolder("f1", device: "D")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/rest/cluster/pending/folders")
    }

    func testEventsRequest() async throws {
        StubURLProtocol.reset { _ in .init(body: try! Fixture.data("events")) }
        let events = try await makeClient().events(since: 7, limit: nil, timeout: 60)
        XCTAssertEqual(events.count, 12)
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.query, "since=7&timeout=60")
        XCTAssertGreaterThan(req.timeoutInterval, 60, "request must outlive the server-side long-poll")
    }

    func testUnauthorizedMapsToHumanError() async {
        for status in [401, 403] {
            StubURLProtocol.reset { _ in .init(status: status, body: Data("CSRF Error".utf8)) }
            do {
                _ = try await makeClient().systemStatus()
                XCTFail("expected error")
            } catch {
                XCTAssertEqual(error as? SyncthingError, .unauthorized)
                XCTAssertTrue((error as? SyncthingError)?.errorDescription?.contains("API key") == true)
            }
        }
    }

    func testServerErrorCarriesMessage() async {
        StubURLProtocol.reset { _ in .init(status: 500, body: Data("folder is paused\n".utf8)) }
        do {
            try await makeClient().scan(folder: "x")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SyncthingError, .server(status: 500, message: "folder is paused"))
        }
    }

    func testTransportErrorsMapToSpecificCases() async {
        let cases: [(URLError.Code, SyncthingError)] = [
            (.timedOut, .timeout),
            (.notConnectedToInternet, .offline),
            (.cannotConnectToHost, .unreachable(host: "nas.local")),
            (.cannotFindHost, .unreachable(host: "nas.local")),
            (.appTransportSecurityRequiresSecureConnection, .plainHTTPNotAllowed),
            (.secureConnectionFailed, .tlsFailure),
        ]
        for (code, expected) in cases {
            StubURLProtocol.reset { _ in .init(error: URLError(code)) }
            do {
                _ = try await makeClient().systemStatus()
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? SyncthingError, expected, "for \(code)")
            }
        }
    }

    func testDecodingErrorIsReported() async {
        StubURLProtocol.reset { _ in .init(body: Data("<html>not json</html>".utf8)) }
        do {
            _ = try await makeClient().systemStatus()
            XCTFail("expected error")
        } catch {
            guard case .decoding = error as? SyncthingError else { return XCTFail("got \(error)") }
        }
    }

    func testInvalidBaseURL() async {
        let client = makeClient(base: "ftp://nas.local")
        do {
            _ = try await client.systemStatus()
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SyncthingError, .invalidURL)
        }
    }

    func testPendingEndpoints() async throws {
        StubURLProtocol.reset { req in
            .init(body: try! Fixture.data(req.url!.path.hasSuffix("devices") ? "pending-devices" : "pending-folders"))
        }
        let client = makeClient()
        let devices = try await client.pendingDevices()
        let folders = try await client.pendingFolders()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(folders.count, 3)
    }
}

final class TrustTests: XCTestCase {
    func testFingerprintFormatting() {
        let info = CertificateInfo(sha256: "ABCDEF0123", subject: "syncthing", host: "nas")
        XCTAssertEqual(info.formattedFingerprint, "AB:CD:EF:01:23")
    }

    func testFingerprintIsSHA256OfDER() {
        // SHA-256("abc")
        XCTAssertEqual(TrustEvaluator.fingerprint(of: Data("abc".utf8)),
                       "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
    }
}
