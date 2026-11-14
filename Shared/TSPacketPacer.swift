import Foundation

/// Constant-rate transport with MPEG-TS null stuffing. Encoded media is unchanged.
/// Fixed 20 ms ticks avoid generating seconds of padding after an app suspension.
final class TSPacketPacer {
    struct Batch { let bytes: Data; let startsGOP: Bool }
    private struct Part { let bytes: Data; var offset = 0; let startsGOP: Bool }
    private var parts: [Part] = []
    private var head = 0
    private var credit: Int64 = 0
    private var started = false
    private var counter: UInt8 = 0
    private(set) var queuedBytes = 0
    let bitrate: Int
    init(bitrate: Int) { self.bitrate = max(188 * 8 * 50, bitrate) }
    func enqueue(_ bytes: Data, startsGOP: Bool) {
        precondition(bytes.count % 188 == 0)
        guard !bytes.isEmpty else { return }
        parts.append(Part(bytes: bytes, startsGOP: startsGOP)); queuedBytes += bytes.count
    }
    func tick() -> Batch? {
        guard started || queuedBytes > 0 else { return nil }
        // The denominator includes 8 bits/byte, 50 ticks/second, 188 bytes/packet.
        credit += Int64(bitrate)
        let count = Int(credit / 75200); credit %= 75200
        var bytes = Data(); var begins = false
        while bytes.count < count * 188 && head < parts.count {
            let part = parts[head]
            if part.offset == 0 && part.startsGOP {
                if !bytes.isEmpty { break } // IDR must be the first bytes of a new cache
                begins = true; started = true
            }
            guard started else { queuedBytes -= part.bytes.count - part.offset; head += 1; continue }
            let size = min(count * 188 - bytes.count, part.bytes.count - part.offset)
            bytes.append(part.bytes.subdata(in: part.offset..<(part.offset + size)))
            parts[head].offset += size; queuedBytes -= size
            if parts[head].offset == part.bytes.count { head += 1 }
        }
        guard started else { return nil }
        while bytes.count < count * 188 {
            bytes.append(contentsOf: [0x47, 0x1f, 0xff, 0x10 | counter])
            bytes.append(Data(repeating: 0xff, count: 184)); counter = (counter + 1) & 15
        }
        if head > 64 { parts.removeFirst(head); head = 0 }
        return Batch(bytes: bytes, startsGOP: begins)
    }
}
