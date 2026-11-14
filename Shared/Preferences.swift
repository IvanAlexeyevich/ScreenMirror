import Foundation

struct VideoPreferences: Codable, Equatable {
    var fps = 30
    var bitrate = 6_000_000
    var resolution = "720p"
    var audio = true
    var reconnect = true
    var transport = "ts"
    var correctLandscapeFlip = true
    var steadyStream = true
    mutating func validate() {
        if ![15, 30].contains(fps) { fps = 30 }
        if ![2,3,4,6,8,12].map({ $0 * 1_000_000 }).contains(bitrate) { bitrate = 6_000_000 }
        if !["720p", "1080p"].contains(resolution) { resolution = "720p" }
        if !["ts", "hls"].contains(transport) { transport = "ts" }
    }
}
extension VideoPreferences {
    private enum CodingKeys: String, CodingKey {
        case fps, bitrate, resolution, audio, reconnect, transport, correctLandscapeFlip, steadyStream
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fps = try values.decodeIfPresent(Int.self, forKey: .fps) ?? fps
        bitrate = try values.decodeIfPresent(Int.self, forKey: .bitrate) ?? bitrate
        resolution = try values.decodeIfPresent(String.self, forKey: .resolution) ?? resolution
        audio = try values.decodeIfPresent(Bool.self, forKey: .audio) ?? audio
        reconnect = try values.decodeIfPresent(Bool.self, forKey: .reconnect) ?? reconnect
        transport = try values.decodeIfPresent(String.self, forKey: .transport) ?? transport
        correctLandscapeFlip = try values.decodeIfPresent(Bool.self, forKey: .correctLandscapeFlip) ?? correctLandscapeFlip
        steadyStream = try values.decodeIfPresent(Bool.self, forKey: .steadyStream) ?? steadyStream
        validate()
    }
}
struct SavedPreferences: Codable {
    var version = 1
    var video = VideoPreferences()
    var devices: [TV] = []
    var selectedID: String?
    var manualURL = ""
}
/// One atomic JSON file survives app restarts and installing over the same bundle.
/// Uses no App Group and no account. Corrupt data is preserved for diagnostics.
final class PreferenceStore {
    let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenMirror", isDirectory: true).appendingPathComponent("preferences.json")
    }
    func load() throws -> SavedPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedPreferences() }
        var value = try JSONDecoder().decode(SavedPreferences.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw MirrorError(message: "Неизвестная версия сохранённых настроек") }
        value.video.validate()
        return value
    }
    func save(_ value: SavedPreferences) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
