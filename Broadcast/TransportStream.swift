import Foundation

/// ISO/IEC 13818-1: single-program TS, H.264 PID 256, ADTS AAC PID 257.
final class TransportStream {
    private var counters: [Int: UInt8] = [:]
    private(set) var bytes = Data()
    func drain() -> Data {
        let result = bytes
        bytes = Data()
        return result
    }
    func begin(audio: Bool) {
        bytes.removeAll(keepingCapacity: true)
        section(pid: 0, body: [0x00,0xb0,0x0d,0,1,0xc1,0,0,0,1,0xf0,0])
        let entries: [UInt8] = [0x1b,0xe1,0,0xf0,0] + (audio ? [0x0f,0xe1,1,0xf0,0] : [])
        let length = 13 + entries.count
        section(pid: 4096, body: [0x02,0xb0 | UInt8(length >> 8),UInt8(length & 255),0,1,0xc1,0,0,0xe1,0,0xf0,0] + entries)
    }
    private func section(pid: Int, body: [UInt8]) {
        var crc: UInt32 = 0xffffffff
        for byte in body {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = (crc & 0x80000000 != 0) ? (crc << 1) ^ 0x04c11db7 : crc << 1 }
        }
        let check = [UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16), UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)]
        packets(pid: pid, payload: Data([0] + body + check), pcr: nil, random: false)
    }
    func appendVideo(_ data: Data, pts: Int64, key: Bool) {
        pes(pid: 256, streamID: 0xe0, data: data, pts: pts, key: key)
    }
    func appendAudio(_ data: Data, pts: Int64) {
        pes(pid: 257, streamID: 0xc0, data: data, pts: pts, key: false)
    }
    private func pes(pid: Int, streamID: UInt8, data: Data, pts: Int64, key: Bool) {
        let stamp = UInt64(max(0, pts)) & 0x1ffffffff
        let timestamp: [UInt8] = [0x21 | UInt8((stamp >> 29) & 14), UInt8((stamp >> 22) & 255), UInt8((stamp >> 14) & 254) | 1, UInt8((stamp >> 7) & 255), UInt8((stamp << 1) & 254) | 1]
        let length = pid == 256 ? 0 : data.count + 8
        let header: [UInt8] = [0,0,1,streamID,UInt8((length >> 8) & 255),UInt8(length & 255),0x80,0x80,5]
        packets(pid: pid, payload: Data(header + timestamp) + data, pcr: pid == 256 ? stamp : nil, random: key)
    }
    private func packets(pid: Int, payload: Data, pcr: UInt64?, random: Bool) {
        var offset = 0; var first = true
        while offset < payload.count {
            let clock = first ? pcr : nil
            let minAdaptation = clock == nil ? 0 : 8 // length + flags + PCR
            let count = min(184 - minAdaptation, payload.count - offset)
            let adaptation = 184 - count
            let cc = counters[pid, default: 0]; counters[pid] = (cc + 1) & 15
            var packet: [UInt8] = [0x47, UInt8((pid >> 8) & 31) | (first ? 0x40 : 0), UInt8(pid & 255), (adaptation > 0 ? 0x30 : 0x10) | cc]
            if adaptation > 0 {
                packet.append(UInt8(adaptation - 1))
                if adaptation > 1 {
                    packet.append((clock == nil ? 0 : 0x10) | (first && random ? 0x40 : 0))
                    if let c = clock {
                        packet += [UInt8((c >> 25) & 255),UInt8((c >> 17) & 255),UInt8((c >> 9) & 255),UInt8((c >> 1) & 255),UInt8((c & 1) << 7) | 0x7e,0]
                    }
                    while packet.count < 4 + adaptation { packet.append(0xff) }
                }
            }
            bytes.append(contentsOf: packet)
            bytes.append(payload.subdata(in: offset..<(offset + count)))
            offset += count; first = false
        }
    }
}

/// Thread-safe bounded media window. Encoding never waits for a slow renderer.
final class SegmentStore {
    struct Segment { let index: Int; let duration: Double; let data: Data; let discontinuity: Bool }
    private let lock = NSLock()
    private var segments: [Segment] = []
    private var next = 0
    private var discardedDiscontinuities = 0
    private var subscribers: [UUID: (Data) -> Void] = [:]
    func subscribe(_ callback: @escaping (Data) -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID(); subscribers[id] = callback
        // Each complete segment begins with PAT/PMT and an IDR, so a new reader
        // can start from the most recent complete segment instead of old history.
        if let latest = segments.last { callback(latest.data) }
        return id
    }
    func unsubscribe(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }; subscribers.removeValue(forKey: id)
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return next }
    func append(_ data: Data, duration: Double, discontinuity: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        segments.append(Segment(index: next, duration: duration, data: data, discontinuity: discontinuity)); next += 1
        while segments.count > 6 { if segments.removeFirst().discontinuity { discardedDiscontinuities += 1 } }
        // Subscribers must enqueue work and return immediately; never do network I/O
        // or call back into this store while its lock is held.
        for callback in subscribers.values { callback(data) }
    }
    func resource(_ name: String) -> (Data, String)? {
        lock.lock(); defer { lock.unlock() }
        if name == "live.m3u8" {
            guard segments.count >= 2 else { return nil }
            let target = 3 // Stable for the entire presentation; encoder bounds rounded EXTINF to <= 3.
            var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(segments[0].index)\n#EXT-X-DISCONTINUITY-SEQUENCE:\(discardedDiscontinuities)\n"
            for s in segments {
                if s.discontinuity { text += "#EXT-X-DISCONTINUITY\n" }
                text += "#EXTINF:\(String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), s.duration)),\nsegment\(s.index).ts\n" }
            return (Data(text.utf8), "application/vnd.apple.mpegurl")
        }
        guard name.hasPrefix("segment"), name.hasSuffix(".ts"), let index = Int(name.dropFirst(7).dropLast(3)), let s = segments.first(where: { $0.index == index }) else { return nil }
        return (s.data, "video/mp2t")
    }
}
