import XCTest
@testable import SyncthingKit

final class DecodingTests: XCTestCase {
    func testSystemStatus() throws {
        let s = try Fixture.decode(SystemStatus.self, "system-status")
        XCTAssertEqual(s.myID, "P56IOI7-MZJNU2Y-IQGDREY-DM2MGTI-MGL3BXN-PQ6W5BM-TBBZ4TJ-XZWICQ2")
        XCTAssertEqual(s.uptime, 2635)
        XCTAssertEqual(s.goroutines, 49)
        XCTAssertEqual(s.pathSeparator, "/")
        XCTAssertTrue(s.discoveryEnabled)
        XCTAssertNotNil(s.startTime)
        XCTAssertEqual(s.discoveryStatus["IPv4 local"], .some(nil))
        XCTAssertEqual(s.discoveryStatus["global@https://discovery-v4.syncthing.net/v2/"], "500 Internal Server Error")
        XCTAssertEqual(s.connectionServiceStatus["quic://0.0.0.0:22000"], "listen udp: address already in use")
    }

    func testSystemStatusToleratesMissingAndMistypedFields() throws {
        let json = #"{"myID": "ABC", "uptime": "17", "goroutines": null}"#
        let s = try JSONDecoder().decode(SystemStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s.myID, "ABC")
        XCTAssertEqual(s.uptime, 17)
        XCTAssertEqual(s.goroutines, 0)
        XCTAssertNil(s.startTime)
        XCTAssertTrue(s.discoveryStatus.isEmpty)
    }

    func testSystemVersionIgnoresNewFields() throws {
        let v = try Fixture.decode(SystemVersion.self, "system-version")
        XCTAssertEqual(v.version, "v2.0.10")
        XCTAssertEqual(v.os, "linux")
        XCTAssertEqual(v.arch, "amd64")
    }

    func testConnections() throws {
        let c = try Fixture.decode(ConnectionsResponse.self, "system-connections")
        XCTAssertEqual(c.connections.count, 2)
        let off = try XCTUnwrap(c.connections["DOVII4U-SQEEESM-VZ2CVTC-CJM4YN5-QNV7DCU-5U3ASRL-YVFG6TH-W5DV5AA"])
        XCTAssertFalse(off.connected)
        XCTAssertNil(off.at, "Go zero time decodes as nil")
        let on = try XCTUnwrap(c.connections["YZJBJFX-RDBL7WY-6ZGKJ2D-4MJB4E7-ZATSDUY-LD6Y3L3-MLFUYWE-AEMXJAC"])
        XCTAssertTrue(on.connected)
        XCTAssertEqual(on.address, "127.0.0.1:22002")
        XCTAssertEqual(on.inBytesTotal, 556)
        XCTAssertEqual(on.type, "tcp-client")
        XCTAssertEqual(c.total.inBytesTotal, 1479)
        XCTAssertEqual(c.total.outBytesTotal, 1318)
        XCTAssertNotNil(c.total.at)
    }

    func testFolderConfig() throws {
        let folders = try Fixture.decode([FolderConfig].self, "config-folders")
        XCTAssertEqual(folders.count, 2)
        XCTAssertEqual(folders[0].id, "default")
        XCTAssertEqual(folders[0].label, "Default Folder")
        XCTAssertEqual(folders[0].deviceIDs.count, 2)
        XCTAssertEqual(folders[0].rescanIntervalS, 3600)
        XCTAssertFalse(folders[0].paused)
        // Sparse object: defaults fill in.
        XCTAssertEqual(folders[1].type, "receiveonly")
        XCTAssertTrue(folders[1].paused)
        XCTAssertEqual(folders[1].displayName, "abcde-fghij")
        XCTAssertEqual(folders[1].deviceIDs, [])
    }

    func testDeviceConfig() throws {
        let devices = try Fixture.decode([DeviceConfig].self, "config-devices")
        XCTAssertEqual(devices[0].name, "syno")
        XCTAssertEqual(devices[0].addresses, ["dynamic"])
        XCTAssertEqual(devices[0].compression, "metadata")
        XCTAssertTrue(devices[1].paused)
        XCTAssertEqual(devices[1].addresses, [], "null arrays decode as empty")
        XCTAssertEqual(devices[1].displayName, "2CYF2WQ")
    }

    func testFolderStatus() throws {
        let s = try Fixture.decode(FolderStatus.self, "db-status")
        XCTAssertEqual(s.state, "syncing")
        XCTAssertEqual(s.globalBytes, 1000)
        XCTAssertEqual(s.globalFiles, 10)
        XCTAssertEqual(s.globalDirectories, 4)
        XCTAssertEqual(s.needBytes, 250)
        XCTAssertEqual(s.needTotalItems, 2)
        XCTAssertEqual(s.sequence, 42)
        XCTAssertNotNil(s.stateChanged)
        XCTAssertEqual(s.completion, 75, accuracy: 0.001)
    }

    func testFolderStatusCompletionEdgeCases() {
        XCTAssertEqual(FolderStatus(globalBytes: 0).completion, 100)
        XCTAssertEqual(FolderStatus(globalBytes: 0, needTotalItems: 3).completion, 0)
        XCTAssertEqual(FolderStatus(globalBytes: 100, needBytes: 500).completion, 0)
    }

    func testCompletion() throws {
        let c = try Fixture.decode(Completion.self, "db-completion")
        XCTAssertEqual(c.completion, 99.9937565835, accuracy: 1e-9)
        XCTAssertEqual(c.globalBytes, 156_793_013_575)
        XCTAssertEqual(c.needItems, 412)
        XCTAssertEqual(c.remoteState, "valid")
    }

    func testNeed() throws {
        let n = try Fixture.decode(NeedResponse.self, "db-need")
        XCTAssertEqual(n.progress.first?.name, "ls")
        XCTAssertEqual(n.progress.first?.size, 34640)
        XCTAssertNotNil(n.progress.first?.modified)
        XCTAssertEqual(n.queued.count, 1)
        XCTAssertEqual(n.rest, [])
        XCTAssertEqual(n.all.count, 2)
    }

    func testFolderErrors() throws {
        let r = try Fixture.decode(FolderErrorsResponse.self, "folder-errors")
        XCTAssertEqual(r.folder, "nnhic-sxuae")
        XCTAssertEqual(r.errors, [FileError(path: "noperm.txt", error: "hashing: open /path/to/folder/noperm.txt: permission denied")])
    }

    func testStats() throws {
        let d = try Fixture.decode([String: DeviceStatistics].self, "stats-device")
        XCTAssertNotNil(d.values.first?.lastSeen)
        XCTAssertEqual(d.values.first?.lastConnectionDurationS ?? 0, 556335.42, accuracy: 0.01)

        let f = try Fixture.decode([String: FolderStatistics].self, "stats-folder")
        XCTAssertNotNil(f["folderid"]?.lastScan)
        XCTAssertEqual(f["folderid"]?.lastFileName, "file/name")
        XCTAssertNil(f["never"]?.lastScan)
        XCTAssertNil(f["never"]?.lastFileName)
    }

    func testPendingDevices() throws {
        let devices = try PendingDecoding.devices(from: Fixture.data("pending-devices"))
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].name, "Friend Joe")
        XCTAssertEqual(devices[0].address, "192.168.1.2:22000")
        XCTAssertEqual(try PendingDecoding.devices(from: Data("null".utf8)), [])
        XCTAssertEqual(try PendingDecoding.devices(from: Data("{}".utf8)), [])
    }

    func testPendingFoldersFlattenedPerOffer() throws {
        let folders = try PendingDecoding.folders(from: Fixture.data("pending-folders"))
        XCTAssertEqual(folders.count, 3)
        let joe = try XCTUnwrap(folders.first { $0.folderID == "cpkn4-57ysy" && $0.label == "Joe's folder" })
        XCTAssertTrue(joe.receiveEncrypted)
        XCTAssertEqual(joe.offeredBy, "P56IOI7-MZJNU2Y-IQGDREY-DM2MGTI-MGL3BXN-PQ6W5BM-TBBZ4TJ-XZWICQ2")
        XCTAssertEqual(Set(folders.map(\.id)).count, 3, "IDs are unique per (folder, device)")
    }

    func testEventsDecodeAndTypedPayloads() throws {
        let events = try Fixture.decode([SyncthingEvent].self, "events")
        XCTAssertEqual(events.count, 12)
        XCTAssertEqual(events[0].payload, .deviceConnected(
            device: "NFGKEKE-7Z6RTH7-I3PRZXS-DEJF3UJ-FRWJBFO-VBBTDND-4SGNGVZ-QUQHJAG",
            address: "172.16.32.25:22000", clientVersion: "v0.13.4", connectionType: "TCP (Client)"))
        XCTAssertEqual(events[1].payload, .stateChanged(folder: "default", from: "scanning", to: "idle"))
        guard case let .folderCompletion(folder, device, completion) = events[2].payload else { return XCTFail() }
        XCTAssertEqual(folder, "default")
        XCTAssertEqual(device, "I6KAH76-66SLLLB-5PFXSOA-UFJCDZC-YAOMLEK-CP2GB32-BV5RQST-3PSROAU")
        XCTAssertEqual(completion.completion, 100)
        XCTAssertEqual(completion.globalItems, 4)
        XCTAssertEqual(events[3].payload, .folderErrors(folder: "default", errors: [FileError(path: "h2j/aslkjd", error: "permission denied")]))
        XCTAssertEqual(events[4].payload, .folderScanProgress(folder: "bd7q3-zskm5", current: 50, total: 200, rate: 12.5))
        XCTAssertEqual(events[5].payload, .folderPaused(folder: "abcde-fghij"))
        XCTAssertEqual(events[6].payload, .devicePaused(device: "NFGKEKE-7Z6RTH7-I3PRZXS-DEJF3UJ-FRWJBFO-VBBTDND-4SGNGVZ-QUQHJAG"))
        XCTAssertEqual(events[7].payload, .deviceDisconnected(device: "NFGKEKE-7Z6RTH7-I3PRZXS-DEJF3UJ-FRWJBFO-VBBTDND-4SGNGVZ-QUQHJAG", error: "unexpected EOF"))
        XCTAssertEqual(events[8].payload, .pendingDevicesChanged)
        guard case let .folderSummary(sf, summary) = events[9].payload else { return XCTFail() }
        XCTAssertEqual(sf, "default")
        XCTAssertEqual(summary.globalBytes, 4)
        XCTAssertEqual(summary.state, "idle")
        XCTAssertEqual(events[10].payload, .other(type: "SomeFutureEvent"))
        XCTAssertEqual(events[10].data, .null)
        XCTAssertEqual(events[11].globalID, 15)
    }

    func testEventsNullArray() throws {
        XCTAssertEqual(try JSONDecoder().decode([SyncthingEvent]?.self, from: Data("null".utf8)), nil)
    }

    func testDateParsing() throws {
        let nanos = try XCTUnwrap(SyncthingDate.parse("2014-07-13T21:04:33.687836696+02:00"))
        let millis = try XCTUnwrap(SyncthingDate.parse("2014-07-13T21:04:33.687+02:00"))
        XCTAssertEqual(nanos, millis)
        XCTAssertNotNil(SyncthingDate.parse("2015-11-07T00:09:47Z"))
        XCTAssertNotNil(SyncthingDate.parse("2024-01-31T08:27:30.7+01:00"))
        XCTAssertNil(SyncthingDate.parse("0001-01-01T00:00:00Z"))
        XCTAssertNil(SyncthingDate.parse(""))
        XCTAssertNil(SyncthingDate.parse("not a date"))
        let utc = try XCTUnwrap(SyncthingDate.parse("1970-01-01T00:00:01.5Z"))
        XCTAssertEqual(utc.timeIntervalSince1970, 1.5, accuracy: 0.0001)
    }

    func testJSONValueRoundTripPreservesUnknownFields() throws {
        let json = #"{"id":"x","nested":{"a":[1,2.5,true,null,"s"]},"big":156793013575}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let reencoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(value, reencoded)
        let out = String(decoding: try JSONEncoder().encode(value["big"]), as: UTF8.self)
        XCTAssertEqual(out, "156793013575", "integers encode without a decimal point")
    }
}
