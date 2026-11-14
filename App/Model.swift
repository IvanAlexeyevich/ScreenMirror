import SwiftUI
import os

@MainActor final class Model: ObservableObject {
    @Published var devices: [TV] = [] { didSet { persist() } }
    @Published var selected: TV? { didSet { persist() } }
    @Published var status = "Не подключено"
    @Published var diagnostics = ""
    @Published var manualURL = "" { didSet { persist() } }
    @Published var busy = false
    @Published var live = true
    @Published var prepared = false
    @Published var mirrorStatus = "Не запущено"
    @Published var audio = true { didSet { persist() } }
    @Published var reconnect = true { didSet { persist() } }
    @Published var transport = "ts" { didSet { persist() } }
    @Published var correctLandscapeFlip = true { didSet { persist() } }
    @Published var fps = 30 { didSet { persist() } }
    @Published var bitrate = 6_000_000 { didSet { persist() } }
    @Published var resolution = "720p" { didSet { persist() } }
    @Published var steadyStream = true { didSet { persist() } }
    @Published var onlineIDs = Set<String>()
    @Published var broadcasting = false
    private let preferencesStore = PreferenceStore()
    private var loadingPreferences = true
    private var bridge: HTTPServer?
    private var mirrorSession: SessionConfig?
    private var monitor: Task<Void, Never>?
    private var activeTV: TV?
    private var server: HTTPServer?
    private var poll: Task<Void, Never>?
    private let log = Logger(subsystem: "org.example.ScreenMirror", category: "Diagnostic")
    init() {
        defer { loadingPreferences = false }
        do {
            let saved = try preferencesStore.load()
            devices = saved.devices; selected = saved.devices.first { $0.id == saved.selectedID }
            manualURL = saved.manualURL
            fps = saved.video.fps; bitrate = saved.video.bitrate; resolution = saved.video.resolution
            audio = saved.video.audio; reconnect = saved.video.reconnect; transport = saved.video.transport
            correctLandscapeFlip = saved.video.correctLandscapeFlip; steadyStream = saved.video.steadyStream
            status = selected == nil ? "Выберите телевизор" : "Сохранённый телевизор"
        } catch { note("Не удалось прочитать настройки: \(error.localizedDescription)") }
    }
    private func persist() {
        guard !loadingPreferences else { return }
        let video = VideoPreferences(fps: fps, bitrate: bitrate, resolution: resolution, audio: audio,
                                     reconnect: reconnect, transport: transport,
                                     correctLandscapeFlip: correctLandscapeFlip, steadyStream: steadyStream)
        do { try preferencesStore.save(SavedPreferences(video: video, devices: devices, selectedID: selected?.id, manualURL: manualURL)) }
        catch { note("Не удалось сохранить настройки: \(error.localizedDescription)") }
    }
    private func remember(_ tv: TV) {
        let previous = selected
        devices.removeAll { $0.id == tv.id || $0.location == tv.location }
        devices.append(tv); onlineIDs.insert(tv.id)
        if previous == nil || previous?.id == tv.id || previous?.location == tv.location { selected = tv }
    }
    func forgetSelected() {
        guard !prepared, let tv = selected else { return }
        selected = nil; devices.removeAll { $0.id == tv.id }; onlineIDs.remove(tv.id)
        if manualURL == tv.location.absoluteString { manualURL = "" }
    }
    func note(_ text: String) {
        log.info("\(text, privacy: .public)")
        diagnostics += "\(Date().formatted(date: .omitted, time: .standard)) \(text)\n"
        if diagnostics.count > 24000 { diagnostics = String(diagnostics.suffix(16000)) }
    }
    func prepareBroadcast() async {
        guard let tv = selected, !prepared, !busy else { return }
        busy = true; defer { busy = false }
        await stop()
        do {
            let refreshed = try await UPnP.describe(tv.location)
            remember(refreshed)
        } catch { onlineIDs.remove(tv.id); fail(MirrorError(message: "Телевизор недоступен. Включите его и нажмите «Найти телевизор».")); return }
        guard let tv = selected else { return }
        bridge?.stop(); monitor?.cancel()
        prepared = false
        let config = SessionConfig(tv: tv, fps: fps, bitrate: bitrate, resolution: resolution, audio: audio, reconnect: reconnect, transport: transport, correctLandscapeFlip: correctLandscapeFlip, steadyStream: steadyStream)
        mirrorSession = config
        let bridge = HTTPServer(allowedHost: "127.0.0.1", port: 19191, token: "bridge", loopbackOnly: true)
        bridge.resource = { name in
            guard name == "config.json", let bytes = try? JSONEncoder().encode(config) else { return nil }
            return (bytes, "application/json")
        }
        self.bridge = bridge
        do {
            _ = try await bridge.start()
            prepared = true
            mirrorStatus = "Нажмите системную кнопку ниже и подтвердите начало записи экрана."
            note("Конфигурация для ReplayKit готова; TV \(tv.name)")
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        var req = URLRequest(url: URL(string: "http://127.0.0.1:19192/\(config.token)/status.json")!, timeoutInterval: 2)
                        req.cachePolicy = .reloadIgnoringLocalCacheData
                        let (data, _) = try await URLSession.shared.data(for: req)
                        let state = try JSONDecoder().decode(BroadcastStatus.self, from: data)
                        self?.broadcasting = true
                        self?.note("Broadcast: кадров \(state.videoFrames), AAC \(state.audioPackets), сегментов \(state.segments), выход \(state.outputSize), цель \(state.targetBitrate), средний TS \(String(format: "%.2f", state.actualMbps)) Мбит/с, очередь HTTP \(state.queuedBytes) байт, очередь подачи \(state.pacingBytes) байт, режим \(state.pacingMode), TV readers \(state.httpReaders), разрывов \(state.disconnections), примечание \(state.deliveryNote ?? "нет"), очередь захвата \(Int(state.captureQueueMs)) мс, A/V \(state.avOffsetMs.map { String(Int($0)) } ?? "нет аудио") мс; HTTP: \(state.httpRequests.suffix(3).joined(separator: " | "))")
                        self?.mirrorStatus = "\(state.state). \(state.outputSize), \(state.targetBitrate / 1_000_000) Мбит/с. Кадров: \(state.videoFrames), AAC: \(state.audioPackets). Очередь HTTP: \(state.queuedBytes / 1024) КБ."
                    } catch is CancellationError { return }
                    catch { self?.broadcasting = false; self?.mirrorStatus = "Расширение не отвечает. Если запуск завершился ошибкой, подготовьте трансляцию заново." }
                }
            }
        } catch { fail(error) }
    }
    func stopBroadcast() async {
        broadcasting = false
        monitor?.cancel(); monitor = nil
        if let config = mirrorSession {
            do {
                let req = URLRequest(url: URL(string: "http://127.0.0.1:19192/\(config.token)/stop")!, timeoutInterval: 3)
                _ = try await URLSession.shared.data(for: req)
                mirrorStatus = "Запрос остановки отправлен"
            } catch { mirrorStatus = "Расширение недоступно. Проверьте красный индикатор iOS и остановите запись через него." }
            try? await UPnP.stop(config.tv)
        }
        bridge?.stop(); bridge = nil; mirrorSession = nil; prepared = false
    }
    func scan() async {
        guard !busy, !prepared else { return }
        busy = true; defer { busy = false }
        onlineIDs.removeAll()
        status = "Ищем телевизоры в вашей сети…"
        if let saved = selected {
            do { remember(try await UPnP.describe(saved.location)) }
            catch { onlineIDs.remove(saved.id); note("Сохранённый TV недоступен: \(error.localizedDescription)") }
        }
        do {
            let urls = try await Task.detached { try UPnP.discover() }.value
            await withTaskGroup(of: TV?.self) { group in
                for url in urls.prefix(24) { group.addTask { try? await UPnP.describe(url) } }
                for await tv in group { if let tv { remember(tv) } }
            }
            status = onlineIDs.isEmpty ? "Телевизор не найден. Включите его и проверьте Wi-Fi." : "Телевизор доступен"
        } catch {
            note("Поиск: \(error.localizedDescription)")
            status = onlineIDs.isEmpty ? error.localizedDescription : "Сохранённый телевизор доступен"
        }
    }
    func add(_ url: URL) async {
        guard !busy, !prepared else { return }
        busy = true; defer { busy = false }
        do {
            let tv = try await UPnP.describe(url)
            remember(tv); selected = tv; manualURL = url.absoluteString
            status = "Телевизор сохранён"
            note("Устройство: \(tv.name), \(tv.model)")
        } catch { fail(error) }
    }
    func connect() async {
        guard let tv = selected else { return }
        busy = true; defer { busy = false }
        do {
            let formats = try await UPnP.protocols(tv)
            note("GetProtocolInfo Sink: \(formats)")
            status = "Описание получено. Совместимость потока ещё не проверена."
        } catch { fail(error) }
    }
    func test() async {
        guard let tv = selected, let host = tv.transport.host else { return }
        busy = true; defer { busy = false }
        if activeTV != nil { await stop() }
        poll?.cancel(); server?.stop()
        activeTV = tv
        let http = HTTPServer(allowedHost: host); server = http
        http.onRequest = { [weak self] path in Task { @MainActor in self?.note("HTTP запрос TV: \(path)") } }
        do {
            let base = try await http.start()
            let url = base.appendingPathComponent(live ? "live.m3u8" : "test.ts")
            note("Локальный тест: \(url). Формат \(live ? "HLS live" : "MPEG-TS 12 секунд")")
            try await UPnP.play(tv, url: url, mime: live ? "application/vnd.apple.mpegurl" : "video/mpeg")
            status = "Play принят. Проверьте картинку и тон 440 Гц на телевизоре."
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                        try Task.checkCancellation()
                        let state = try await UPnP.state(tv)
                        self?.note("AVTransport: \(state) (это не подтверждает картинку/звук)")
                    } catch is CancellationError { return }
                    catch { self?.note("Опрос: \(error.localizedDescription)"); return }
                }
            }
        } catch { http.stop(); fail(error) }
    }
    func stop() async {
        poll?.cancel(); server?.stop(); server = nil
        guard let tv = activeTV else { return }
        activeTV = nil
        do { try await UPnP.stop(tv); status = "Тест остановлен" } catch { fail(error) }
    }
    private func fail(_ error: Error) { status = error.localizedDescription; note("Ошибка: \(status)") }
}

