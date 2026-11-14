import XCTest
@testable import MirrorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CoreTests: XCTestCase {
    func tv() -> TV {
        TV(udn: "uuid:test-samsung", name: "Samsung & TV", model: "UE32H6300", location: URL(string: "http://192.168.31.30:7676/smp_37_")!, transport: URL(string: "http://192.168.31.30:7676/control")!, transportType: "urn:schemas-upnp-org:service:AVTransport:1", connection: nil, connectionType: nil)
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testPreferencesSurviveNewStoreInstanceAndKeepEverySetting() throws {
        let url = try directory().appendingPathComponent("nested/preferences.json")
        let first = PreferenceStore(url: url)
        let video = VideoPreferences(fps: 15, bitrate: 12_000_000, resolution: "1080p", audio: false, reconnect: false, transport: "hls", correctLandscapeFlip: false, steadyStream: false)
        try first.save(SavedPreferences(video: video, devices: [tv()], selectedID: tv().id, manualURL: tv().location.absoluteString))
        let second = PreferenceStore(url: url)
        let restored = try second.load()
        XCTAssertEqual(restored.video, video)
        XCTAssertEqual(restored.devices, [tv()])
        XCTAssertEqual(restored.selectedID, tv().id)
        XCTAssertEqual(restored.manualURL, tv().location.absoluteString)
        for _ in 0..<50 { try second.save(restored); XCTAssertEqual(try first.load().video, video) }
    }
    func testOlderVideoPreferencesFillMissingFields() throws {
        let data = Data("{\"fps\":15,\"bitrate\":8000000,\"resolution\":\"1080p\"}".utf8)
        let value = try JSONDecoder().decode(VideoPreferences.self, from: data)
        XCTAssertEqual(value.fps, 15); XCTAssertEqual(value.bitrate, 8_000_000)
        XCTAssertEqual(value.resolution, "1080p"); XCTAssertTrue(value.steadyStream)
        XCTAssertTrue(value.audio); XCTAssertTrue(value.correctLandscapeFlip)
    }
    func testPickerUsesActualResignedBroadcastID() throws {
        let plugins = try directory()
        let entry = plugins.appendingPathComponent("Broadcast.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.nikita.ScreenMirror.TEAM.Broadcast", "NSExtension": ["NSExtensionPointIdentifier": "com.apple.broadcast-services-upload"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: entry.appendingPathComponent("Info.plist"))
        XCTAssertEqual(BroadcastExtensionID.find(in: plugins), "com.nikita.ScreenMirror.TEAM.Broadcast")
        XCTAssertNil(BroadcastExtensionID.find(in: nil))
    }
    func testAbsentAndCorruptPreferences() throws {
        let url = try directory().appendingPathComponent("preferences.json")
        let store = PreferenceStore(url: url)
        XCTAssertEqual(try store.load().video, VideoPreferences())
        try Data("truncated json {".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: url), "truncated json {")
    }
    func testUnknownVersionRejectedAndInvalidSettingsNormalized() throws {
        let store = PreferenceStore(url: try directory().appendingPathComponent("p.json"))
        var value = SavedPreferences(); value.version = 99
        try store.save(value); XCTAssertThrowsError(try store.load())
        value.version = 1; value.video.fps = 999; value.video.bitrate = -1; value.video.resolution = "8k"; value.video.transport = "invalid"
        try store.save(value)
        XCTAssertEqual(try store.load().video, VideoPreferences())
    }
    func testStableIdentitySurvivesDHCPChange() {
        let old = tv()
        let changed = TV(udn: old.udn, name: old.name, model: old.model, location: URL(string: "http://192.168.31.55:7676/new")!, transport: old.transport, transportType: old.transportType, connection: nil, connectionType: nil)
        XCTAssertEqual(old.id, changed.id)
    }
    func testDiscoveryResponseAndSubnetLimits() {
        let response = "HTTP/1.1 200 OK\r\nlOcAtIoN: http://192.168.31.30:7676/smp_37_\r\nST: ssdp:all\r\n\r\n"
        XCTAssertEqual(SSDPMessage.location(response)?.absoluteString, tv().location.absoluteString)
        XCTAssertNil(SSDPMessage.location("LOCATION: file:///etc/passwd"))
        XCTAssertTrue(SSDPMessage.search().hasSuffix("\r\n\r\n"))
        let hosts = SubnetDiscovery.hosts(ip: "192.168.31.9", mask: "255.255.255.0")
        XCTAssertEqual(hosts.count, 253); XCTAssertTrue(hosts.contains("192.168.31.30"))
        XCTAssertFalse(hosts.contains("192.168.31.9")); XCTAssertFalse(hosts.contains("192.168.31.255"))
        XCTAssertEqual(SubnetDiscovery.hosts(ip: "10.1.2.4", mask: "255.0.0.0").count, 253)
        XCTAssertTrue(SubnetDiscovery.hosts(ip: "bad", mask: "255.255.255.0").isEmpty)
        XCTAssertTrue(SubnetDiscovery.hosts(ip: "10.1.2.4", mask: "255.0.255.0").isEmpty)
    }
    func testPairingCodesAndCredentialsRejected() {
        let value = "screenmirror://pair?url=http%3A%2F%2F192.168.31.30%3A7676%2Fsmp_37_"
        XCTAssertEqual(PairingCode.url(from: value), tv().location)
        XCTAssertNil(PairingCode.url(from: "javascript:alert(1)"))
        XCTAssertNil(PairingCode.url(from: "http://user:password@host/path"))
        XCTAssertNil(PairingCode.url(from: "screenmirror://other?url=http://host"))
    }
    func testStaticFramesAndBackwardClock() {
        var clock = FrameSchedule(); clock.update(sampleTime: 0, arrival: 0)
        var last: Int64 = -1; var keys: [Int64] = []
        for index in 0..<900 {
            let frame = clock.next(now: UInt64(index) * 1_000_000_000 / 30, keyInterval: 90000)!
            XCTAssertGreaterThan(frame.pts, last); last = frame.pts
            if frame.forceKey { keys.append(frame.pts) }
        }
        XCTAssertGreaterThanOrEqual(keys.count, 29)
        clock.update(sampleTime: 0, arrival: 30_000_000_000)
        XCTAssertNil(clock.next(now: 30_000_000_000))
    }
    func testImmediateGOPJoinAndBoundedCache() {
        let live = LiveStreamBuffer(limit: 4)
        var first: [Data] = []; let a = live.subscribe { first.append($0) }
        live.append(Data([9]), startsGOP: false); XCTAssertTrue(first.isEmpty)
        live.append(Data([1]), startsGOP: true); XCTAssertEqual(first, [Data([1])])
        live.append(Data([2]), startsGOP: false)
        var second: [Data] = []; let b = live.subscribe { second.append($0) }
        XCTAssertEqual(second, [Data([1,2])])
        live.append(Data([3,4,5]), startsGOP: false); XCTAssertFalse(live.ready)
        var waiting: [Data] = []; let c = live.subscribe { waiting.append($0) }
        live.append(Data([6]), startsGOP: false); XCTAssertTrue(waiting.isEmpty)
        live.append(Data([7]), startsGOP: true); XCTAssertEqual(waiting, [Data([7])])
        for id in [a,b,c] { live.unsubscribe(id) }
        let count = first.count; live.append(Data([8]), startsGOP: false); XCTAssertEqual(first.count, count)
    }
    func testPacerBitrateNoInitialPaddingAndPreservedMedia() {
        let pacer = TSPacketPacer(bitrate: 6_192_000)
        XCTAssertNil(pacer.tick())
        let packet = Data([0x47,0x01,0x00,0x10] + Array(repeating: UInt8(42), count: 184))
        pacer.enqueue(packet, startsGOP: true)
        var total = 0; var media = Data()
        for tick in 0..<500 {
            let batch = pacer.tick()!
            XCTAssertEqual(batch.bytes.count % 188, 0)
            if tick == 0 { XCTAssertTrue(batch.startsGOP) }
            total += batch.bytes.count
            for index in stride(from: 0, to: batch.bytes.count, by: 188) {
                let pid = Int(batch.bytes[index+1] & 31) * 256 + Int(batch.bytes[index+2])
                if pid != 8191 { media.append(batch.bytes.subdata(in: index..<(index+188))) }
            }
        }
        XCTAssertEqual(media, packet)
        XCTAssertLessThan(abs(total * 8 - 6_192_000 * 10), 188 * 8)
        XCTAssertEqual(pacer.queuedBytes, 0)
    }
    func testPacerNeverPutsOldGOPBeforeNewIDRFlag() {
        let pacer = TSPacketPacer(bitrate: 188 * 8 * 50 * 2)
        func packet(_ mark: UInt8) -> Data { Data([0x47,0x01,0x00,0x10] + Array(repeating: mark, count: 184)) }
        pacer.enqueue(packet(1), startsGOP: true)
        pacer.enqueue(packet(2), startsGOP: true)
        let first = pacer.tick()!, second = pacer.tick()!
        XCTAssertTrue(first.startsGOP); XCTAssertTrue(second.startsGOP)
        XCTAssertEqual(first.bytes[4], 1); XCTAssertEqual(second.bytes[4], 2)
        XCTAssertEqual(pacer.queuedBytes, 0)
    }
}

final class NetworkTests: XCTestCase {
    func fixture() throws -> (URL, UInt16) {
        let env = ProcessInfo.processInfo.environment
        guard let http = env["MIRROR_TEST_HTTP"], let udp = env["MIRROR_TEST_UDP"], let port = UInt16(udp), let url = URL(string: "http://127.0.0.1:\(http)/description") else {
            throw XCTSkip("Run tools/run_tests.py to start the loopback HTTP/UDP fixture")
        }
        return (url, port)
    }
    func testActualDirectedUDPDiscoveryDeduplicatesResponses() throws {
        let (url, port) = try fixture()
        let found = try SSDPProbe.search(hosts: ["127.0.0.1"], port: port, localIP: "127.0.0.1", timeout: 0.3, multicast: false)
        XCTAssertEqual(found, [url])
    }
    func testActualHTTPDescriptionRelativeServicesAndSOAP() async throws {
        let (url, _) = try fixture()
        let tv = try await UPnP.describe(url)
        XCTAssertEqual(tv.name, "Samsung & Test"); XCTAssertEqual(tv.udn, "uuid:fixture-tv")
        XCTAssertEqual(tv.transport.path, "/transport")
        XCTAssertEqual(tv.connection?.path, "/base/connection")
        let formats = try await UPnP.protocols(tv); XCTAssertEqual(formats, "http-get:*:video/mpeg:*")
        try await UPnP.play(tv, url: URL(string: "http://127.0.0.1:1234/screen.ts?a=1&b=2")!, mime: "video/mpeg")
        let state = try await UPnP.state(tv); XCTAssertEqual(state, "PLAYING")
        try await UPnP.stop(tv)
        do {
            _ = try await UPnP.soap(tv.transport, type: tv.transportType, action: "Unsupported", fields: [])
            XCTFail("SOAP fault must propagate")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Transition not available")) }
    }
}
