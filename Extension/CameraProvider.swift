import Foundation
import CoreMediaIO
import CoreVideo
import IOKit.audio
import os.log

let log = Logger(subsystem: VirtualCameraConstants.extensionBundleID, category: "camera")

@inline(__always) func hostTimeNanoseconds() -> UInt64 {
    UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
}

// MARK: - Provider

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: VirtualCameraConstants.deviceName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        log.info("client connected: \(client.signingID ?? "?", privacy: .public)")
    }

    func disconnect(from client: CMIOExtensionClient) {
        log.info("client disconnected: \(client.signingID ?? "?", privacy: .public)")
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer, .providerName]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "Artifact" }
        if properties.contains(.providerName) { p.name = "Silhouette" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Device

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: SourceStreamSource!
    private var sinkStream: SinkStreamSource!

    private let formatDescription: CMFormatDescription
    private let frameDuration = CMTime(value: 1, timescale: VirtualCameraConstants.frameRate)

    private let lock = NSLock()
    private var sourceStreamingCount = 0
    private var lastSinkFrameTime: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "\(VirtualCameraConstants.extensionBundleID).placeholder", qos: .userInteractive)
    private var placeholder: CVPixelBuffer?

    init(localizedName: String) {
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(VirtualCameraConstants.width),
                                       height: Int32(VirtualCameraConstants.height),
                                       extensions: nil,
                                       formatDescriptionOut: &fd)
        formatDescription = fd!
        super.init()

        device = CMIOExtensionDevice(localizedName: localizedName,
                                     deviceID: VirtualCameraConstants.deviceUID,
                                     legacyDeviceID: VirtualCameraConstants.deviceUID.uuidString,
                                     source: self)

        let format = CMIOExtensionStreamFormat(formatDescription: formatDescription,
                                               maxFrameDuration: frameDuration,
                                               minFrameDuration: frameDuration,
                                               validFrameDurations: nil)
        sourceStream = SourceStreamSource(localizedName: VirtualCameraConstants.sourceStreamName,
                                          streamID: VirtualCameraConstants.sourceStreamID,
                                          format: format, device: self)
        sinkStream = SinkStreamSource(localizedName: VirtualCameraConstants.sinkStreamName,
                                      streamID: VirtualCameraConstants.sinkStreamID,
                                      format: format, device: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error.localizedDescription)")
        }
        placeholder = Self.makePlaceholder()
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = "Silhouette Virtual Camera" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Source stream lifecycle

    func sourceDidStart() {
        lock.lock(); defer { lock.unlock() }
        sourceStreamingCount += 1
        guard sourceStreamingCount == 1 else { return }
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(Int(1000 / VirtualCameraConstants.frameRate)), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.timerTick() }
        t.resume()
        timer = t
        log.info("source stream started")
    }

    func sourceDidStop() {
        lock.lock(); defer { lock.unlock() }
        sourceStreamingCount = max(0, sourceStreamingCount - 1)
        guard sourceStreamingCount == 0 else { return }
        timer?.cancel()
        timer = nil
        log.info("source stream stopped")
    }

    /// Runs at the nominal frame rate. If the app has not delivered a frame
    /// recently, emit the placeholder so clients still see a live stream.
    private func timerTick() {
        let now = hostTimeNanoseconds()
        lock.lock()
        let stale = now &- lastSinkFrameTime > 500_000_000
        lock.unlock()
        guard stale, let placeholder else { return }
        var timing = CMSampleTimingInfo(duration: frameDuration,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: placeholder,
                                                 formatDescription: formatDescription,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sbuf)
        if let sbuf {
            sourceStream.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: now)
        }
    }

    // MARK: Sink → source

    /// Forward a frame the app pushed into the sink stream to every client of
    /// the source stream.
    func forward(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        lastSinkFrameTime = hostTimeNanoseconds()
        let streaming = sourceStreamingCount > 0
        lock.unlock()
        guard streaming else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        sourceStream.stream.send(sampleBuffer, discontinuity: [],
                                 hostTimeInNanoseconds: UInt64(pts.seconds * Double(NSEC_PER_SEC)))
    }

    private static func makePlaceholder() -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: VirtualCameraConstants.width,
            kCVPixelBufferHeightKey: VirtualCameraConstants.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, VirtualCameraConstants.width, VirtualCameraConstants.height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let height = CVPixelBufferGetHeight(pb)
            let width = CVPixelBufferGetWidth(pb)
            for y in 0..<height {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt32.self)
                for x in 0..<width { row[x] = 0xFF1C1C1C }  // opaque dark gray, BGRA
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}

// MARK: - Source stream (what Zoom / FaceTime read)

final class SourceStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: DeviceSource
    private var activeFormatIndex = 0

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: VirtualCameraConstants.frameRate)
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex { activeFormatIndex = index }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { device.sourceDidStart() }

    func stopStream() throws { device.sourceDidStop() }
}

// MARK: - Sink stream (what the Silhouette app writes into)

final class SinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: DeviceSource
    private var client: CMIOExtensionClient?
    private var streaming = false

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration,
         .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
         .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: VirtualCameraConstants.frameRate)
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            p.setPropertyState(CMIOExtensionPropertyState(value: NSNumber(value: 4)), forProperty: .streamSinkBufferQueueSize)
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            p.setPropertyState(CMIOExtensionPropertyState(value: NSNumber(value: 1)), forProperty: .streamSinkBuffersRequiredForStartup)
        }
        if properties.contains(.streamSinkBufferUnderrunCount) {
            p.setPropertyState(CMIOExtensionPropertyState(value: NSNumber(value: 0)), forProperty: .streamSinkBufferUnderrunCount)
        }
        if properties.contains(.streamSinkEndOfData) {
            p.setPropertyState(CMIOExtensionPropertyState(value: NSNumber(value: false)), forProperty: .streamSinkEndOfData)
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    /// The sink is open to any local process. CMIOExtensionClient.signingID
    /// reports "unknown" for Developer ID apps on current macOS, so it cannot
    /// gate access.
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        log.info("sink client connected, pid \(client.pid)")
        self.client = client
        return true
    }

    func startStream() throws {
        streaming = true
        log.info("sink stream started")
        consumeNext()
    }

    func stopStream() throws {
        streaming = false
        client = nil
        log.info("sink stream stopped")
    }

    private func consumeNext() {
        guard streaming, let client else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, error in
            guard let self else { return }
            if let sampleBuffer {
                self.device.forward(sampleBuffer)
                self.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber,
                                                 hostTimeInNanoseconds: hostTimeNanoseconds()))
                self.consumeNext()
            } else if self.streaming {
                if let error { log.error("consume failed: \(error.localizedDescription, privacy: .public)") }
                // Avoid a hot loop if the framework reports an empty queue.
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                    self?.consumeNext()
                }
            }
        }
    }
}
