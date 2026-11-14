import Foundation
import Network
import Darwin

final class HTTPServer {
    private let queue = DispatchQueue(label: "mirror.http")
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var started = Date()
    private let token: String
    private let port: NWEndpoint.Port
    private let loopbackOnly: Bool
    var resource: ((String) -> (Data, String)?)?
    typealias StreamSubscription = (@escaping (Data) -> Void) -> UUID
    var subscribeStream: StreamSubscription?
    var unsubscribeStream: ((UUID) -> Void)?
    private var subscriptions: [UUID: UUID] = [:]
    private var queuedBytes: [UUID: Int] = [:]
    var streamQueueByteLimit = 2_000_000
    // Read only from the HTTP queue (e.g. in resource callback).
    var streamQueuedBytes: Int { queuedBytes.values.max() ?? 0 }
    var lastRequest = Date()
    var onRequest: ((String) -> Void)?
    private let allowedHost: String
    init(allowedHost: String, port: UInt16 = 0, token: String = UUID().uuidString, loopbackOnly: Bool = false) {
        self.allowedHost = allowedHost; self.port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        self.token = token; self.loopbackOnly = loopbackOnly
    }
    func start() async throws -> URL {
        let listener = try NWListener(using: .tcp, on: port)
        self.listener = listener
        started = Date()
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    guard let ip = (self.loopbackOnly ? "127.0.0.1" : Self.localIP()), let port = listener.port,
                          let url = URL(string: "http://\(ip):\(port.rawValue)/\(self.token)/") else {
                        listener.cancel(); continuation.resume(throwing: MirrorError(message: "Нет IPv4 адреса Wi-Fi")); return
                    }
                    continuation.resume(returning: url)
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                // Serve only the selected renderer, without exposing files to the whole LAN.
                guard case .hostPort(let host, _) = connection.endpoint,
                      (host.debugDescription == "127.0.0.1" || (!self.loopbackOnly && host.debugDescription == self.allowedHost)), self.clients.count < 8 else { connection.cancel(); return }
                let id = UUID(); self.clients[id] = connection
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let self, let connection else { return }
                    switch state { case .failed, .cancelled: self.close(connection, id); default: break }
                }
                connection.start(queue: self.queue)
                self.receive(connection, id: id, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            for id in Array(self.clients.keys) {
                if let connection = self.clients[id] { self.close(connection, id) }
            }
        }
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var all = buffer; all.append(data ?? Data())
            if all.count > 16384 { self.close(connection, id); return }
            if all.range(of: Data("\r\n\r\n".utf8)) != nil { self.respond(connection, id: id, request: String(decoding: all, as: UTF8.self)); return }
            if complete || error != nil { self.close(connection, id); return }
            self.receive(connection, id: id, buffer: all)
        }
    }
    private func close(_ connection: NWConnection, _ id: UUID) {
        guard clients.removeValue(forKey: id) != nil else { return }
        if let subscription = subscriptions.removeValue(forKey: id) { unsubscribeStream?(subscription) }
        queuedBytes.removeValue(forKey: id)
        connection.cancel()
    }
    private func stream(_ connection: NWConnection, id: UUID, head: Bool) {
        let header = Data("HTTP/1.1 200 OK\r\nContent-Type: video/mpeg\r\nCache-Control: no-store\r\nConnection: close\r\nAccept-Ranges: none\r\ntransferMode.dlna.org: Streaming\r\ncontentFeatures.dlna.org: DLNA.ORG_OP=00;DLNA.ORG_CI=0\r\n\r\n".utf8)
        // Close-delimited HTTP entity: no invented Content-Length, no chunk bytes
        // inside MPEG-TS. The connection remains open until Stop/disconnect.
        connection.send(content: header, completion: .contentProcessed { error in
            if error != nil || head { self.close(connection, id) }
        })
        guard !head, let subscribeStream else { return }
        queuedBytes[id] = 0
        let subscription = subscribeStream { [weak self, weak connection] bytes in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.clients[id] != nil else { return }
                let queued = self.queuedBytes[id, default: 0] + bytes.count
                guard queued <= self.streamQueueByteLimit else {
                    self.onRequest?("stream: slow reader disconnected (queue limit)")
                    self.close(connection, id); return
                }
                self.queuedBytes[id] = queued
                connection.send(content: bytes, completion: .contentProcessed { error in
                    guard self.clients[id] != nil else { return }
                    self.queuedBytes[id] = max(0, self.queuedBytes[id, default: 0] - bytes.count)
                    if error != nil { self.close(connection, id) }
                })
            }
        }
        subscriptions[id] = subscription
    }
    private func respond(_ connection: NWConnection, id: UUID, request: String) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, ["GET", "HEAD"].contains(String(parts[0])) else { send(connection, id, status: "405 Method Not Allowed", data: Data()); return }
        let path = String(parts[1]).components(separatedBy: "?")[0]
        let prefix = "/\(token)/"
        guard path.hasPrefix(prefix) else { send(connection, id, status: "404 Not Found", data: Data()); return }
        let name = String(path.dropFirst(prefix.count))
        lastRequest = Date()
        let rangeDescription = lines.first(where: { $0.lowercased().hasPrefix("range:") }) ?? "Range: none"
        onRequest?("\(parts[0]) \(name); \(rangeDescription)")
        if name == "screen.ts", subscribeStream != nil {
            if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
               range.dropFirst(6).trimmingCharacters(in: .whitespaces) != "bytes=0-" {
                send(connection, id, status: "416 Range Not Satisfiable", data: Data()); return
            }
            stream(connection, id: id, head: parts[0] == "HEAD"); return
        }
        var data: Data; let mime: String
        if let resource = resource {
            guard let result = resource(name) else { send(connection, id, status: "404 Not Found", data: Data()); return }
            data = result.0; mime = result.1
        } else if name == "live.m3u8" {
            // Four-segment sliding window. Each cycle explicitly starts a new TS timestamp period.
            let last = max(3, Int(Date().timeIntervalSince(started) / 2))
            let first = last - 3
            var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:\(first)\n#EXT-X-DISCONTINUITY-SEQUENCE:\(first / 6)\n"
            for index in first...last {
                if index > first && index % 6 == 0 { playlist += "#EXT-X-DISCONTINUITY\n" }
                playlist += "#EXTINF:2.000,\nsegment\(index).ts\n"
            }
            data = Data(playlist.utf8); mime = "application/vnd.apple.mpegurl"
        } else {
            let resource: String
            if name == "test.ts" { resource = "test" }
            else if name.hasPrefix("segment"), name.hasSuffix(".ts"), let index = Int(name.dropFirst(7).dropLast(3)), index >= 0 {
                resource = String(format: "segment%02d", index % 6)
            } else { send(connection, id, status: "404 Not Found", data: Data()); return }
            guard let url = Bundle.main.url(forResource: resource, withExtension: "ts"), let bytes = try? Data(contentsOf: url) else {
                send(connection, id, status: "404 Not Found", data: Data()); return
            }
            data = bytes; mime = "video/mpeg"
        }
        let total = data.count
        var headers = ["Content-Type": mime, "Cache-Control": "no-store", "Accept-Ranges": "bytes", "transferMode.dlna.org": "Streaming"]
        var status = "200 OK"
        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let value = rangeLine.dropFirst(6).trimmingCharacters(in: .whitespaces)
            let bounds = value.hasPrefix("bytes=") ? String(value.dropFirst(6)).split(separator: "-", omittingEmptySubsequences: false) : []
            var low = 0; var high = total - 1
            if bounds.count == 2, !value.contains(",") {
                if bounds[0].isEmpty, let suffix = Int(bounds[1]), suffix > 0 { low = max(0, total - suffix) }
                else if let start = Int(bounds[0]) { low = start; if !bounds[1].isEmpty { high = Int(bounds[1]) ?? -1 } }
                else { low = -1 }
            } else { low = -1 }
            guard low >= 0, low < total, high >= low else {
                send(connection, id, status: "416 Range Not Satisfiable", data: Data(), headers: ["Content-Range": "bytes */\(total)"]); return
            }
            high = min(high, total - 1)
            data = data.subdata(in: low..<(high + 1)); status = "206 Partial Content"
            headers["Content-Range"] = "bytes \(low)-\(high)/\(total)"
        }
        headers["Content-Length"] = String(data.count)
        send(connection, id, status: status, data: parts[0] == "HEAD" ? Data() : data, headers: headers)
    }
    private func send(_ connection: NWConnection, _ id: UUID, status: String, data: Data, headers: [String: String] = [:]) {
        var fields = headers
        if fields["Content-Length"] == nil { fields["Content-Length"] = String(data.count) }
        fields["Connection"] = "close"
        var response = Data(("HTTP/1.1 \(status)\r\n" + fields.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n").utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in self.close(connection, id) })
    }
    static func localIP() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }; defer { freeifaddrs(list) }
        var cursor = list
        while let item = cursor {
            let value = item.pointee; cursor = value.ifa_next
            guard String(cString: value.ifa_name) == "en0", let address = value.ifa_addr, address.pointee.sa_family == AF_INET else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }
}
