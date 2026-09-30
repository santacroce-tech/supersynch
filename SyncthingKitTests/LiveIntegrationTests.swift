import XCTest
@testable import SyncthingKit

/// Runs against a real Syncthing instance. Skipped unless configured:
///
///     TEST_RUNNER_SYNCTHING_URL=https://127.0.0.1:8385 \
///     TEST_RUNNER_SYNCTHING_API_KEY=... \
///     xcodebuild test -scheme SuperSynch -destination '…'
///
/// See README → "Integration tests".
final class LiveIntegrationTests: XCTestCase {
    private var baseURL: URL!
    private var apiKey: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["SYNCTHING_URL"].flatMap(URL.init(string:)), let key = env["SYNCTHING_API_KEY"] else {
            throw XCTSkip("Set SYNCTHING_URL and SYNCTHING_API_KEY to run live integration tests.")
        }
        baseURL = url
        apiKey = key
    }

    /// Returns a client that trusts the server's certificate (pinning it if
    /// it's self-signed), exercising the trust-on-first-use path.
    private func trustedClient() async throws -> SyncthingHTTPClient {
        try await Self.trustedClient(baseURL: baseURL, apiKey: apiKey)
    }

    private static func trustedClient(baseURL: URL, apiKey: String) async throws -> SyncthingHTTPClient {
        let unpinned = SyncthingHTTPClient(endpoint: ServerEndpoint(baseURL: baseURL, apiKey: apiKey))
        do {
            _ = try await unpinned.health()
            return unpinned
        } catch SyncthingError.untrustedCertificate(let info) {
            XCTAssertEqual(info.sha256.count, 64)
            return SyncthingHTTPClient(endpoint: ServerEndpoint(baseURL: baseURL, apiKey: apiKey, pinnedFingerprint: info.sha256))
        }
    }

    func testSelfSignedCertificateRequiresPinAndWrongPinIsRejected() async throws {
        try XCTSkipUnless(baseURL.scheme == "https", "HTTPS only")
        let wrongPin = SyncthingHTTPClient(endpoint: ServerEndpoint(baseURL: baseURL, apiKey: apiKey,
                                                                    pinnedFingerprint: String(repeating: "0", count: 64)))
        do {
            _ = try await wrongPin.health()
            // A CA-signed certificate is accepted regardless of the pin.
        } catch SyncthingError.certificateChanged(let info) {
            XCTAssertEqual(info.host, baseURL.host)
        }
    }

    func testAllReadEndpointsDecode() async throws {
        let client = try await trustedClient()
        let health = try await client.health()
        XCTAssertTrue(health.isOK)
        try await client.ping()
        let status = try await client.systemStatus()
        XCTAssertEqual(status.myID.count, 63)
        XCTAssertGreaterThan(status.uptime, -1)
        let version = try await client.systemVersion()
        XCTAssertTrue(version.version.hasPrefix("v"))
        let connections = try await client.connections()
        XCTAssertNotNil(connections.total.at)
        let devices = try await client.devices()
        XCTAssertTrue(devices.contains { $0.deviceID == status.myID })
        let folders = try await client.folders()
        for folder in folders {
            let folderStatus = try await client.folderStatus(folder.id)
            XCTAssertFalse(folderStatus.state.isEmpty)
            _ = try await client.completion(folder: folder.id, device: nil)
            _ = try await client.need(folder: folder.id, page: 1, perPage: 10)
            _ = try await client.folderErrors(folder.id)
        }
        _ = try await client.completion(folder: nil, device: nil)
        _ = try await client.deviceStats()
        _ = try await client.folderStats()
        _ = try await client.systemErrors()
        _ = try await client.pendingDevices()
        _ = try await client.pendingFolders()
        let folderDefaults = try await client.folderDefaults()
        XCTAssertNotNil(folderDefaults["path"])
        _ = try await client.deviceDefaults()
        let latest = try await client.events(since: 0, limit: 1, timeout: 1)
        XCTAssertEqual(latest.count, 1)
        XCTAssertGreaterThan(latest[0].id, 0)
    }

    func testWrongAPIKeyIsUnauthorized() async throws {
        let good = try await trustedClient()
        let bad = SyncthingHTTPClient(endpoint: ServerEndpoint(baseURL: baseURL, apiKey: "definitely-wrong",
                                                               pinnedFingerprint: good.endpoint.pinnedFingerprint))
        do {
            _ = try await bad.systemStatus()
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? SyncthingError, .unauthorized)
        }
    }

    func testFolderLifecycleThroughEvents() async throws {
        let client = try await trustedClient()
        let folderID = "supersynch-it-\(UInt32.random(in: 0...UInt32.max))"
        let dir = NSTemporaryDirectory() + folderID
        var folder = try await client.folderDefaults()
        folder["id"] = .string(folderID)
        folder["label"] = "Integration"
        folder["path"] = .string(dir)
        let cursor = try await client.events(since: 0, limit: 1, timeout: 1).last?.id ?? 0
        try await client.addFolder(folder)

        // The new folder appears in config and the event stream.
        let folders = try await client.folders()
        XCTAssertTrue(folders.contains { $0.id == folderID })

        var state = ServerState()
        state.applyFolders(folders)
        state.lastEventID = cursor
        var sawFolderEvent = false
        for _ in 0..<10 where !sawFolderEvent {
            let events = try await client.events(since: state.lastEventID, limit: nil, timeout: 2)
            _ = EventReducer.apply(events, to: &state)
            sawFolderEvent = state.folderStatuses[folderID] != nil
        }
        XCTAssertTrue(sawFolderEvent, "expected StateChanged/FolderSummary for the new folder")

        try await client.setFolderPaused(folderID, paused: true)
        let paused = try await client.folders().first { $0.id == folderID }
        XCTAssertEqual(paused?.paused, true)
        try await client.setFolderPaused(folderID, paused: false)
        try await client.scan(folder: folderID)

        // Clean up via DELETE /rest/config/folders/{id}.
        var request = try client.makeRequest("DELETE", "config/folders/\(folderID)")
        request.timeoutInterval = 10
        _ = try await client.send(request)
    }

    @MainActor
    func testSessionGoesLive() async throws {
        let client = try await Self.trustedClient(baseURL: baseURL, apiKey: apiKey)
        let server = ServerConfig(name: "it", baseURL: baseURL, pinnedFingerprint: client.endpoint.pinnedFingerprint)
        let session = ServerSession(server: server, client: client)
        session.start()
        defer { session.stop() }
        let deadline = Date().addingTimeInterval(10)
        while session.phase != .live || session.state.status == nil {
            if Date() > deadline { return XCTFail("session did not go live: \(session.phase)") }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(session.state.version)
        XCTAssertGreaterThan(session.state.lastEventID, 0)
    }
}
