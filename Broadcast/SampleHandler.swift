import ReplayKit
import Foundation
import os

final class SampleHandler: RPBroadcastSampleHandler {
    private let lock = NSLock()
    private var pipeline: MediaPipeline?
    private var server: HTTPServer?
    private var control: Task<Void, Never>?
    private var config: SessionConfig?
    private var ended = false
    private var stage = "Чтение настроек приложения"
    private var finishing = false
    private let log = Logger(subsystem: "org.example.ScreenMirror", category: "Broadcast")
    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        control = Task { [weak self] in
            guard let self else { return }
            do { try await self.run() }
            catch is CancellationError { }
            catch { self.fail(error) }
        }
    }
    private func run() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:19191/bridge/config.json")!, timeoutInterval: 5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MirrorError(message: "Откройте Screen Mirror, выберите TV и подготовьте трансляцию заново") }
        let config = try JSONDecoder().decode(SessionConfig.self, from: data)
        try Task.checkCancellation()
        guard let host = config.tv.transport.host else { throw MirrorError(message: "Нет адреса TV") }
        let p = MediaPipeline(config)
        p.onError = { [weak self] error in
            DispatchQueue.main.async { self?.fail(error, at: "Кодирование экрана и звука") }
        }
        setStage("Подготовка аппаратного H.264")
        try p.start()
        let http = HTTPServer(allowedHost: host, port: 19192, token: config.token)
        http.subscribeStream = { [weak p] callback in p?.live.subscribe(callback) ?? UUID() }
        http.unsubscribeStream = { [weak p] id in p?.live.unsubscribe(id) }
        http.streamQueueByteLimit = max(2_000_000, config.bitrate / 4)
        // Both closures execute on HTTPServer's serial queue.
        var mediaRequests: [String] = []
        http.onRequest = { [weak self] path in
            guard !path.contains("status.json"), !path.contains("/stop") else { return }
            mediaRequests.append(path)
            if mediaRequests.count > 12 { mediaRequests.removeFirst() }
            self?.log.info("HTTP: \(path, privacy: .public)")
        }
        http.resource = { [weak self, weak p, weak http] name in
            guard let p else { return nil }
            if name == "status.json" {
                var status = p.snapshot(); status.httpRequests = mediaRequests
                let health = http?.healthSnapshot() ?? StreamHealth()
                status.queuedBytes = health.queuedBytes
                status.httpReaders = health.activeReaders; status.disconnections = health.disconnections
                return ((try? JSONEncoder().encode(status)) ?? Data(), "application/json")
            }
            if name == "stop" {
                DispatchQueue.main.async { self?.fail(MirrorError(message: "Трансляция остановлена пользователем"), at: "Остановка") }
                return (Data("stopping".utf8), "text/plain")
            }
            return p.store.resource(name)
        }
        try install(p, http: http, config: config)
        setStage("Запуск локального HTTP-сервера")
        let base = try await http.start()
        let isHLS = config.transport == "hls"
        let mime = isHLS ? "application/vnd.apple.mpegurl" : "video/mpeg"
        var uri = base.appendingPathComponent(isHLS ? "live.m3u8" : "screen.ts")
        setStage("Ожидание кадров ReplayKit")
        var waited = 0
        while isHLS ? p.store.count < 2 : !p.live.ready {
            try await Task.sleep(nanoseconds: 50_000_000); waited += 1
            if waited > 400 { throw MirrorError(message: "ReplayKit не предоставил достаточно кадров для потока за 20 секунд") }
        }
        try Task.checkCancellation()
        setStage("Передача \(isHLS ? "HLS" : "MPEG-TS video/mpeg") телевизору через AVTransport")
        try await UPnP.play(config.tv, url: uri, mime: mime, live: !isHLS)
        log.info("Play принят TV; поток готов. Это не подтверждение декодирования на TV.")
        setStage("Проверка связи с телевизором")
        var failures = 0
        var recovery = StreamRecoveryPolicy()
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard config.reconnect else { continue }
            do {
                if let ip = HTTPServer.localIP(), ip != uri.host,
                   var parts = URLComponents(url: uri, resolvingAgainstBaseURL: false) {
                    parts.host = ip
                    if let changed = parts.url { uri = changed; try await UPnP.play(config.tv, url: uri, mime: mime, live: !isHLS) }
                }
                let state = try await UPnP.state(config.tv)
                let health = http.healthSnapshot()
                if recovery.needsRestart(state: state, health: isHLS ? StreamHealth() : health, now: monotonicSeconds()) {
                    log.info("Recovering TV playback: state=\(state, privacy: .public), readers=\(health.activeReaders), queued=\(health.queuedBytes)")
                    // ReplayKit/encoders stay alive. Re-open from the freshest IDR,
                    // with a new URI so the renderer does not reuse an old HTTP read.
                    if !isHLS {
                        var parts = URLComponents(url: uri, resolvingAgainstBaseURL: false)!
                        parts.queryItems = [URLQueryItem(name: "session", value: UUID().uuidString)]
                        if let updated = parts.url { uri = updated }
                    }
                    if state != "STOPPED" && state != "NO_MEDIA_PRESENT" { try? await UPnP.stop(config.tv) }
                    try await UPnP.play(config.tv, url: uri, mime: mime, live: !isHLS)
                }
                failures = 0
            } catch {
                failures += 1
                log.error("AVTransport retry \(failures): \(error.localizedDescription, privacy: .public)")
                // A temporary LAN/renderer outage is not a fatal capture error.
                // Keep the bounded latest-GOP cache and retry while user broadcast is active.
                try await Task.sleep(nanoseconds: UInt64(min(15, failures * 2)) * 1_000_000_000)
            }
        }
    }
    private func setStage(_ value: String) {
        lock.lock(); stage = value; lock.unlock()
        log.info("Этап: \(value, privacy: .public)")
    }
    private func fail(_ error: Error, at explicitStage: String? = nil) {
        lock.lock()
        guard !finishing, !ended else { lock.unlock(); return }
        finishing = true
        let failedStage = explicitStage ?? stage
        lock.unlock()
        // ReplayKit crosses a process boundary. Send explicit NSError userInfo,
        // rather than relying on Swift Error/LocalizedError serialization.
        let reason = (error as? MirrorError)?.message ?? error.localizedDescription
        let message = "\(failedStage): \(reason)"
        log.error("\(message, privacy: .public)")
        let nsError = NSError(domain: "ScreenMirror.Broadcast", code: 100,
                              userInfo: [NSLocalizedDescriptionKey: message,
                                         NSLocalizedFailureReasonErrorKey: reason])
        finishBroadcastWithError(nsError)
    }
    private func install(_ p: MediaPipeline, http: HTTPServer, config: SessionConfig) throws {
        lock.lock(); defer { lock.unlock() }
        if ended { p.stop(); throw CancellationError() }
        pipeline = p; server = http; self.config = config
    }
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        lock.lock(); let p = pipeline; lock.unlock()
        p?.process(sampleBuffer, type: sampleBufferType)
    }
    override func broadcastPaused() {
        lock.lock(); let p = pipeline; lock.unlock()
        p?.setPaused(true); log.info("ReplayKit paused")
    }
    override func broadcastResumed() {
        lock.lock(); let p = pipeline; lock.unlock()
        p?.setPaused(false); log.info("ReplayKit resumed; awaiting new image")
    }
    override func broadcastFinished() {
        control?.cancel(); control = nil
        lock.lock()
        ended = true
        let p = pipeline; pipeline = nil
        let http = server; server = nil
        let tv = config?.tv; config = nil
        lock.unlock()
        http?.stop(); p?.stop()
        if let tv { Task { try? await UPnP.stop(tv) } }
    }
}
