import AVFoundation

/// Physical camera capture. Frames arrive as 4:2:0 bi-planar full-range
/// YCbCr, which the shader keys directly.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?
    private(set) var currentDevice: AVCaptureDevice?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private let queue = DispatchQueue(label: "\(VirtualCameraConstants.appBundleID).camera", qos: .userInteractive)
    private lazy var testPattern: TestPatternSource = {
        let t = TestPatternSource()
        t.onFrame = { [weak self] pb in self?.onFrame?(pb) }
        return t
    }()
    /// True while the synthetic test pattern is the active source.
    private(set) var usingTestPattern = false
    private var video: VideoFileSource?
    /// The movie file currently used as the source, if any.
    var currentVideoURL: URL? { video?.url }
    /// Capture at 4K when the device offers it (for supersampled keying).
    var preferHighResolution = false

    static func availableDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
            .devices
            .filter { !$0.uniqueID.contains(VirtualCameraConstants.deviceUID.uuidString)
                      && $0.localizedName != VirtualCameraConstants.deviceName }
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { completion(ok) } }
        default: completion(false)
        }
    }

    func startTestPattern() {
        usingTestPattern = true
        currentDevice = nil
        stopVideo()
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
        testPattern.start()
    }

    func startVideo(url: URL) {
        usingTestPattern = false
        testPattern.stop()
        currentDevice = nil
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
        stopVideo()
        let v = VideoFileSource(url: url)
        v.onFrame = { [weak self] pb in self?.onFrame?(pb) }
        video = v
        v.start()
    }

    private func stopVideo() {
        video?.stop()
        video = nil
    }

    func start(device: AVCaptureDevice) {
        usingTestPattern = false
        testPattern.stop()
        stopVideo()
        queue.async { [self] in
            session.beginConfiguration()
            if let input { session.removeInput(input) }
            guard let newInput = try? AVCaptureDeviceInput(device: device), session.canAddInput(newInput) else {
                session.commitConfiguration(); return
            }
            session.addInput(newInput)
            input = newInput
            currentDevice = device
            if preferHighResolution && session.canSetSessionPreset(.hd4K3840x2160) {
                session.sessionPreset = .hd4K3840x2160
            } else {
                session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
            }

            if !session.outputs.contains(output) {
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            // availableVideoPixelFormatTypes is ordered most efficient first; take the
            // first 4:2:0 bi-planar one so AVFoundation does no extra conversion.
            let planar: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            let format = output.availableVideoPixelFormatTypes.first { planar.contains($0) } ?? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        testPattern.stop()
        stopVideo()
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
