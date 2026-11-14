import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum SSDPProbe {
    static func search(hosts: [String], port: UInt16 = 1900, localIP: String? = nil,
                       timeout: TimeInterval = 4, multicast: Bool = true) throws -> [URL] {
        #if canImport(Darwin)
        let kind = SOCK_DGRAM
        #else
        let kind = Int32(SOCK_DGRAM.rawValue)
        #endif
        let fd = socket(AF_INET, kind, Int32(IPPROTO_UDP))
        guard fd >= 0 else { throw MirrorError(message: "Не удалось открыть поиск устройств: \(errno)") }
        defer { close(fd) }
        var receiveBuffer: Int32 = 512 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout.size(ofValue: receiveBuffer)))
        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout.size(ofValue: receiveTimeout)))
        func address(_ ip: String, _ port: UInt16) -> sockaddr_in {
            var value = sockaddr_in(); value.sin_family = sa_family_t(AF_INET); value.sin_port = port.bigEndian
            #if canImport(Darwin)
            value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            inet_pton(AF_INET, ip, &value.sin_addr); return value
        }
        if let localIP {
            var local = address(localIP, 0)
            let result = withUnsafePointer(to: &local) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard result == 0 else { throw MirrorError(message: "Не удалось использовать Wi-Fi: \(errno)") }
        }
        func send(_ host: String, multicast: Bool) -> Bool {
            var endpoint = address(host, port)
            var text = SSDPMessage.search(target: multicast ? "urn:schemas-upnp-org:device:MediaRenderer:1" : "ssdp:all")
            if !multicast { text = text.replacingOccurrences(of: "HOST: 239.255.255.250:1900", with: "HOST: \(host):\(port)") }
            return text.withCString { ptr in withUnsafePointer(to: &endpoint) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, ptr, strlen(ptr), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) >= 0 }
            } }
        }
        var successful = multicast && send("239.255.255.250", multicast: true) ? 1 : 0
        for host in hosts.prefix(254) { if send(host, multicast: false) { successful += 1 }; usleep(1500) }
        guard successful > 0 else { throw MirrorError(message: "Поиск заблокирован. Разрешите доступ к локальной сети в настройках iPhone.") }
        var locations = Set<URL>(); let until = Date().addingTimeInterval(max(0.1, min(timeout, 10)))
        while Date() < until {
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = recv(fd, &bytes, bytes.count, 0)
            if count > 0, let url = SSDPMessage.location(String(decoding: bytes.prefix(count), as: UTF8.self)) { locations.insert(url) }
        }
        return Array(locations)
    }
}
