import Foundation

// End-to-end harness: production TS muxer packages real compressed elementary streams.
// tools/test_mux.sh checks resulting audio/video by decoding them with FFmpeg.
@main enum MuxHarness {
    static func main() throws {
        var clock = FrameSchedule()
        clock.update(sampleTime: 10, arrival: 1_000_000_000)
        var lastPTS: Int64 = -1
        var keys: [Int64] = []
        for index in 0..<360 {
            let now = UInt64(1_000_000_000) + UInt64(index) * 1_000_000_000 / 30
            // No new ReplayKit image for 12 seconds: time and IDRs must advance.
            let frame = clock.next(now: now)!
            precondition(frame.pts > lastPTS); lastPTS = frame.pts
            if frame.forceKey { keys.append(frame.pts) }
        }
        precondition(keys.count >= 6)
        for index in 1..<keys.count { precondition(keys[index] - keys[index - 1] <= 180000) }
        clock.update(sampleTime: 9, arrival: 13_000_000_000)
        precondition(clock.next(now: 13_000_000_000) == nil) // no backward PTS
        clock.reset()
        clock.update(sampleTime: 40, arrival: 14_000_000_000)
        precondition(clock.next(now: 14_000_000_000)!.forceKey)
        print("Sparse-image frame pacing: monotonic PTS and periodic IDR requests OK")
        var fastClock = FrameSchedule()
        fastClock.update(sampleTime: 0, arrival: 0)
        var fastKeys: [Int64] = []
        for index in 0..<180 {
            let frame = fastClock.next(now: UInt64(index) * 1_000_000_000 / 30, keyInterval: 90000)!
            if frame.forceKey { fastKeys.append(frame.pts) }
        }
        precondition(fastKeys.count >= 5)
        for i in 1..<fastKeys.count { precondition(fastKeys[i] - fastKeys[i-1] <= 93000) }
        let immediate = LiveStreamBuffer(limit: 8)
        var early: [Data] = []
        let earlyID = immediate.subscribe { early.append($0) }
        immediate.append(Data([9]), startsGOP: false)
        precondition(early.isEmpty)
        immediate.append(Data([1,2]), startsGOP: true)
        precondition(early == [Data([1,2])]) // visible immediately, no segment wait
        immediate.append(Data([3]), startsGOP: false)
        var joining: [Data] = []
        let joiningID = immediate.subscribe { joining.append($0) }
        precondition(joining == [Data([1,2,3])])
        immediate.append(Data([4,5]), startsGOP: true)
        var newest: [Data] = []
        let newestID = immediate.subscribe { newest.append($0) }
        precondition(newest == [Data([4,5])]) // old GOP is not replayed
        immediate.append(Data(repeating: 6, count: 9), startsGOP: false)
        precondition(!immediate.ready)
        var waiting: [Data] = []
        let waitingID = immediate.subscribe { waiting.append($0) }
        immediate.append(Data([7]), startsGOP: false)
        precondition(waiting.isEmpty)
        immediate.append(Data([8]), startsGOP: true)
        precondition(waiting == [Data([8])])
        for id in [earlyID, joiningID, newestID, waitingID] { immediate.unsubscribe(id) }
        print("Immediate TS: first IDR delivered without segment wait, GOP join, cache bounds, 1s key schedule OK")
        let args = CommandLine.arguments
        let h264 = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[1])))
        let audio = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[2])))
        var nalStarts: [(Int, Int)] = []
        var cursor = 0
        while cursor + 3 < h264.count {
            if h264[cursor] == 0 && h264[cursor + 1] == 0 {
                if h264[cursor + 2] == 1 { nalStarts.append((cursor, cursor + 3)); cursor += 3; continue }
                if h264[cursor + 2] == 0 && h264[cursor + 3] == 1 { nalStarts.append((cursor, cursor + 4)); cursor += 4; continue }
            }
            cursor += 1
        }
        var units: [Data] = []; var current = Data()
        for (i, start) in nalStarts.enumerated() {
            let end = i + 1 < nalStarts.count ? nalStarts[i + 1].0 : h264.count
            if h264[start.1] & 31 == 9 && !current.isEmpty { units.append(current); current = Data() }
            current.append(contentsOf: h264[start.0..<end])
        }
        if !current.isEmpty { units.append(current) }
        var packets: [Data] = []; cursor = 0
        while cursor + 7 <= audio.count {
            precondition(audio[cursor] == 0xff && audio[cursor + 1] & 0xf0 == 0xf0)
            let size = (Int(audio[cursor + 3] & 3) << 11) | (Int(audio[cursor + 4]) << 3) | Int(audio[cursor + 5] >> 5)
            precondition(size >= 7 && cursor + size <= audio.count)
            packets.append(Data(audio[cursor..<(cursor + size)])); cursor += size
        }
        let mux = TransportStream(); mux.begin(audio: true)
        var wire = Data()
        var a = 0
        for (i, unit) in units.enumerated() {
            let pts = Int64(90000 + i * 3000)
            mux.appendVideo(unit, pts: pts, key: i % 60 == 0)
            wire.append(mux.drain())
            while a < packets.count && Int64(90000 + a * 1920) <= pts {
                mux.appendAudio(packets[a], pts: Int64(90000 + a * 1920)); wire.append(mux.drain()); a += 1
            }
        }
        while a < packets.count { mux.appendAudio(packets[a], pts: Int64(90000 + a * 1920)); wire.append(mux.drain()); a += 1 }
        precondition(wire.count % 188 == 0 && !wire.isEmpty)
        precondition(mux.bytes.isEmpty)
        try wire.write(to: URL(fileURLWithPath: args[3]))
        let paced = TSPacketPacer(bitrate: 6_192_000)
        paced.enqueue(wire, startsGOP: true)
        var padded = Data()
        while paced.queuedBytes > 0 { padded.append(paced.tick()!.bytes) }
        for _ in 0..<50 { padded.append(paced.tick()!.bytes) }
        try padded.write(to: URL(fileURLWithPath: args[3] + ".paced.ts"))
        let store = SegmentStore()
        for _ in 0..<10 { store.append(wire, duration: 2) }
        precondition(store.resource("segment0.ts") == nil)
        precondition(store.resource("segment9.ts") != nil)
        let text = String(data: store.resource("live.m3u8")!.0, encoding: .utf8)!
        precondition(text.contains("#EXT-X-MEDIA-SEQUENCE:4"))
        precondition(!text.contains("ENDLIST"))
        let liveStore = SegmentStore()
        liveStore.append(Data([1]), duration: 2)
        var received: [Data] = []
        let subscription = liveStore.subscribe { received.append($0) }
        liveStore.append(Data([2]), duration: 2)
        liveStore.unsubscribe(subscription)
        liveStore.append(Data([3]), duration: 2)
        precondition(received == [Data([1]), Data([2])])
        print("Continuous TS subscription: IDR segment pre-roll, order and unsubscribe OK")
        let discontinuous = SegmentStore()
        discontinuous.append(Data([1]), duration: 2)
        discontinuous.append(Data([2]), duration: 2, discontinuity: true)
        let initial = String(data: discontinuous.resource("live.m3u8")!.0, encoding: .utf8)!
        precondition(initial.contains("#EXT-X-DISCONTINUITY\n"))
        precondition(initial.contains("#EXT-X-DISCONTINUITY-SEQUENCE:0"))
        for _ in 0..<6 { discontinuous.append(Data([3]), duration: 2) }
        let rolled = String(data: discontinuous.resource("live.m3u8")!.0, encoding: .utf8)!
        precondition(rolled.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1"))
        precondition(!rolled.contains("#EXT-X-DISCONTINUITY\n"))
        print("Native muxer: \(units.count) H.264 access units, \(packets.count) AAC packets; bounded HLS window OK")
    }
}
