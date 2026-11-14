import Foundation

/// Constant-rate transport with MPEG-TS null stuffing. Encoded media is unchanged.
/// Budget uses elapsed monotonic time; a delayed/coalesced timer must not halve throughput.
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
    /// Extract every unsent media byte in order when switching to direct delivery.
    /// A partially emitted PES/GOP retains its continuation flag, never a false IDR.
    func drainPending() -> [Batch] {
        var result: [Batch] = []
        for index in head..<parts.count {
            let part = parts[index]
            if part.offset < part.bytes.count {
                result.append(Batch(bytes: part.bytes.subdata(in: part.offset..<part.bytes.count), startsGOP: part.startsGOP && part.offset == 0))
            }
        }
        parts.removeAll(); head = 0; queuedBytes = 0; credit = 0; started = false
        return result
    }
    func tick(elapsedNanoseconds: UInt64 = 20_000_000) -> Batch? {
        guard started || queuedBytes > 0 else { return nil }
        // Cap a single catch-up batch: do not emit seconds of padding after pause.
        let elapsed = min(elapsedNanoseconds, 200_000_000)
        credit += Int64(bitrate) * Int64(elapsed)
        let denominator: Int64 = 188 * 8 * 1_000_000_000
        let count = Int(credit / denominator); credit %= denominator
        guard count > 0 else { return nil }
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
