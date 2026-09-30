import XCTest
@testable import SyncthingKit

final class EventReducerTests: XCTestCase {
    private let laptop = MockData.laptopID
    private let phone = MockData.phoneID

    private func baseState() -> ServerState {
        var s = ServerState()
        s.status = SystemStatus(myID: MockData.myID)
        s.applyFolders(MockData.folders)
        s.applyDevices(MockData.devices)
        s.connections[laptop] = ConnectionInfo(connected: false)
        s.lastEventID = 10
        return s
    }

    private func event(_ id: Int, _ type: String, _ data: [String: JSONValue], time: Date? = nil) -> SyncthingEvent {
        SyncthingEvent(id: id, type: type, time: time, data: .object(data))
    }

    func testAdvancesCursorAndIgnoresReplays() {
        var s = baseState()
        let e1 = event(11, "StateChanged", ["folder": "docs", "from": "idle", "to": "scanning"])
        let effects = EventReducer.apply([e1], to: &s)
        XCTAssertEqual(s.lastEventID, 11)
        XCTAssertTrue(effects.isEmpty)

        // A replayed event must not re-apply.
        s.folderStatuses["docs"]?.state = "idle"
        _ = EventReducer.apply([e1], to: &s)
        XCTAssertEqual(s.folderStatuses["docs"]?.state, "idle")
        XCTAssertEqual(s.lastEventID, 11)
    }

    func testGapInEventIDsRequestsResync() {
        var s = baseState()
        let effects = EventReducer.apply([event(15, "Ping", [:])], to: &s)
        XCTAssertTrue(effects.contains(.resync))
        XCTAssertEqual(s.lastEventID, 15)
    }

    func testFirstBatchFromZeroIsNotAGap() {
        var s = ServerState()
        let effects = EventReducer.apply([event(500, "Ping", [:])], to: &s)
        XCTAssertFalse(effects.contains(.resync))
        XCTAssertEqual(s.lastEventID, 500)
    }

    func testEventsAppliedInIDOrder() {
        var s = baseState()
        _ = EventReducer.apply([
            event(12, "StateChanged", ["folder": "docs", "from": "scanning", "to": "idle"]),
            event(11, "StateChanged", ["folder": "docs", "from": "idle", "to": "scanning"]),
        ], to: &s)
        XCTAssertEqual(s.folderStatuses["docs"]?.state, "idle")
    }

    func testStateChangedUpdatesStateAndClearsObsoleteErrors() {
        var s = baseState()
        s.folderErrors["photos"] = [FileError(path: "a", error: "b")]
        s.scanProgress["photos"] = ScanProgress(current: 1, total: 2, rate: 0)
        _ = EventReducer.apply([event(11, "StateChanged", ["folder": "photos", "from": "scanning", "to": "syncing"])], to: &s)
        XCTAssertEqual(s.folderStatuses["photos"]?.state, "syncing")
        XCTAssertNil(s.folderErrors["photos"])
        XCTAssertNil(s.scanProgress["photos"])
        XCTAssertEqual(s.folderState("photos"), .syncing(percent: 100))
    }

    func testFolderSummaryReplacesStatus() {
        var s = baseState()
        let summary: JSONValue = .object(["state": .string("idle"), "globalBytes": .number(100), "needBytes": .number(40),
                                          "needTotalItems": .number(2)])
        _ = EventReducer.apply([event(11, "FolderSummary", ["folder": "docs", "summary": summary])], to: &s)
        XCTAssertEqual(s.folderStatuses["docs"]?.globalBytes, 100)
        XCTAssertEqual(s.folderStatuses["docs"]?.completion ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(s.folderState("docs"), .outOfSync)
    }

    func testScanProgress() {
        var s = baseState()
        _ = EventReducer.apply([
            event(11, "StateChanged", ["folder": "docs", "from": "idle", "to": "scanning"]),
            event(12, "FolderScanProgress", ["folder": "docs", "current": .number(25), "total": .number(100), "rate": .number(5)]),
        ], to: &s)
        XCTAssertEqual(s.folderState("docs"), .scanning(percent: 25))
        _ = EventReducer.apply([event(13, "StateChanged", ["folder": "docs", "from": "scanning", "to": "idle"])], to: &s)
        XCTAssertNil(s.scanProgress["docs"])
    }

    func testFolderErrorsSetAndClear() {
        var s = baseState()
        let errors: JSONValue = .array([.object(["path": .string("x"), "error": .string("denied")])])
        _ = EventReducer.apply([event(11, "FolderErrors", ["folder": "docs", "errors": errors])], to: &s)
        XCTAssertEqual(s.folderErrors["docs"], [FileError(path: "x", error: "denied")])
        _ = EventReducer.apply([event(12, "FolderErrors", ["folder": "docs", "errors": .array([])])], to: &s)
        XCTAssertNil(s.folderErrors["docs"])
    }

    func testFolderPauseResume() {
        var s = baseState()
        _ = EventReducer.apply([event(11, "FolderPaused", ["id": "docs", "label": "Documents"])], to: &s)
        XCTAssertEqual(s.folder("docs")?.paused, true)
        XCTAssertEqual(s.folderState("docs"), .paused)
        let effects = EventReducer.apply([event(12, "FolderResumed", ["id": "docs"])], to: &s)
        XCTAssertEqual(s.folder("docs")?.paused, false)
        XCTAssertEqual(effects, [.refreshFolderStatus("docs")])
    }

    func testDeviceConnectDisconnect() {
        var s = baseState()
        let t = Date(timeIntervalSince1970: 1_000_000)
        let effects = EventReducer.apply([event(11, "DeviceConnected", [
            "id": .string(laptop), "addr": "10.0.0.2:22000", "clientVersion": "v2.0.0", "type": "tcp-client",
        ], time: t)], to: &s)
        XCTAssertEqual(s.connections[laptop]?.connected, true)
        XCTAssertEqual(s.connections[laptop]?.address, "10.0.0.2:22000")
        XCTAssertEqual(s.connectedDeviceCount, 1)
        XCTAssertEqual(effects, [.refreshDeviceCompletion(laptop)])

        s.deviceRates[laptop] = TransferRates(inBps: 5, outBps: 5)
        let t2 = t.addingTimeInterval(60)
        _ = EventReducer.apply([event(12, "DeviceDisconnected", ["id": .string(laptop), "error": "EOF"], time: t2)], to: &s)
        XCTAssertEqual(s.connections[laptop]?.connected, false)
        XCTAssertNil(s.deviceRates[laptop])
        XCTAssertEqual(s.deviceStats[laptop]?.lastSeen, t2)
        XCTAssertEqual(s.deviceState(laptop), .disconnected)
    }

    func testDevicePauseResume() {
        var s = baseState()
        s.connections[laptop] = ConnectionInfo(connected: true)
        _ = EventReducer.apply([event(11, "DevicePaused", ["device": .string(laptop)])], to: &s)
        XCTAssertEqual(s.device(laptop)?.paused, true)
        XCTAssertEqual(s.connections[laptop]?.connected, false)
        XCTAssertEqual(s.deviceState(laptop), .paused)
        _ = EventReducer.apply([event(12, "DeviceResumed", ["device": .string(laptop)])], to: &s)
        XCTAssertEqual(s.device(laptop)?.paused, false)
    }

    func testFolderCompletionAggregatesOnceAllSharedFoldersKnown() {
        var s = baseState()
        // Laptop shares "photos" and "docs".
        let e1 = event(11, "FolderCompletion", ["folder": "photos", "device": .string(laptop), "completion": .number(50),
                                                "globalBytes": .number(1000), "needBytes": .number(500)])
        XCTAssertEqual(EventReducer.apply([e1], to: &s), [.refreshDeviceCompletion(laptop)],
                       "partial knowledge falls back to fetching the aggregate")
        XCTAssertEqual(s.remoteFolderCompletion[laptop]?["photos"]?.completion, 50)

        let e2 = event(12, "FolderCompletion", ["folder": "docs", "device": .string(laptop), "completion": .number(100),
                                                "globalBytes": .number(1000), "needBytes": .number(0)])
        XCTAssertEqual(EventReducer.apply([e2], to: &s), [])
        XCTAssertEqual(s.deviceCompletion[laptop]?.completion ?? 0, 75, accuracy: 0.001)
    }

    func testConfigSavedWithPayloadAppliesDirectly() {
        var s = baseState()
        s.folderStatuses["music"] = FolderStatus(state: "idle")
        let folders: JSONValue = .array([
            .object(["id": "docs", "label": "Docs Renamed", "devices": .array([])]),
            .object(["id": "new", "label": "New"]),
        ])
        let devices: JSONValue = .array([.object(["deviceID": .string(MockData.myID), "name": "nas"])])
        let effects = EventReducer.apply([event(11, "ConfigSaved", ["folders": folders, "devices": devices])], to: &s)
        XCTAssertEqual(s.folders.map(\.id), ["docs", "new"])
        XCTAssertEqual(s.folder("docs")?.label, "Docs Renamed")
        XCTAssertNil(s.folderStatuses["music"], "removed folders are pruned")
        XCTAssertEqual(s.devices.count, 1)
        XCTAssertEqual(effects, [.refreshFolderStatus("new")])
    }

    func testConfigSavedWithoutPayloadRequestsRefresh() {
        var s = baseState()
        XCTAssertEqual(EventReducer.apply([event(11, "ConfigSaved", [:])], to: &s), [.refreshConfig])
    }

    func testPendingChangesRequestRefresh() {
        var s = baseState()
        let effects = EventReducer.apply([
            event(11, "PendingDevicesChanged", ["added": .array([])]),
            event(12, "PendingFoldersChanged", ["removed": .array([])]),
        ], to: &s)
        XCTAssertEqual(effects, [.refreshPending])
    }

    func testUnknownEventsAreHarmless() throws {
        var s = baseState()
        let before = s
        let effects = EventReducer.apply([event(11, "BrandNewEventType", ["whatever": .number(1)])], to: &s)
        XCTAssertTrue(effects.isEmpty)
        var expected = before
        expected.lastEventID = 11
        XCTAssertEqual(s, expected)
    }

    func testFixtureStreamAppliesWithoutCrashing() throws {
        var s = baseState()
        s.lastEventID = 1
        let events = try Fixture.decode([SyncthingEvent].self, "events")
        let effects = EventReducer.apply(events, to: &s)
        XCTAssertEqual(s.lastEventID, 13)
        XCTAssertTrue(effects.contains(.refreshPending))
        XCTAssertFalse(effects.contains(.resync))
        XCTAssertEqual(s.folderErrors["default"]?.count, 1)
        XCTAssertEqual(s.folderStatuses["default"]?.globalBytes, 4)
    }
}

final class DerivedStateTests: XCTestCase {
    func testFolderSyncStateMapping() {
        func state(_ raw: String, need: Int = 0, pullErrors: Int = 0, paused: Bool = false) -> FolderSyncState {
            FolderSyncState.derive(paused: paused, status: FolderStatus(state: raw, globalBytes: 100, needTotalItems: need, pullErrors: pullErrors))
        }
        XCTAssertEqual(state("idle"), .upToDate)
        XCTAssertEqual(state("idle", need: 3), .outOfSync)
        XCTAssertEqual(state("idle", pullErrors: 1), .outOfSync)
        XCTAssertEqual(state("scanning"), .scanning(percent: nil))
        XCTAssertEqual(state("syncing"), .syncing(percent: 100))
        XCTAssertEqual(state("sync-preparing"), .syncing(percent: 100))
        XCTAssertEqual(state("scan-waiting"), .waiting)
        XCTAssertEqual(state("sync-waiting"), .waiting)
        XCTAssertEqual(state("cleaning"), .scanning(percent: nil))
        XCTAssertEqual(state("error"), .error)
        XCTAssertEqual(state("idle", paused: true), .paused)
        XCTAssertEqual(state("something-new"), .unknown)
        XCTAssertEqual(FolderSyncState.derive(paused: false, status: nil), .unknown)
    }

    func testDeviceSyncStateMapping() {
        XCTAssertEqual(DeviceSyncState.derive(paused: true, connected: true, completion: nil, sharedFolderCount: 1), .paused)
        XCTAssertEqual(DeviceSyncState.derive(paused: false, connected: false, completion: nil, sharedFolderCount: 1), .disconnected)
        XCTAssertEqual(DeviceSyncState.derive(paused: false, connected: true, completion: nil, sharedFolderCount: 0), .unused)
        XCTAssertEqual(DeviceSyncState.derive(paused: false, connected: true, completion: Completion(completion: 40), sharedFolderCount: 1), .syncing(percent: 40))
        XCTAssertEqual(DeviceSyncState.derive(paused: false, connected: true, completion: Completion(completion: 100), sharedFolderCount: 1), .upToDate)
    }

    func testRates() {
        let t0 = Date(timeIntervalSince1970: 0)
        let r = RateCalculator.rates(previous: (1000, 500, t0), current: (3000, 1500, t0.addingTimeInterval(2)))
        XCTAssertEqual(r, TransferRates(inBps: 1000, outBps: 500))
        XCTAssertEqual(RateCalculator.rates(previous: nil, current: (1, 1, t0)), .zero)
        XCTAssertEqual(RateCalculator.rates(previous: (5000, 5000, t0), current: (10, 10, t0.addingTimeInterval(1))), .zero,
                       "counter reset after restart")
        XCTAssertEqual(RateCalculator.rates(previous: (0, 0, t0), current: (10, 10, t0)), .zero, "zero interval")
        XCTAssertEqual(RateCalculator.rates(previous: (0, 0, nil), current: (10, 10, t0)), .zero)
    }

    func testApplyConnectionsComputesPerDeviceRates() {
        var s = ServerState()
        let t0 = Date(timeIntervalSince1970: 100)
        s.applyConnections(ConnectionsResponse(
            connections: ["A": ConnectionInfo(connected: true, inBytesTotal: 0, outBytesTotal: 0, at: t0)],
            total: TransferTotals(inBytesTotal: 0, outBytesTotal: 0, at: t0)))
        XCTAssertEqual(s.totalRates, .zero)
        let t1 = t0.addingTimeInterval(10)
        s.applyConnections(ConnectionsResponse(
            connections: ["A": ConnectionInfo(connected: true, inBytesTotal: 10_000, outBytesTotal: 2_000, at: t1)],
            total: TransferTotals(inBytesTotal: 10_000, outBytesTotal: 2_000, at: t1)))
        XCTAssertEqual(s.totalRates, TransferRates(inBps: 1000, outBps: 200))
        XCTAssertEqual(s.deviceRates["A"], TransferRates(inBps: 1000, outBps: 200))
    }

    func testAggregateCompletion() {
        let a = EventReducer.aggregate([Completion(globalBytes: 300, needBytes: 0), Completion(globalBytes: 100, needBytes: 100)])
        XCTAssertEqual(a.completion, 75, accuracy: 0.001)
        XCTAssertEqual(EventReducer.aggregate([]).completion, 100)
        XCTAssertEqual(EventReducer.aggregate([Completion(globalBytes: 0, needItems: 2)]).completion, 95)
    }

    func testRemoteDevicesExcludeSelf() {
        let s = MockData.state
        XCTAssertFalse(s.remoteDevices.contains { $0.deviceID == MockData.myID })
        XCTAssertEqual(s.remoteDevices.count, 2)
        XCTAssertEqual(s.connectedDeviceCount, 1)
    }
}
