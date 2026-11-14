import Foundation

/// Direct TS delivery has no HLS segment wait. A new reader gets only the current
/// GOP (PAT/PMT + IDR + following packets), then each packet batch as it is muxed.
final class LiveStreamBuffer {
    private let lock = NSLock()
    private var cache = Data()
    private var hasIDR = false
    private var cacheValid = false
    private var readers: [UUID: (Data, Bool) -> Void] = [:]
    private let limit: Int
    init(limit: Int = 2_000_000) { self.limit = limit }
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return cacheValid && !cache.isEmpty }
    func append(_ bytes: Data, startsGOP: Bool) {
        guard !bytes.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if startsGOP { cache.removeAll(keepingCapacity: true); hasIDR = true; cacheValid = true }
        guard hasIDR else { return }
        if cacheValid {
            if cache.count + bytes.count <= limit { cache.append(bytes) }
            else { cache.removeAll(keepingCapacity: true); cacheValid = false }
        }
        // Callbacks enqueue work on their own queue; never reenter this object.
        for reader in readers.values { reader(bytes, startsGOP) }
    }
    func subscribe(_ reader: @escaping (Data) -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        // If no cached IDR is available, start this reader at the next GOP.
        var started = cacheValid && !cache.isEmpty
        if started { reader(cache) }
        readers[id] = { bytes, startsGOP in
            if !started { started = startsGOP }
            if started { reader(bytes) }
        }
        return id
    }
    func unsubscribe(_ id: UUID) { lock.lock(); defer { lock.unlock() }; readers.removeValue(forKey: id) }
}
