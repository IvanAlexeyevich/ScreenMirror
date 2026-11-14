import Foundation

enum BroadcastExtensionID {
    /// Re-signers may change bundle IDs. Read the actual embedded extension ID
    /// instead of assuming the original build-time suffix survived re-signing.
    static func find(in plugins: URL?) -> String? {
        guard let plugins, let entries = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return nil }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where entry.pathExtension == "appex" {
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("Info.plist")),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let ext = info["NSExtension"] as? [String: Any],
                  ext["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload",
                  let identifier = info["CFBundleIdentifier"] as? String else { continue }
            return identifier
        }
        return nil
    }
}
