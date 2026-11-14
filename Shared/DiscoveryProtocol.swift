import Foundation

enum SSDPMessage {
    static func search(target: String = "urn:schemas-upnp-org:device:MediaRenderer:1") -> String {
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n"
    }
    static func location(_ response: String) -> URL? {
        for line in response.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "location" else { continue }
            let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { continue }
            return url
        }
        return nil
    }
}
enum SubnetDiscovery {
    static func number(_ text: String) -> UInt32? {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return nil }
        var result: UInt32 = 0
        for field in fields { guard let byte = UInt8(field) else { return nil }; result = result << 8 | UInt32(byte) }
        return result
    }
    static func address(_ value: UInt32) -> String {
        [24,16,8,0].map { String((value >> $0) & 255) }.joined(separator: ".")
    }
    // Bound discovery to at most the local /24; never scan a huge routed network.
    static func hosts(ip: String, mask: String) -> [String] {
        guard let ip = number(ip), let original = number(mask) else { return [] }
        let inverse = ~original
        guard inverse & (inverse &+ 1) == 0, original != 0 else { return [] }
        let mask = original | 0xffffff00
        let network = ip & mask, broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        return ((network + 1)..<broadcast).filter { $0 != ip }.map(address)
    }
}
