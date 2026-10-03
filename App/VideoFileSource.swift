import AVFoundation
import QuartzCore

/// Plays a movie file as a camera source, looping. Hardware decode via
/// AVPlayer; frames come out as the same 4:2:0 full-range buffers a camera
/// produces, so 4K files exercise the whole pipeline.
final class VideoFileSource {
    var onFrame: ((CVPixelBuffer) -> Void)?
    static let prefix = "video:"
    let url: URL

    private let player = AVPlayer()
    private let output: AVPlayerItemVideoOutput
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "\(VirtualCameraConstants.appBundleID).video", qos: .userInteractive)
    private var endObserver: NSObjectProtocol?

    /// `pixelFormat` defaults to video-range 4:2:0, what the hardware decoder
    /// emits for 8-bit H.264/HEVC, so no per-frame conversion pass. Backgrounds
    /// ask for BGRA so the frame can be sampled directly as a colour texture.
    init(url: URL, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        self.url = url
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        player.isMuted = true
        player.actionAtItemEnd = .none
        Task { [weak self] in
            // Video track only: a muted player still decodes audio otherwise.
            let asset = AVURLAsset(url: url)
            let item: AVPlayerItem
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let duration = try? await asset.load(.duration),
               let transform = try? await track.load(.preferredTransform) {
                let composition = AVMutableComposition()
                let ct = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                try? ct?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                ct?.preferredTransform = transform
                item = AVPlayerItem(asset: composition)
            } else {
                item = AVPlayerItem(url: url)
            }
            await MainActor.run { self?.attach(item) }
        }
    }

    private func attach(_ item: AVPlayerItem) {
        item.add(output)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: nil) { [weak self] _ in
            self?.player.seek(to: .zero)
        }
        if timer != nil { player.play() }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func start() {
        player.play()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        player.pause()
    }

    private func poll() {
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
        onFrame?(pb)
    }
}
