import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(os)
import os
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
import FoundationXML
#endif

struct TV: Identifiable, Hashable, Codable {
    var id: String { udn ?? location.absoluteString }
    var udn: String? = nil
    let name: String
    let model: String
    let location: URL
    let transport: URL
    let transportType: String
    let connection: URL?
    let connectionType: String?
}
struct MirrorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// XMLParser preserves local element names with namespace processing enabled.
final class XMLTree: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        var text = ""
        var children: [Node] = []
        init(_ name: String) { self.name = name }
        func child(_ name: String) -> Node? { children.first { $0.name == name } }
        func value(_ name: String) -> String { child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func all(_ name: String) -> [Node] { children.flatMap { ($0.name == name ? [$0] : []) + $0.all(name) } }
    }
    let root = Node("root")
    var stack: [Node] = []
    static func parse(_ data: Data) throws -> Node {
        let tree = XMLTree(); tree.stack = [tree.root]
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = tree
        guard parser.parse() else { throw parser.parserError ?? MirrorError(message: "Некорректный XML") }
        return tree.root
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let node = Node(name); stack.last?.children.append(node); stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { stack.removeLast() }
}

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
}

enum UPnP {
    #if canImport(os)
    static let log = Logger(subsystem: "org.example.ScreenMirror", category: "UPnP")
    #endif
    static func describe(_ url: URL) async throws -> TV {
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MirrorError(message: "Не удалось получить описание устройства") }
        let root = try XMLTree.parse(data)
        let base = root.all("URLBase").first.flatMap { URL(string: $0.text) } ?? url
        let services = root.all("service")
        guard let av = services.first(where: { $0.value("serviceType").contains(":AVTransport:") }),
              let endpoint = URL(string: av.value("controlURL"), relativeTo: base)?.absoluteURL else {
            throw MirrorError(message: "Устройство не объявляет AVTransport")
        }
        let cm = services.first { $0.value("serviceType").contains(":ConnectionManager:") }
        let device = root.all("device").first
        return TV(udn: device?.value("UDN").isEmpty == false ? device?.value("UDN") : nil, name: device?.value("friendlyName") ?? "TV", model: device?.value("modelName") ?? "", location: url,
                  transport: endpoint, transportType: av.value("serviceType"),
                  connection: cm.flatMap { URL(string: $0.value("controlURL"), relativeTo: base)?.absoluteURL },
                  connectionType: cm?.value("serviceType"))
    }
    static func soap(_ url: URL, type: String, action: String, fields: [(String, String)]) async throws -> XMLTree.Node {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(type)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        let body = fields.map { "<\($0.0)>\(xmlEscape($0.1))</\($0.0)>" }.joined()
        req.httpBody = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(type)\">\(body)</u:\(action)></s:Body></s:Envelope>".data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let root = try XMLTree.parse(data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), root.all("Fault").isEmpty else {
            let detail = root.all("errorDescription").first?.text ?? String(data: data, encoding: .utf8) ?? "SOAP error"
            throw MirrorError(message: "\(action): \(detail)")
        }
        #if canImport(os)
        log.info("SOAP \(action, privacy: .public) OK")
        #endif
        return root
    }
    static func protocols(_ tv: TV) async throws -> String {
        guard let url = tv.connection, let type = tv.connectionType else { return "ConnectionManager не объявлен" }
        let root = try await soap(url, type: type, action: "GetProtocolInfo", fields: [])
        return root.all("Sink").first?.text ?? "Sink отсутствует"
    }
    static func play(_ tv: TV, url: URL, mime: String) async throws {
        let didl = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"1\" parentID=\"0\" restricted=\"1\"><dc:title>Screen Mirror test</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo=\"http-get:*:\(mime):*\">\(xmlEscape(url.absoluteString))</res></item></DIDL-Lite>"
        _ = try await soap(tv.transport, type: tv.transportType, action: "SetAVTransportURI", fields: [("InstanceID", "0"), ("CurrentURI", url.absoluteString), ("CurrentURIMetaData", didl)])
        _ = try await soap(tv.transport, type: tv.transportType, action: "Play", fields: [("InstanceID", "0"), ("Speed", "1")])
    }
    static func stop(_ tv: TV) async throws {
        _ = try await soap(tv.transport, type: tv.transportType, action: "Stop", fields: [("InstanceID", "0")])
    }
    static func state(_ tv: TV) async throws -> String {
        let root = try await soap(tv.transport, type: tv.transportType, action: "GetTransportInfo", fields: [("InstanceID", "0")])
        return root.all("CurrentTransportState").first?.text ?? "UNKNOWN"
    }
    #if canImport(Darwin)
    static func discover() throws -> [URL] {
        var ip: String?, mask: String?
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0 {
            defer { freeifaddrs(list) }
            var cursor = list
            while let item = cursor {
                let entry = item.pointee; cursor = entry.ifa_next
                guard String(cString: entry.ifa_name) == "en0", let addr = entry.ifa_addr,
                      addr.pointee.sa_family == AF_INET, let netmask = entry.ifa_netmask else { continue }
                func numeric(_ p: UnsafePointer<sockaddr>) -> String? {
                    var out = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    guard getnameinfo(p, socklen_t(p.pointee.sa_len), &out, socklen_t(out.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                    return String(cString: out)
                }
                ip = numeric(addr); mask = numeric(netmask)
            }
        }
        guard let ip, let mask else { throw MirrorError(message: "Подключите iPhone к домашней сети Wi-Fi") }
        return try SSDPProbe.search(hosts: SubnetDiscovery.hosts(ip: ip, mask: mask), localIP: ip)
    }
    #endif
}
