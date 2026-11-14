import Foundation

struct SessionConfig: Codable {
    let tv: TV
    var fps = 30
    var bitrate = 6_000_000
    var resolution = "720p"
    var width: Int { resolution == "1080p" ? 1920 : 1280 }
    var height: Int { resolution == "1080p" ? 1080 : 720 }
    var audio = true
    var reconnect = true
    var transport = "ts"
    var correctLandscapeFlip = true
    var steadyStream = true
    var token = UUID().uuidString
}
struct BroadcastStatus: Codable {
    var state: String
    var videoFrames: Int
    var audioPackets: Int
    var segments: Int
    var lastError: String?
    var httpRequests: [String] = []
    var outputSize = ""
    var targetBitrate = 0
    var actualMbps = 0.0
    var queuedBytes = 0
    var pacingBytes = 0
    var pacingMode = "direct"
    var deliveryNote: String? = nil
    var httpReaders = 0
    var disconnections = 0
    var captureQueueMs = 0.0
    var avOffsetMs: Double? = nil
}
