import Foundation
import CoreMediaIO
import CoreMedia
import os.log

private let log = Logger(subsystem: VirtualCameraConstants.appBundleID, category: "sink")

/// Pushes finished frames into the camera extension's sink stream using the
/// CoreMediaIO C API. The extension forwards them to Zoom, FaceTime, etc.
final class VirtualCameraSink {
    private let lock = NSLock()
    private var deviceID: CMIODeviceID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var formatDescription: CMVideoFormatDescription?
    private let frameDuration = CMTime(value: 1, timescale: VirtualCameraConstants.frameRate)

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return queue != nil }
    /// Set when the device and sink exist but starting the stream failed,
    /// which is what a stale connection to a replaced extension looks like.
    private(set) var startFailed = false

    /// Returns true when the extension's device is present and its sink stream
    /// accepted us. Safe to call repeatedly.
    @discardableResult
    func connect() -> Bool {
        if isConnected { return true }
        guard let device = Self.findDevice() else { log.info("virtual camera device not found"); return false }
        guard let sink = Self.findSinkStream(device: device) else { log.error("sink stream not found"); return false }

        var unmanaged: Unmanaged<CMSimpleQueue>?
        let copyStatus = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanaged)
        guard copyStatus == noErr, let unmanaged else {
            log.error("CMIOStreamCopyBufferQueue failed (\(copyStatus))"); return false
        }
        let q = unmanaged.takeRetainedValue()
        let startStatus = CMIODeviceStartStream(device, sink)
        guard startStatus == noErr else {
            log.error("CMIODeviceStartStream failed (\(startStatus)) device \(device) stream \(sink)")
            startFailed = true
            return false
        }
        startFailed = false
        lock.lock()
        deviceID = device; streamID = sink; queue = q
        lock.unlock()
        log.info("sink connected: device \(device) stream \(sink) queue capacity \(CMSimpleQueueGetCapacity(q))")
        return true
    }

    func disconnect() {
        lock.lock(); defer { lock.unlock() }
        guard queue != nil else { return }
        CMIODeviceStopStream(deviceID, streamID)
        queue = nil
    }

    /// Enqueue one frame. Drops the frame if the extension is behind.
    func send(_ pixelBuffer: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let queue else { return }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }

        if formatDescription == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            var fd: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fd)
            formatDescription = fd
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(duration: frameDuration,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                              formatDescription: formatDescription, sampleTiming: &timing,
                                                              sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return }
        // The queue takes ownership of one retain; the framework releases it after delivery.
        let enqueue = CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
        if enqueue != noErr {
            Unmanaged.passUnretained(sampleBuffer).release()
            if enqueue != kCMSimpleQueueError_QueueIsFull { log.error("enqueue failed (\(enqueue))") }
        }
    }

    // MARK: CMIO property plumbing

    private static func address(_ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(scope),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func array<T>(_ object: CMIOObjectID, _ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal, of: T.Type) -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(used) / MemoryLayout<T>.stride))
    }

    private static func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ object: CMIOObjectID, _ selector: Int) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, 4, &used, &value) == noErr else { return nil }
        return value
    }

    private static func findDevice() -> CMIODeviceID? {
        let devices = array(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices, of: CMIODeviceID.self)
        let uid = VirtualCameraConstants.deviceUID.uuidString
        return devices.first { string($0, kCMIODevicePropertyDeviceUID) == uid }
            ?? devices.first { string($0, kCMIOObjectPropertyName) == VirtualCameraConstants.deviceName }
    }

    private static func findSinkStream(device: CMIODeviceID) -> CMIOStreamID? {
        var streams = array(device, kCMIODevicePropertyStreams, of: CMIOStreamID.self)
        if streams.isEmpty {
            streams = array(device, kCMIODevicePropertyStreams, scope: kCMIODevicePropertyScopeInput, of: CMIOStreamID.self)
                + array(device, kCMIODevicePropertyStreams, scope: kCMIODevicePropertyScopeOutput, of: CMIOStreamID.self)
        }
        if let byName = streams.first(where: { string($0, kCMIOObjectPropertyName) == VirtualCameraConstants.sinkStreamName }) {
            return byName
        }
        // Direction 0 = host -> device ("output" in CMIO terms), which is the sink.
        return streams.first { uint32($0, kCMIOStreamPropertyDirection) == 0 }
    }
}
