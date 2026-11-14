import ReplayKit
import VideoToolbox
import AVFoundation
import CoreImage
import ImageIO
import os

final class MediaPipeline {
    let queue = DispatchQueue(label: "mirror.media", qos: .userInitiated)
    let store = SegmentStore()
    let live = LiveStreamBuffer()
    private let config: SessionConfig
    private var encoder: VTCompressionSession?
    private var routeObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "org.example.ScreenMirror", category: "Media")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private let mux = TransportStream()
    private var startPTS: Int64?
    private var origin: CMTime?
    private var lastVideo: CMTime = .invalid
    private var latestImage: CVPixelBuffer?
    private var lastOrientationDescription = ""
    private var schedule = FrameSchedule()
    private var ticker: DispatchSourceTimer?
    private var networkTicker: DispatchSourceTimer?
    private var pacing: LivePacingController?
    private let cachedStatus = LockedValue(BroadcastStatus(state: "Подготовка", videoFrames: 0, audioPackets: 0, segments: 0, lastError: nil))
    private var lastStatusUpdate: Double = 0
    private var captureQueueMs = 0.0
    private var lastEncodedVideoSeconds: Double?
    private var lastAudioInputAt: Double = 0
    private var paused = false
    private var segmentDiscontinuity = false
    private var pending = 0
    private var converter: AVAudioConverter?
    private var inputAudioFormat: AVAudioFormat?
    private var audioClock: Double?
    private(set) var frames = 0
    private(set) var audioPackets = 0
    private var stopped = false
    private var bitrate: Int
    private var byteCount = 0
    private var firstEncodedAt: Date?
    var onError: ((Error) -> Void)?
    init(_ config: SessionConfig) { self.config = config; bitrate = config.bitrate }
    private func check(_ code: OSStatus, _ operation: String) throws {
        if code != noErr { throw MirrorError(message: "\(operation): OSStatus \(code)") }
    }
    func start() throws {
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.converter = nil; self.inputAudioFormat = nil; self.audioClock = nil
                self.log.info("Audio route changed: AAC converter reset; waiting for ReplayKit format")
            }
        }
        // The hardware requirement key is only available to iOS app extensions
        // from 17.4. Older systems use VideoToolbox's default encoder selection.
        let specification: CFDictionary?
        if #available(iOS 17.4, *) {
            specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
        } else {
            specification = nil
        }
        try check(VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(config.width), height: Int32(config.height), codecType: kCMVideoCodecType_H264, encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { ref, _, status, _, buffer in
            guard let ref else { return }
            let owner = Unmanaged<MediaPipeline>.fromOpaque(ref).takeUnretainedValue()
            owner.queue.async {
                owner.pending = max(0, owner.pending - 1)
                guard !owner.stopped else { return }
                do {
                    try owner.check(status, "H.264 callback")
                    if let buffer { try owner.encoded(buffer) }
                } catch { owner.onError?(error) }
            }
        }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &encoder), "VTCompressionSessionCreate")
        guard let encoder else { throw MirrorError(message: "H.264 encoder отсутствует") }
        for (key, value) in [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as CFTypeRef),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as CFTypeRef),
            (kVTCompressionPropertyKey_ProfileLevel, (config.resolution == "1080p" ? kVTProfileLevel_H264_Main_4_0 : kVTProfileLevel_H264_Main_3_1) as CFTypeRef),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate) as CFTypeRef),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: config.fps) as CFTypeRef),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: config.transport == "ts" ? 1 : 2) as CFTypeRef)
        ] { try check(VTSessionSetProperty(encoder, key: key, value: value), "VT property \(key)") }
        // Optional on hardware encoders: forbid holding extra frames internally.
        // Unsupported properties must not break a previously working encoder.
        let delayResult = VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))
        if delayResult != noErr { log.info("Hardware encoder did not accept MaxFrameDelayCount=0: \(delayResult)") }
        try check(VTCompressionSessionPrepareToEncodeFrames(encoder), "Prepare H.264")
        let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: config.width, kCVPixelBufferHeightKey as String: config.height, kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        try check(CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary, attributes as CFDictionary, &pool), "Pixel pool")
        let ticker = DispatchSource.makeTimerSource(queue: queue)
        ticker.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / config.fps), leeway: .milliseconds(2))
        ticker.setEventHandler { [weak self] in
            guard let self, !self.stopped, !self.paused else { return }
            do { try self.encodeTick() } catch { self.onError?(error) }
        }
        self.ticker = ticker
        ticker.resume()
        if config.transport == "ts", config.steadyStream {
            // Leave headroom for AAC, TS overhead and keyframe bursts. Padding
            // does not reduce the selected encoder bitrate or picture quality.
            pacing = LivePacingController(bitrate: config.bitrate, enabled: true)
            let networkTicker = DispatchSource.makeTimerSource(queue: queue)
            networkTicker.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
            networkTicker.setEventHandler { [weak self] in
                guard let self, !self.stopped, !self.paused else { return }
                for batch in self.pacing?.tick(now: DispatchTime.now().uptimeNanoseconds) ?? [] {
                    self.deliverLive(batch.bytes, startsGOP: batch.startsGOP)
                }
                self.refreshStatus()
            }
            self.networkTicker = networkTicker; networkTicker.resume()
        }
    }
    func process(_ buffer: CMSampleBuffer, type: RPSampleBufferType) {
        // A semaphore bounds queued video work before dispatch; no unlimited buffer backlog.
        guard admission.wait(timeout: .now()) == .success else { return }
        let receivedAt = monotonicSeconds()
        queue.async {
            defer { self.admission.signal() }
            guard !self.stopped, !self.paused else { return }
            self.captureQueueMs = max(0, monotonicSeconds() - receivedAt) * 1000
            do {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
                guard timestamp.isNumeric else { return }
                if self.origin == nil { self.origin = timestamp }
                switch type {
                case .video: try self.video(buffer)
                case .audioApp: if self.config.audio { try self.audio(buffer) }
                default: break
                }
            } catch { self.onError?(error) }
        }
    }
    private let admission = DispatchSemaphore(value: 8)
    private func time(_ timestamp: CMTime) -> Double { max(0, CMTimeGetSeconds(CMTimeSubtract(timestamp, origin ?? timestamp))) }
    private func video(_ buffer: CMSampleBuffer) throws {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        if lastVideo.isValid && CMTimeGetSeconds(CMTimeSubtract(timestamp, lastVideo)) < 1 / Double(config.fps) - 0.001 { return }
        guard !paused, let pool, let image = CMSampleBufferGetImageBuffer(buffer) else { return }
        var target: CVPixelBuffer?
        let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, [kCVPixelBufferPoolAllocationThresholdKey as String: 5] as CFDictionary, &target)
        if allocation == kCVReturnWouldExceedAllocationThreshold { return }
        try check(allocation, "Pixel buffer")
        guard let target else { return }
        let attachment = CMGetAttachment(buffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber
        let orientation = CGImagePropertyOrientation(rawValue: attachment?.uint32Value ?? 1) ?? .up
        var picture = CIImage(cvPixelBuffer: image).oriented(orientation)
        // Device testing reported an upside-down landscape picture. Apply the
        // display correction to the oriented source, before fitting it to the
        // canvas. Testing the 16:9 output canvas would also rotate portrait video.
        let landscape = picture.extent.width > picture.extent.height
        if config.correctLandscapeFlip && landscape {
            picture = picture.oriented(.down)
        }
        let orientationDescription = "ReplayKit EXIF=\(orientation.rawValue), buffer=\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image)), landscape180=\(config.correctLandscapeFlip && landscape)"
        if orientationDescription != lastOrientationDescription {
            log.info("\(orientationDescription, privacy: .public)")
            lastOrientationDescription = orientationDescription
        }
        // Recompute the extent after the correction; its origin can be negative.
        let bounds = picture.extent
        let width = CGFloat(config.width), height = CGFloat(config.height)
        let scale = min(width / bounds.width, height / bounds.height)
        picture = picture.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
            .transformed(by: CGAffineTransform(translationX: (width - bounds.width * scale) / 2, y: (height - bounds.height * scale) / 2))
        let background = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        context.render(picture.composited(over: background), to: target)
        latestImage = target; lastVideo = timestamp
        schedule.update(sampleTime: time(timestamp), arrival: DispatchTime.now().uptimeNanoseconds)
    }
    private func encodeTick() throws {
        guard pending < 3, let encoder, let image = latestImage,
              let frame = schedule.next(now: DispatchTime.now().uptimeNanoseconds, keyInterval: config.transport == "ts" ? 90000 : 171000) else { return }
        let properties: CFDictionary? = frame.forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        let pts = CMTime(value: frame.pts, timescale: 90000)
        pending += 1
        let result = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: Int32(config.fps)), frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil)
        if result != noErr { pending -= 1; try check(result, "Encode frame") }
    }
    func setPaused(_ value: Bool) {
        queue.async {
            self.paused = value
            self.latestImage = nil
            self.lastVideo = .invalid
            self.schedule.reset()
            self.pacing?.discardForSystemPause()
            self.converter?.reset(); self.audioClock = nil
        }
    }
    private func encoded(_ buffer: CMSampleBuffer) throws {
        guard let block = CMSampleBufferGetDataBuffer(buffer), let format = CMSampleBufferGetFormatDescription(buffer) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[String: Any]]
        let key = (attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool) != true
        let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(buffer), timescale: 90000, method: .default).value
        if config.transport == "hls", let start = startPTS, key, pts - start >= 135000 {
            let duration = Double(pts - start) / 90000
            if duration < 3.5 {
                store.append(mux.bytes, duration: duration, discontinuity: segmentDiscontinuity)
                segmentDiscontinuity = false
            } else {
                // Do not publish an oversized segment or change HLS target duration.
                // Restart from this real IDR and explicitly mark the timestamp gap.
                log.warning("Discarding delayed segment, duration \(duration); next segment starts with discontinuity")
                segmentDiscontinuity = true
            }
            startPTS = nil
        }
        if startPTS == nil || (config.transport == "ts" && key) {
            guard key else { return }
            mux.begin(audio: config.audio); startPTS = pts
        }
        var annex = Data([0,0,0,1,0x09,0xf0]) // Access Unit Delimiter
        var nalHeader: Int32 = 4
        if key {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?; var length = 0; var total = 0
                try check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &length, parameterSetCountOut: &total, nalUnitHeaderLengthOut: &nalHeader), "H.264 parameter set")
                if let pointer { annex.append(contentsOf: [0,0,0,1]); annex.append(pointer, count: length) }
            }
        }
        guard nalHeader == 4 else { throw MirrorError(message: "Неожиданный H.264 NAL header") }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { raw in try check(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!), "H.264 bytes") }
        var offset = 0
        while offset + 4 <= data.count {
            let size = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }; offset += 4
            guard size > 0, offset + size <= data.count else { throw MirrorError(message: "Повреждён H.264 NAL") }
            annex.append(contentsOf: [0,0,0,1]); annex.append(data.subdata(in: offset..<(offset + size))); offset += size
        }
        mux.appendVideo(annex, pts: pts, key: key); frames += 1
        lastEncodedVideoSeconds = Double(pts) / 90000
        if firstEncodedAt == nil { firstEncodedAt = Date() }
        if config.transport == "ts" { publishLive(startsGOP: key) }
        refreshStatus()
        if mux.bytes.count > 4_000_000 { throw MirrorError(message: "Сегмент превысил лимит памяти: нет своевременного IDR") }
    }
    private func publishLive(startsGOP: Bool = false) {
        let bytes = mux.drain()
        if let pacing {
            for batch in pacing.enqueue(bytes, startsGOP: startsGOP) {
                deliverLive(batch.bytes, startsGOP: batch.startsGOP)
            }
        } else { deliverLive(bytes, startsGOP: startsGOP) }
    }
    private func deliverLive(_ bytes: Data, startsGOP: Bool) {
        byteCount += bytes.count; live.append(bytes, startsGOP: startsGOP)
        refreshStatus()
    }
    private func audio(_ buffer: CMSampleBuffer) throws {
        lastAudioInputAt = monotonicSeconds()
        guard let desc = CMSampleBufferGetFormatDescription(buffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        if converter == nil || inputAudioFormat != format {
            let output = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000])!
            guard let created = AVAudioConverter(from: format, to: output) else { throw MirrorError(message: "AAC converter недоступен") }
            created.bitRate = 128000; converter = created; inputAudioFormat = format; audioClock = nil
        }
        guard let converter else { return }
        let count = CMSampleBufferGetNumSamples(buffer)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        try check(CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList), "ReplayKit PCM")
        let sourceTime = time(CMSampleBufferGetPresentationTimeStamp(buffer))
        if audioClock == nil || abs((audioClock ?? sourceTime) - sourceTime) > 0.25 { converter.reset(); audioClock = sourceTime }
        var supplied = false
        let output = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 8, maximumPacketSize: max(2048, converter.maximumOutputPacketSize))
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return pcm
            }
            if let error { throw error }
            if let descriptions = output.packetDescriptions {
                for index in 0..<Int(output.packetCount) {
                    let d = descriptions[index]; let size = Int(d.mDataByteSize)
                    let aac = Data(bytes: output.data.advanced(by: Int(d.mStartOffset)), count: size)
                    let length = size + 7
                    let adts: [UInt8] = [0xff,0xf1,0x4c,0x80 | UInt8((length >> 11) & 3),UInt8((length >> 3) & 255),UInt8((length & 7) << 5) | 0x1f,0xfc]
                    let pts = Int64((audioClock ?? sourceTime) * 90000)
                    if startPTS != nil {
                        mux.appendAudio(Data(adts) + aac, pts: pts); audioPackets += 1
                        if config.transport == "ts" { publishLive() }
                    }
                    audioClock = (audioClock ?? sourceTime) + 1024.0 / 48000
                }
            }
            if status == .error { throw MirrorError(message: "AAC conversion failed") }
            if status != .haveData || output.packetCount == 0 { break }
        }
    }
    private func refreshStatus() {
        let now = monotonicSeconds()
        guard now - lastStatusUpdate >= 0.5 else { return }
        lastStatusUpdate = now
        var status = BroadcastStatus(state: "Захват активен; воспроизведение TV проверьте визуально", videoFrames: frames, audioPackets: audioPackets, segments: store.count, lastError: nil)
        status.outputSize = "\(config.width)×\(config.height)"
        status.targetBitrate = bitrate; status.pacingBytes = pacing?.queuedBytes ?? 0
        status.pacingMode = pacing?.mode.rawValue ?? "direct"
        status.deliveryNote = pacing?.fallbackReason
        status.captureQueueMs = captureQueueMs
        if now - lastAudioInputAt < 1, let audioClock, let video = lastEncodedVideoSeconds { status.avOffsetMs = (audioClock - video) * 1000 }
        if let firstEncodedAt { status.actualMbps = Double(byteCount) * 8 / max(0.1, Date().timeIntervalSince(firstEncodedAt)) / 1_000_000 }
        cachedStatus.set(status)
    }
    // HTTP request handling must never block the live sender waiting on Core Image.
    func snapshot() -> BroadcastStatus { cachedStatus.get() }
    deinit {
        ticker?.cancel(); networkTicker?.cancel()
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        if let encoder { VTCompressionSessionInvalidate(encoder) }
    }
    func stop() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver); self.routeObserver = nil }
        queue.sync {
            stopped = true
            ticker?.setEventHandler {}; ticker?.cancel(); ticker = nil
            networkTicker?.setEventHandler {}; networkTicker?.cancel(); networkTicker = nil; pacing = nil
            latestImage = nil
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil; converter = nil
        }
    }
}
