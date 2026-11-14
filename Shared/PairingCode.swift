import Foundation

enum PairingCode {
    static func url(from text: String) -> URL? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        if parts.scheme == "screenmirror", parts.host == "pair",
           let value = parts.queryItems?.first(where: { $0.name == "url" })?.value { return valid(value) }
        return valid(text)
    }
    private static func valid(_ text: String) -> URL? {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
