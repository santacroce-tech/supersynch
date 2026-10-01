import XCTest
@testable import SyncthingKit

@MainActor
final class SyncSessionTests: XCTestCase {
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

    private func makeSession(_ mock: MockSyncthingAPIClient) -> SyncSession {
        var config = SyncSession.Configuration()
        config.pollInterval = .seconds(3600)
        config.sleep = { _ in try await Task.sleep(for: .milliseconds(10)) }
        return SyncSession(client: mock, configuration: config)
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

    func testEngineNotRunningIsReportedAndRecovers() async throws {
        let mock = await makeMock()
        await mock.configure { m in
            m.eventBatches = [.failure(.notRunning), .success([SyncthingEvent(id: 2, type: "Ping")])]
        }
        let session = makeSession(mock)
        session.start()
        try await waitUntil { session.state.lastEventID == 2 }
        XCTAssertEqual(session.phase, .live)
        let resyncs = await mock.calls.filter { $0 == "events since=0 limit=1" }.count
        XCTAssertEqual(resyncs, 2, "an interrupted stream resyncs before resuming")
        session.stop()
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
        await session.rescanAll()
        await session.pauseAll()
        XCTAssertTrue(session.state.remoteDevices.allSatisfy(\.paused))
        await session.resumeAll()
        XCTAssertTrue(session.state.remoteDevices.allSatisfy { !$0.paused })

        let calls = await mock.calls
        for expected in ["setFolderPaused docs true", "pause \(MockData.laptopID)", "scan photos", "scan all", "pause all", "resume all"] {
            XCTAssertTrue(calls.contains(expected), expected)
        }
        XCTAssertNil(session.actionError)
    }

    func testFailedActionSurfacesError() async throws {
        let mock = await makeMock()
        await mock.configure { m in m.actionError = .engine("boom") }
        let session = makeSession(mock)
        await session.rescan(folder: "photos")
        XCTAssertEqual(session.actionError, .engine("boom"))
    }

    func testSaveDeviceSharesAndUnsharesFolders() async throws {
        let mock = await makeMock()
        let session = makeSession(mock)
        try await session.fullRefresh()
        // Laptop currently shares photos + docs; switch it to photos + music.
        let ok = await session.saveDevice(DeviceDraft(deviceID: MockData.laptopID, name: "Mac"), sharing: ["photos", "music"])
        XCTAssertTrue(ok)
        XCTAssertEqual(session.state.folder("music")?.deviceIDs.contains(MockData.laptopID), true)
        XCTAssertEqual(session.state.folder("docs")?.deviceIDs.contains(MockData.laptopID), false)
        XCTAssertEqual(session.state.folder("photos")?.deviceIDs.contains(MockData.laptopID), true)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains("setDevice \(MockData.laptopID)"))
        XCTAssertFalse(calls.contains("setFolder photos"), "unchanged folders aren't rewritten")
    }

    func testAcceptPendingDeviceRemovesItFromPending() async throws {
        let mock = await makeMock()
        let session = makeSession(mock)
        try await session.fullRefresh()
        do { let ok = await session.saveDevice(DeviceDraft(deviceID: "NEW", name: "Joe")); XCTAssertTrue(ok) }
        XCTAssertTrue(session.state.pendingDevices.isEmpty)
        XCTAssertNotNil(session.state.device("NEW"))
    }

    func testSaveAndRemoveFolder() async throws {
        let mock = await makeMock()
        let session = makeSession(mock)
        try await session.fullRefresh()
        let draft = FolderDraft(id: "abc", label: "New", path: "/tmp/New", deviceIDs: [MockData.laptopID])
        do { let ok = await session.saveFolder(draft); XCTAssertTrue(ok) }
        XCTAssertEqual(session.state.folder("abc")?.label, "New")
        do { let ok = await session.removeFolder("abc"); XCTAssertTrue(ok) }
        XCTAssertNil(session.state.folder("abc"))
    }

    func testIsSyncIdle() {
        var s = NodeState()
        s.status = SystemStatus(myID: MockData.myID)
        s.applyFolders([FolderConfig(id: "a", deviceIDs: [MockData.myID, MockData.laptopID])])
        s.applyDevices(MockData.devices)
        XCTAssertFalse(s.isSyncIdle, "unknown folder status isn't idle")
        s.folderStatuses["a"] = FolderStatus(state: "idle")
        XCTAssertTrue(s.isSyncIdle)
        s.connections[MockData.laptopID] = ConnectionInfo(connected: true)
        s.deviceCompletion[MockData.laptopID] = Completion(completion: 50)
        XCTAssertFalse(s.isSyncIdle, "a connected peer still catching up")
        s.deviceCompletion[MockData.laptopID] = Completion(completion: 100)
        XCTAssertTrue(s.isSyncIdle)
        s.folderStatuses["a"] = FolderStatus(state: "idle", needTotalItems: 1)
        XCTAssertFalse(s.isSyncIdle)
    }
}

final class DraftTests: XCTestCase {
    func testFolderDraftJSON() {
        let draft = FolderDraft(id: "abc", label: "Pics", path: "/p", deviceIDs: ["D1"])
        XCTAssertEqual(draft.json["id"], "abc")
        XCTAssertEqual(draft.json["devices"], [["deviceID": "D1"]])
        let accept = FolderDraft(accepting: PendingFolder(folderID: "x", offeredBy: "MAC", label: "L", receiveEncrypted: true), path: "/q")
        XCTAssertEqual(accept.type, "receiveencrypted")
        XCTAssertEqual(accept.deviceIDs, ["MAC"])
        XCTAssertEqual(FolderDraft.sharing("f", with: ["A", "B"]), ["id": "f", "devices": [["deviceID": "A"], ["deviceID": "B"]]])
    }

    func testGeneratedFolderIDFormat() {
        let id = FolderDraft.generateID()
        XCTAssertNotNil(id.wholeMatch(of: /[a-z2-9]{5}-[a-z2-9]{5}/))
    }

    func testDeviceDraftDefaultsToDynamic() {
        XCTAssertEqual(DeviceDraft(deviceID: "D", addresses: []).json["addresses"], ["dynamic"])
    }

    func testDeviceIDValidation() {
        let valid = "P56IOI7-MZJNU2Y-IQGDREY-DM2MGTI-MGL3BXN-PQ6W5BM-TBBZ4TJ-XZWICQ2"
        XCTAssertEqual(DeviceIDValidator.normalize(valid), valid)
        XCTAssertEqual(DeviceIDValidator.normalize(valid.lowercased()), valid)
        XCTAssertEqual(DeviceIDValidator.normalize(valid.replacingOccurrences(of: "-", with: "")), valid)
        XCTAssertEqual(DeviceIDValidator.normalize(" " + valid.replacingOccurrences(of: "-", with: " ") + "\n"), valid)
        XCTAssertNil(DeviceIDValidator.normalize("P56IOI7-MZJNU2Y-IQGDREY-DM2MGTI-MGL3BXN-PQ6W5BM-TBBZ4TJ-XZWICQ3"), "bad check digit")
        XCTAssertNil(DeviceIDValidator.normalize("too-short"))
        XCTAssertNil(DeviceIDValidator.normalize(""))
    }

    func testPathSuggestion() {
        XCTAssertEqual(PathSuggestion.make(defaultPath: "/docs", name: "Pics", separator: "/"), "/docs/Pics")
        XCTAssertEqual(PathSuggestion.make(defaultPath: "/docs/", name: "a/b", separator: "/"), "/docs/a-b")
        XCTAssertEqual(PathSuggestion.make(defaultPath: nil, name: "x", separator: "/"), "~/x")
    }
}

/// Polls the main actor until `condition` holds or the timeout elapses.
@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { XCTFail("timed out"); return }
        try await Task.sleep(for: .milliseconds(20))
    }
}
