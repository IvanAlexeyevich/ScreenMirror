import Foundation

/// ReplayKit can deliver no new image for a static screen. Advance the last image
/// using elapsed monotonic time, anchored to the original ReplayKit A/V timeline.
struct FrameSchedule {
    private var sampleTime: Double?
    private var arrival: UInt64 = 0
    private var lastPTS: Int64?
    private var lastKey: Int64?
    mutating func update(sampleTime: Double, arrival: UInt64) {
        guard sampleTime.isFinite else { return }
        self.sampleTime = sampleTime; self.arrival = arrival
    }
    mutating func next(now: UInt64, keyInterval: Int64 = 171000) -> (pts: Int64, forceKey: Bool)? {
        guard let sampleTime else { return nil }
        let elapsed = now >= arrival ? Double(now - arrival) / 1_000_000_000 : 0
        let value = sampleTime + elapsed
        guard value.isFinite, value >= 0, value < Double(Int64.max / 90000) else { return nil }
        let pts = Int64((value * 90000).rounded())
        if let lastPTS, pts <= lastPTS { return nil }
        let force = lastKey == nil || pts - (lastKey ?? pts) >= keyInterval
        lastPTS = pts
        if force { lastKey = pts }
        return (pts, force)
    }
    mutating func reset() { self = FrameSchedule() }
}
