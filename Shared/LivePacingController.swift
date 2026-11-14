import Foundation
import Dispatch

func monotonicSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

/// Runs on the media queue. Overshoot is a change of delivery mode, never a reason
/// to stop ReplayKit or discard already encoded video/audio.
final class LivePacingController {
    enum Mode: String { case direct, paced, directFallback }
    private(set) var mode: Mode
    private(set) var fallbackReason: String?
    private var pacer: TSPacketPacer?
    private var lastTick: UInt64?
    private let maximumQueuedBytes: Int
    var queuedBytes: Int { pacer?.queuedBytes ?? 0 }
    init(bitrate: Int, enabled: Bool) {
        let transportRate = bitrate * 5 / 4 + 192_000
        maximumQueuedBytes = max(64_000, transportRate / 16) // 0.5 s, no growing seconds-long backlog
        mode = enabled ? .paced : .direct
        pacer = enabled ? TSPacketPacer(bitrate: transportRate) : nil
    }
    func enqueue(_ bytes: Data, startsGOP: Bool) -> [TSPacketPacer.Batch] {
        guard let pacer else { return [TSPacketPacer.Batch(bytes: bytes, startsGOP: startsGOP)] }
        pacer.enqueue(bytes, startsGOP: startsGOP)
        if pacer.queuedBytes > maximumQueuedBytes {
            return bypass("Очередь ровной подачи превысила 0,5 секунды; включена прямая выдача")
        }
        return []
    }
    func tick(now: UInt64) -> [TSPacketPacer.Batch] {
        guard let pacer else { return [] }
        let elapsed = lastTick.map { now >= $0 ? now - $0 : 20_000_000 } ?? 20_000_000
        lastTick = now
        if elapsed > 250_000_000 && pacer.queuedBytes > 0 {
            return bypass("Таймер подачи задержан; включена прямая выдача")
        }
        if let batch = pacer.tick(elapsedNanoseconds: elapsed) { return [batch] }
        return []
    }
    private func bypass(_ reason: String) -> [TSPacketPacer.Batch] {
        let pending = pacer?.drainPending() ?? []
        pacer = nil; mode = .directFallback; fallbackReason = reason
        return pending
    }
    func discardForSystemPause() {
        _ = pacer?.drainPending(); lastTick = nil
    }
}

final class LockedValue<Value> {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; self.value = value }
}
