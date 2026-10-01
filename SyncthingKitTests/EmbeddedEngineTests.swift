import XCTest
@testable import SyncthingKit

/// Runs the real embedded Syncthing (gomobile bridge) inside the simulator.
@MainActor
final class EmbeddedEngineTests: XCTestCase {
    private var root: URL!
    private var engine: SyncEngine!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "engine-\(UUID().uuidString)")
        let paths = EnginePaths(configDir: root.appending(path: "config"), dataDir: root.appending(path: "data"),
                                folderRoot: root.appending(path: "Documents"))
        let defaults = UserDefaults(suiteName: "engine-tests-\(UUID().uuidString)")!
        // Keep the test node local and off the default port: a real Syncthing
        // may be running on the host the simulator shares its network with.
        let options: JSONValue = [
            "listenAddresses": ["tcp://127.0.0.1:22100"], "globalAnnounceEnabled": false,
            "localAnnounceEnabled": false, "relaysEnabled": false, "natEnabled": false,
        ]
        engine = try SyncEngine(paths: paths, deviceName: "Test iPhone",
                                externalFolders: ExternalFolderAccess(defaults: defaults), startupOptions: options)
        await engine.start()
        XCTAssertEqual(engine.status, .running)
    }

    override func tearDown() async throws {
        await engine?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func testIdentityAndMobileDefaults() async throws {
        XCTAssertNotNil(DeviceIDValidator.normalize(engine.deviceID), "device ID passes Luhn validation")
        let status = try await engine.client.systemStatus()
        XCTAssertEqual(status.myID, engine.deviceID)
        let version = try await engine.client.systemVersion()
        XCTAssertEqual(version.version, "v2.1.5")
        XCTAssertEqual(version.os, "ios")
        let devices = try await engine.client.devices()
        XCTAssertEqual(devices.first { $0.deviceID == engine.deviceID }?.name, "Test iPhone")
        let options = try await engine.client.options()
        XCTAssertEqual(options["urAccepted"], -1, "usage reporting off")
        XCTAssertEqual(options["crashReportingEnabled"], false)
        let defaults = try await engine.client.folderDefaults()
        XCTAssertEqual(defaults["path"]?.stringValue, engine.paths.folderRoot.path, "new folders default into Documents")
    }

    func testSessionFollowsEngineAndManagesFolders() async throws {
        let session = SyncSession(client: engine.client)
        session.start()
        defer { session.stop() }
        try await waitUntil(timeout: 10) { session.phase == .live }

        let path = engine.paths.folderRoot.appending(path: "Notes").path
        do { let ok = await session.saveFolder(FolderDraft(id: "notes", label: "Notes", path: path)); XCTAssertTrue(ok) }
        XCTAssertEqual(session.state.folder("notes")?.label, "Notes")
        try await waitUntil(timeout: 15) { session.state.folderState("notes") == .upToDate }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/.stfolder"), "Syncthing created the folder marker")

        // Add a file, rescan, and see the index grow through events.
        try Data("hello".utf8).write(to: URL(filePath: path).appending(path: "a.txt"))
        await session.rescan(folder: "notes")
        try await waitUntil(timeout: 15) { (session.state.folderStatuses["notes"]?.localFiles ?? 0) >= 1 }

        await session.setFolderPaused("notes", paused: true)
        try await waitUntil(timeout: 5) { session.state.folderState("notes") == .paused }

        do { let ok = await session.removeFolder("notes"); XCTAssertTrue(ok) }
        XCTAssertNil(session.state.folder("notes"))
        XCTAssertNil(session.actionError)
    }

    func testInvalidDeviceIsRejected() async throws {
        do {
            try await engine.client.setDevice(["deviceID": "not-a-device"])
            XCTFail("expected an error")
        } catch {
            guard case .engine = error as? SyncthingError else { return XCTFail("got \(error)") }
        }
    }

    func testStopAndRestart() async throws {
        await engine.stop()
        XCTAssertEqual(engine.status, .stopped)
        do {
            _ = try await engine.client.systemStatus()
            XCTFail("expected notRunning")
        } catch {
            XCTAssertEqual(error as? SyncthingError, .notRunning)
        }
        await engine.start()
        XCTAssertEqual(engine.status, .running)
        let status = try await engine.client.systemStatus()
        XCTAssertEqual(status.myID, engine.deviceID, "same identity after restart")
    }

    func testEventLongPollCancelsPromptly() async throws {
        let client = engine.client
        let latest = try await client.events(since: 0, limit: 1, timeout: 1).last?.id ?? 0
        let task = Task { try await client.events(since: latest + 10_000, limit: nil, timeout: 20) }
        try await Task.sleep(for: .milliseconds(200))
        let started = Date()
        task.cancel()
        _ = try? await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "cancellation must not wait for the long-poll")
    }

    /// Full two-device sync with a separate Syncthing ("the Mac"), started by
    /// scripts/e2e-peer.sh. Opt-in:
    ///   TEST_RUNNER_PEER_URL=http://127.0.0.1:8386 TEST_RUNNER_PEER_API_KEY=e2e-key
    func testTwoWaySyncWithPeer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let peerURL = env["PEER_URL"], let peerKey = env["PEER_API_KEY"] else {
            throw XCTSkip("Set PEER_URL / PEER_API_KEY (see scripts/e2e-peer.sh)")
        }
        let peer = Peer(base: peerURL, key: peerKey)
        let macID = try await peer.myID()
        let folderID = "ios-e2e-\(Int(Date().timeIntervalSince1970))"
        let macDir = FileManager.default.temporaryDirectory.appending(path: "mac-\(folderID)")
        let phoneDir = engine.paths.folderRoot.appending(path: "Shared")

        let session = SyncSession(client: engine.client)
        session.start()
        defer { session.stop() }

        // Pair: the phone adds the Mac (with a direct address), the Mac adds the phone.
        do { let ok = await session.saveDevice(DeviceDraft(deviceID: macID, name: "Mac", addresses: ["tcp://127.0.0.1:22001"])); XCTAssertTrue(ok) }
        try await peer.send("POST", "/rest/config/devices", ["deviceID": .string(engine.deviceID), "name": "iPhone",
                                                            "addresses": ["tcp://127.0.0.1:22100"]])
        try await peer.send("POST", "/rest/config/folders", ["id": .string(folderID), "label": "Shared", "path": .string(macDir.path),
                                                            "rescanIntervalS": 5, "fsWatcherEnabled": false,
                                                            "devices": [["deviceID": .string(engine.deviceID)]]])
        defer {
            Task {
                try? await peer.send("DELETE", "/rest/config/folders/\(folderID)", nil)
                try? await peer.send("DELETE", "/rest/config/devices/\(engine.deviceID)", nil)
            }
        }

        // The Mac's offer shows up as a pending folder on the phone; accept it.
        try await waitUntil(timeout: 30) { session.state.connections[macID]?.connected == true }
        try await waitUntil(timeout: 30) { session.state.pendingFolders.contains { $0.folderID == folderID } }
        let pending = try XCTUnwrap(session.state.pendingFolders.first { $0.folderID == folderID })
        do { let ok = await session.saveFolder(FolderDraft(accepting: pending, path: phoneDir.path)); XCTAssertTrue(ok) }

        // Mac → phone.
        try FileManager.default.createDirectory(at: macDir, withIntermediateDirectories: true)
        try Data("from mac".utf8).write(to: macDir.appending(path: "mac.txt"))
        try await peer.send("POST", "/rest/db/scan?folder=\(folderID)", nil)
        try await waitUntil(timeout: 60) {
            (try? String(contentsOf: phoneDir.appending(path: "mac.txt"), encoding: .utf8)) == "from mac"
        }

        // Phone → Mac.
        try Data("from phone".utf8).write(to: phoneDir.appending(path: "phone.txt"))
        await session.rescan(folder: folderID)
        try await waitUntil(timeout: 60) {
            (try? String(contentsOf: macDir.appending(path: "phone.txt"), encoding: .utf8)) == "from phone"
        }
        try await waitUntil(timeout: 30) { session.state.isSyncIdle }

        // Per-device byte counters reach the UI state.
        try await waitUntil(timeout: 15) { (session.state.connections[macID]?.inBytesTotal ?? 0) > 0 }

        // Ignore patterns round-trip through the engine.
        do { let ok = await session.saveIgnores(folderID, lines: ["*.tmp"]); XCTAssertTrue(ok) }
        let ignores = try await session.loadIgnores(folderID)
        XCTAssertEqual(ignores.lines, ["*.tmp"])
    }
}

/// Minimal REST client for the peer in the end-to-end test.
private struct Peer {
    let base: String
    let key: String

    func myID() async throws -> String {
        let data = try await send("GET", "/rest/system/status", nil)
        return try JSONDecoder().decode(SystemStatus.self, from: data).myID
    }

    @discardableResult
    func send(_ method: String, _ path: String, _ body: JSONValue?) async throws -> Data {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 300 else { throw SyncthingError.other("peer \(method) \(path): \(status)") }
        return data
    }
}
