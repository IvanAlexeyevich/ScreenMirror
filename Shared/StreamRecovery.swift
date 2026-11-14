import Foundation

struct StreamHealth {
    var activeReaders = 0
    var everHadReader = false
    var lastWriteAt: Double = 0
    var lastDisconnectAt: Double = 0
    var queuedBytes = 0
    var disconnections = 0
}

/// Recovery is based on real transport/HTTP evidence, with cooldown to avoid
/// repeatedly resetting an old TV while it is already buffering a new stream.
struct StreamRecoveryPolicy {
    private var nextAllowedAt: Double = 0
    mutating func needsRestart(state: String, health: StreamHealth, now: Double) -> Bool {
        guard now >= nextAllowedAt else { return false }
        let stopped = state == "STOPPED" || state == "NO_MEDIA_PRESENT"
        let readerLost = health.everHadReader && health.activeReaders == 0 && now - health.lastDisconnectAt >= 3
        let writerStalled = health.activeReaders > 0 && health.queuedBytes > 0 && health.lastWriteAt > 0 && now - health.lastWriteAt >= 8
        guard stopped || readerLost || writerStalled else { return false }
        nextAllowedAt = now + 15
        return true
    }
}
