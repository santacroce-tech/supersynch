import XCTest
@testable import SyncthingKit

@MainActor
final class ServerSessionTests: XCTestCase {
    private let server = ServerConfig(name: "nas", baseURL: URL(string: "https://nas.local:8384")!)

    private func makeMock() async -> MockSyncthingAPIClient {
        let mock = MockSyncthingAPIClient()
        await mock.configure { m in
            m.folderList = MockData.folders
            m.deviceList = MockData.devices
            m.folderStatuses = ["photos": FolderStatus(state: "idle", globalBytes: 10), "docs": FolderStatus(state: "syncing")]
            m.connectionsResponse = ConnectionsResponse(connections: [MockData.laptopID: ConnectionInfo(connected: true)])
            m.deviceCompletions = [MockData.laptopID: Completion(completion: 42)]
            m.pendingDeviceList = [PendingDevice(deviceID: "NEW")]
        }
        return mock
    }

    private func makeSession(_ mock: MockSyncthingAPIClient) -> ServerSession {
        var config = ServerSession.Configuration()
        config.pollInterval = .seconds(3600)
        config.sleep = { _ in try await Task.sleep(for: .milliseconds(10)) }
        return ServerSession(server: server, client: mock, configuration: config)
    }

    /// Polls the main actor until `condition` holds or the timeout elapses.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testFullRefreshPopulatesState() async throws {
        let mock = await makeMock()
        let session = makeSession(mock)
        try await session.fullRefresh()
        XCTAssertEqual(session.state.status?.myID, MockData.myID)
        XCTAssertEqual(session.state.folders.count, 3)
        XCTAssertEqual(session.state.folderStatuses["docs"]?.state, "syncing")
        XCTAssertNil(session.state.folderStatuses["music"], "paused folders are not queried")
        XCTAssertEqual(session.state.deviceCompletion[MockData.laptopID]?.completion, 42)
        XCTAssertEqual(session.state.pendingDevices.map(\.deviceID), ["NEW"])
        XCTAssertEqual(session.state.connectedDeviceCount, 1)
    }

    func testStartGoesLiveAndAppliesEvents() async throws {
        let mock = await makeMock()
        await mock.configure { m in
            m.eventBatches = [.success([
                SyncthingEvent(id: 2, type: "StateChanged", data: ["folder": "photos", "from": "idle", "to": "scanning"]),
            ])]
        }
        let session = makeSession(mock)
        session.start()
        try await waitUntil { session.state.lastEventID == 2 }
        XCTAssertEqual(session.phase, .live)
        XCTAssertEqual(session.state.folderStatuses["photos"]?.state, "scanning")
        let calls = await mock.calls
        XCTAssertEqual(calls.first, "events since=0 limit=1", "resync cursor is taken before loading")
        XCTAssertTrue(calls.contains("events since=1"))
        session.stop()
        XCTAssertEqual(session.phase, .idle)
    }

    func testTransientErrorFallsBackToPollingAndRecovers() async throws {
        let mock = await makeMock()
        await mock.configure { m in
            m.eventBatches = [.failure(.timeout), .success([SyncthingEvent(id: 2, type: "Ping")])]
        }
        let session = makeSession(mock)
        session.start()
        try await waitUntil { session.state.lastEventID == 2 }
        XCTAssertEqual(session.phase, .live)
        let resyncs = await mock.calls.filter { $0 == "events since=0 limit=1" }.count
        XCTAssertEqual(resyncs, 2, "an interrupted stream resyncs before resuming")
        session.stop()
    }

    func testUnauthorizedStopsWithFailure() async throws {
        let mock = await makeMock()
        await mock.configure { m in m.statusResponse = .failure(.unauthorized) }
        let session = makeSession(mock)
        session.start()
        try await waitUntil { session.phase == .failed(.unauthorized) }
        XCTAssertFalse(session.isRunning)
    }

    func testActionsCallClientAndUpdateStateOptimistically() async throws {
        let mock = await makeMock()
        let session = makeSession(mock)
        try await session.fullRefresh()

        await session.setFolderPaused("docs", paused: true)
        XCTAssertEqual(session.state.folder("docs")?.paused, true)

        await session.setDevicePaused(MockData.laptopID, paused: true)
        XCTAssertEqual(session.state.device(MockData.laptopID)?.paused, true)

        await session.rescan(folder: "photos")
        await session.pauseAll()
        XCTAssertTrue(session.state.remoteDevices.allSatisfy(\.paused))
        await session.resumeAll()
        XCTAssertTrue(session.state.remoteDevices.allSatisfy { !$0.paused })

        let calls = await mock.calls
        XCTAssertTrue(calls.contains("setFolderPaused docs true"))
        XCTAssertTrue(calls.contains("pause \(MockData.laptopID)"))
        XCTAssertTrue(calls.contains("scan photos"))
        XCTAssertTrue(calls.contains("pause all"))
        XCTAssertTrue(calls.contains("resume all"))
        XCTAssertNil(session.actionError)
    }

    func testFailedActionSurfacesError() async throws {
        let mock = await makeMock()
        await mock.configure { m in m.actionError = .server(status: 500, message: "boom") }
        let session = makeSession(mock)
        await session.rescan(folder: "photos")
        XCTAssertEqual(session.actionError, .server(status: 500, message: "boom"))
    }

    func testShutdownStopsSession() async throws {
        let mock = await makeMock()
        let session = makeSession(mock)
        session.start()
        await session.shutdown()
        XCTAssertEqual(session.phase, .shutDown)
        XCTAssertFalse(session.isRunning)
    }

    func testAcceptPendingDeviceUsesServerDefaults() async throws {
        let mock = await makeMock()
        let session = makeSession(mock)
        try await session.fullRefresh()
        let ok = await session.accept(PendingDevice(deviceID: "NEW", name: "Joe"), name: "")
        XCTAssertTrue(ok)
        XCTAssertTrue(session.state.pendingDevices.isEmpty)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains("deviceDefaults"))
        XCTAssertTrue(calls.contains("addDevice NEW"))
    }

    func testPendingActionsBuildConfigsFromDefaults() {
        let defaults: JSONValue = .object(["path": "~", "rescanIntervalS": 3600, "devices": .array([.object(["deviceID": "ME"])])])
        let pending = PendingFolder(folderID: "abc", offeredBy: "JOE", label: "Pics", receiveEncrypted: true)
        let folder = PendingActions.folderConfig(from: defaults, for: pending, path: "~/Pics")
        XCTAssertEqual(folder["id"], "abc")
        XCTAssertEqual(folder["path"], "~/Pics")
        XCTAssertEqual(folder["type"], "receiveencrypted")
        XCTAssertEqual(folder["rescanIntervalS"], 3600, "unknown default fields are preserved")
        XCTAssertEqual(folder["devices"]?.arrayValue?.compactMap { $0["deviceID"]?.stringValue }, ["ME", "JOE"])

        let device = PendingActions.deviceConfig(from: .object(["compression": "metadata"]),
                                                 for: PendingDevice(deviceID: "D", name: "Remote"), name: "")
        XCTAssertEqual(device["deviceID"], "D")
        XCTAssertEqual(device["name"], "Remote")
        XCTAssertEqual(device["addresses"], .array(["dynamic"]))
        XCTAssertEqual(device["compression"], "metadata")

        XCTAssertEqual(PendingActions.suggestedPath(defaultPath: "~", folder: pending, separator: "/"), "~/Pics")
        XCTAssertEqual(PendingActions.suggestedPath(defaultPath: "/data/", folder: pending, separator: "/"), "/data/Pics")
        XCTAssertEqual(PendingActions.suggestedPath(defaultPath: nil, folder: PendingFolder(folderID: "x", offeredBy: "y"), separator: "\\"), "~\\x")
    }
}

@MainActor
final class ServerStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testSaveLoadRemoveKeepsKeyOutOfDefaults() throws {
        let defaults = makeDefaults()
        let secrets = InMemorySecretStore()
        let store = ServerStore(defaults: defaults, secrets: secrets)
        let server = ServerConfig(name: "nas", baseURL: URL(string: "https://nas:8384")!, pinnedFingerprint: "AB")
        try store.save(server, apiKey: "k3y")

        let reloaded = ServerStore(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reloaded.servers, [server])
        XCTAssertEqual(reloaded.endpoint(for: server.id),
                       ServerEndpoint(baseURL: server.baseURL, apiKey: "k3y", pinnedFingerprint: "AB"))
        let raw = defaults.dictionaryRepresentation().values.compactMap { $0 as? Data }
            .map { String(decoding: $0, as: UTF8.self) }.joined()
        XCTAssertFalse(raw.contains("k3y"), "API keys must never be written to UserDefaults")

        reloaded.remove(id: server.id)
        XCTAssertTrue(reloaded.servers.isEmpty)
        XCTAssertNil(try secrets.secret(for: server.id.uuidString))
    }

    func testMove() throws {
        let store = ServerStore(defaults: makeDefaults(), secrets: InMemorySecretStore())
        let a = ServerConfig(name: "a", baseURL: URL(string: "http://a")!)
        let b = ServerConfig(name: "b", baseURL: URL(string: "http://b")!)
        let c = ServerConfig(name: "c", baseURL: URL(string: "http://c")!)
        for s in [a, b, c] { try store.save(s, apiKey: "k") }
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(store.servers.map(\.name), ["b", "c", "a"])
    }

    func testURLNormalization() {
        XCTAssertEqual(ServerURL.normalize(" 192.168.1.10:8384 ")?.absoluteString, "https://192.168.1.10:8384")
        XCTAssertEqual(ServerURL.normalize("HTTP://homeserver.local:8384/")?.absoluteString, "http://homeserver.local:8384")
        XCTAssertEqual(ServerURL.normalize("https://x.com/st/?a=b#c")?.absoluteString, "https://x.com/st/")
        XCTAssertNil(ServerURL.normalize(""))
        XCTAssertNil(ServerURL.normalize("ftp://host"))
        XCTAssertNil(ServerURL.normalize("https://"))
    }

    func testAppModelSelectionAndLifecycle() throws {
        let defaults = makeDefaults()
        let store = ServerStore(defaults: defaults, secrets: InMemorySecretStore())
        let a = ServerConfig(name: "a", baseURL: URL(string: "http://a")!)
        let b = ServerConfig(name: "b", baseURL: URL(string: "http://b")!)
        try store.save(a, apiKey: "k"); try store.save(b, apiKey: "k")

        let model = AppModel(store: store, defaults: defaults, clientFactory: { _ in MockSyncthingAPIClient() })
        XCTAssertEqual(model.selectedServerID, a.id)
        model.setActive(true)
        XCTAssertEqual(model.selectedSession?.isRunning, true)

        model.selectedServerID = b.id
        XCTAssertEqual(model.session(for: a.id)?.isRunning, false, "only the selected server runs")
        XCTAssertEqual(model.selectedSession?.isRunning, true)

        model.setActive(false)
        XCTAssertEqual(model.selectedSession?.isRunning, false, "backgrounding stops live updates")

        let again = AppModel(store: store, defaults: defaults, clientFactory: { _ in MockSyncthingAPIClient() })
        XCTAssertEqual(again.selectedServerID, b.id, "selection persists")

        again.removeServer(b.id)
        XCTAssertEqual(again.selectedServerID, a.id)
    }
}

@MainActor
final class ServerEditorTests: XCTestCase {
    private func makeStore() -> ServerStore {
        let name = "test.\(UUID().uuidString)"
        return ServerStore(defaults: UserDefaults(suiteName: name)!, secrets: InMemorySecretStore())
    }

    private func validator(_ mock: MockSyncthingAPIClient, capture: (@Sendable (ServerEndpoint) -> Void)? = nil) -> ConnectionValidator {
        ConnectionValidator { endpoint in
            capture?(endpoint)
            return mock
        }
    }

    func testValidateAndSave() async throws {
        let mock = MockSyncthingAPIClient()
        let editor = ServerEditorModel(validator: validator(mock))
        editor.name = " Home "
        editor.urlText = "192.168.1.10:8384"
        editor.apiKey = " abc "
        XCTAssertTrue(editor.canSubmit)
        let store = makeStore()
        let saved = await editor.validateAndSave(to: store)
        XCTAssertEqual(saved?.name, "Home")
        XCTAssertEqual(saved?.baseURL.absoluteString, "https://192.168.1.10:8384")
        XCTAssertEqual(store.apiKey(for: try XCTUnwrap(saved).id), "abc")
        let calls = await mock.calls
        XCTAssertEqual(calls.first, "health", "noauth health check comes first")
        XCTAssertTrue(calls.contains("status"))
        XCTAssertTrue(calls.contains("version"))
    }

    func testUnauthorizedIsReportedAndNothingSaved() async {
        let mock = MockSyncthingAPIClient()
        await mock.configure { m in m.statusResponse = .failure(.unauthorized) }
        let editor = ServerEditorModel(validator: validator(mock))
        editor.urlText = "https://nas:8384"
        editor.apiKey = "wrong"
        let store = makeStore()
        let saved = await editor.validateAndSave(to: store)
        XCTAssertNil(saved)
        XCTAssertEqual(editor.error, .unauthorized)
        XCTAssertTrue(store.servers.isEmpty)
    }

    func testUntrustedCertificateFlowPinsFingerprint() async throws {
        let mock = MockSyncthingAPIClient()
        let cert = CertificateInfo(sha256: "ABCD", subject: "syncthing", host: "nas")
        await mock.configure { m in m.healthResponse = .failure(.untrustedCertificate(cert)) }
        let pins = PinRecorder()
        let editor = ServerEditorModel(validator: validator(mock) { pins.append($0.pinnedFingerprint) })
        editor.urlText = "https://nas:8384"
        editor.apiKey = "k"
        let store = makeStore()

        let first = await editor.validateAndSave(to: store)
        XCTAssertNil(first)
        XCTAssertEqual(editor.certificateToReview, cert)
        XCTAssertNil(editor.error)

        await mock.configure { m in m.healthResponse = .success(HealthResponse(status: "OK")) }
        let saved = await editor.trustReviewedCertificate(andSaveTo: store)
        XCTAssertEqual(saved?.pinnedFingerprint, "ABCD")
        XCTAssertEqual(pins.values, [nil, "ABCD"], "retry uses the pinned fingerprint")
    }

    func testImportPayload() {
        let editor = ServerEditorModel()
        XCTAssertTrue(editor.apply(importPayload: #"{"name":"NAS","url":"https://nas:8384","apiKey":"xyz"}"#))
        XCTAssertEqual(editor.name, "NAS")
        XCTAssertEqual(editor.urlText, "https://nas:8384")
        XCTAssertEqual(editor.apiKey, "xyz")
        XCTAssertFalse(editor.apply(importPayload: "garbage"))
    }
}

final class PinRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String?] = []
    func append(_ v: String?) { lock.lock(); _values.append(v); lock.unlock() }
    var values: [String?] { lock.lock(); defer { lock.unlock() }; return _values }
}
