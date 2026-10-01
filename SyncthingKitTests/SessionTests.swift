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

    func testMaintenanceActions() async throws {
        let mock = await makeMock()
        await mock.configure { m in m.errors = [LogEntry(when: nil, message: "disk full")] }
        let session = makeSession(mock)
        try await session.fullRefresh()
        XCTAssertEqual(session.state.systemErrors.map(\.message), ["disk full"])
        await session.clearSystemErrors()
        XCTAssertTrue(session.state.systemErrors.isEmpty)

        do { let ok = await session.saveIgnores("photos", lines: ["*.tmp"]); XCTAssertTrue(ok) }
        let ignores = try await session.loadIgnores("photos")
        XCTAssertEqual(ignores.lines, ["*.tmp"])

        let version = FileVersion(versionTime: .now, versionTimeRaw: "2024-01-01T00:00:00Z")
        do { let ok = await session.restore("a.txt", version: version, in: "photos"); XCTAssertTrue(ok) }
        await session.dismiss(PendingDevice(deviceID: "NEW"))
        XCTAssertTrue(session.state.pendingDevices.isEmpty)
        await session.overrideRemoteChanges("photos")
        await session.revertLocalChanges("photos")

        let calls = await mock.calls
        for expected in ["clearErrors", "setIgnores photos", "scan photos", "restore photos a.txt", "dismissDevice NEW",
                         "override photos", "revert photos"] {
            XCTAssertTrue(calls.contains(expected), expected)
        }
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
        XCTAssertEqual(FolderDraft.sharing(FolderConfig(id: "f"), with: ["A", "B"]),
                       ["id": "f", "devices": [["deviceID": "A"], ["deviceID": "B"]]])
    }

    func testSharingKeepsEncryptionPasswords() {
        let folder = FolderConfig(id: "f", deviceIDs: ["A", "U"], encryptionPasswords: ["U": "secret"])
        XCTAssertEqual(FolderDraft.sharing(folder, with: ["A", "U", "B"]),
                       ["id": "f", "devices": [["deviceID": "A"], ["deviceID": "U", "encryptionPassword": "secret"], ["deviceID": "B"]]])
    }

    func testFolderDraftVersioningAndPasswords() {
        var draft = FolderDraft(id: "x", path: "/p", deviceIDs: ["U"], encryptionPasswords: ["U": "pw"])
        XCTAssertNil(draft.json["versioning"], "unchanged unless set")
        draft.versioning = Versioning(type: "trashcan", params: ["cleanoutDays": "30"])
        XCTAssertEqual(draft.json["versioning"], ["type": "trashcan", "params": ["cleanoutDays": "30"]])
        XCTAssertEqual(draft.json["devices"], [["deviceID": "U", "encryptionPassword": "pw"]])
    }

    func testDeviceDraftLimitsAndIntroducer() {
        let json = DeviceDraft(deviceID: "D", introducer: true, maxSendKbps: 100, maxRecvKbps: 0).json
        XCTAssertEqual(json["introducer"], true)
        XCTAssertEqual(json["maxSendKbps"], 100)
        XCTAssertEqual(json["maxRecvKbps"], 0)
    }

    func testConflictNames() {
        XCTAssertTrue(ConflictName.isConflict("report.sync-conflict-20240101-120000-ABCDEFG.pdf"))
        XCTAssertFalse(ConflictName.isConflict("report.pdf"))
        XCTAssertEqual(ConflictName.original(of: "report.sync-conflict-20240101-120000-ABCDEFG.pdf"), "report.pdf")
        XCTAssertEqual(ConflictName.original(of: "notes.sync-conflict-20240101-120000-ABCDEFG"), "notes")
        XCTAssertEqual(ConflictName.original(of: "a.tar.sync-conflict-20240101-120000-ABCDEFG.gz"), "a.tar.gz")
        XCTAssertNil(ConflictName.original(of: "plain.txt"))
    }

    func testMaintenanceModelsDecode() throws {
        let config = try JSONDecoder().decode(FolderConfig.self, from: Data(#"""
            {"id":"f","devices":[{"deviceID":"A","encryptionPassword":""},{"deviceID":"U","encryptionPassword":"pw"}],
             "versioning":{"type":"staggered","params":{"maxAge":"31536000"},"cleanupIntervalS":3600}}
            """#.utf8))
        XCTAssertEqual(config.encryptionPasswords, ["U": "pw"])
        XCTAssertEqual(config.versioning, Versioning(type: "staggered", params: ["maxAge": "31536000"]))

        let versions = try JSONDecoder().decode([String: [FileVersion]].self, from: Data(#"""
            {"a/b.txt":[{"versionTime":"2024-01-01T12:00:00.123456789+01:00","modTime":"2023-12-31T10:00:00Z","size":42}]}
            """#.utf8))
        let v = try XCTUnwrap(versions["a/b.txt"]?.first)
        XCTAssertEqual(v.size, 42)
        XCTAssertEqual(v.versionTimeRaw, "2024-01-01T12:00:00.123456789+01:00", "kept verbatim for restore")

        let log = try JSONDecoder().decode(LogResponse.self, from: Data(#"{"errors":[{"when":"2024-01-01T00:00:00Z","message":"boom","level":8}]}"#.utf8))
        XCTAssertEqual(log.entries.first?.message, "boom")
        XCTAssertTrue(log.entries.first?.isError ?? false)
        let ignores = try JSONDecoder().decode(IgnorePatterns.self, from: Data(#"{"ignore":["*.tmp"],"expanded":null}"#.utf8))
        XCTAssertEqual(ignores, IgnorePatterns(lines: ["*.tmp"]))
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

@MainActor
final class NetworkPolicyTests: XCTestCase {
    func testDecision() {
        XCTAssertTrue(NetworkPolicy.allows(wifiOnly: false, respectLowDataMode: false, expensive: true, constrained: true))
        XCTAssertFalse(NetworkPolicy.allows(wifiOnly: true, respectLowDataMode: false, expensive: true, constrained: false))
        XCTAssertTrue(NetworkPolicy.allows(wifiOnly: true, respectLowDataMode: false, expensive: false, constrained: false))
        XCTAssertFalse(NetworkPolicy.allows(wifiOnly: false, respectLowDataMode: true, expensive: false, constrained: true))
    }

    func testPolicyPersistsAndNotifies() {
        let defaults = UserDefaults(suiteName: "net-\(UUID().uuidString)")!
        let policy = NetworkPolicy(defaults: defaults, monitorPath: false)
        XCTAssertFalse(policy.wifiOnly, "cellular allowed by default")
        XCTAssertTrue(policy.respectLowDataMode)
        var changes = 0
        policy.onChange = { changes += 1 }
        policy.wifiOnly = true
        XCTAssertTrue(policy.allowsSync, "still on Wi-Fi")
        policy.update(expensive: true, constrained: false)
        XCTAssertFalse(policy.allowsSync)
        XCTAssertNotNil(policy.blockReason)
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(NetworkPolicy(defaults: defaults, monitorPath: false).wifiOnly, "setting persists")
    }
}

final class FolderPathTests: XCTestCase {
    private let home = "/var/mobile/Containers/Data/Application/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    func testExpand() {
        XCTAssertEqual(FolderPath.expand("~/Documents/Sync", home: home), home + "/Documents/Sync")
        XCTAssertEqual(FolderPath.expand("~", home: home), home)
        XCTAssertEqual(FolderPath.expand("/abs/path", home: home), "/abs/path")
        XCTAssertEqual(FolderPath.resolve("~/Documents", home: home).path, home + "/Documents")
    }

    func testPortable() {
        XCTAssertEqual(FolderPath.portable(home + "/Documents/Sync", home: home), "~/Documents/Sync")
        XCTAssertEqual(FolderPath.portable(home, home: home), "~")
        // A previous container's path (after reinstall) maps to the same place.
        XCTAssertEqual(FolderPath.portable("/var/mobile/Containers/Data/Application/98A907DB-5D9D-4699-ABB7-BE65FBB25BA8/Documents/Sync",
                                           home: home), "~/Documents/Sync")
        XCTAssertEqual(FolderPath.portable("/private/var/mobile/Containers/Shared/AppGroup/X/Docs", home: home),
                       "/private/var/mobile/Containers/Shared/AppGroup/X/Docs", "other locations unchanged")
    }

    func testDisplayName() {
        XCTAssertEqual(FolderPath.displayName("~/Documents/Sync/Photos"), "On My iPhone › SuperSynch › Sync › Photos")
        XCTAssertEqual(FolderPath.displayName("~/Documents"), "On My iPhone › SuperSynch")
        XCTAssertEqual(FolderPath.displayName("/elsewhere/x"), "/elsewhere/x")
    }
}
