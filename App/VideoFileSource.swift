import AVFoundation
import QuartzCore

/// Plays a movie file, looping, with hardware decode via AVPlayer. As a
/// camera source it pushes frames through `onFrame` from a timer at the
/// movie's frame rate (4:2:0 buffers like a camera's, so 4K files exercise
/// the whole pipeline). As a layer it is pulled instead: `pull()` returns the
/// frame for now, called once per rendered frame, so there is no timer at all.
final class VideoFileSource {
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called once the track loads: true when its display matrix flips it
    /// horizontally. Decoded frames come out unflipped, so the renderer mirrors them.
    var onMirrored: ((Bool) -> Void)?
    static let prefix = "video:"
    let url: URL

    private let player = AVPlayer()
    private let output: AVPlayerItemVideoOutput
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "\(VirtualCameraConstants.appBundleID).video", qos: .userInteractive)
    private var endObserver: NSObjectProtocol?
    /// Seconds per frame of the movie, once the track has loaded; 1/30 until then.
    private var frameInterval: Double = 1.0 / 30
    private var playing = false
    private var pushing = false

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
                if let rate = try? await track.load(.nominalFrameRate), rate > 1 {
                    await MainActor.run { self?.frameInterval = 1.0 / Double(rate) }
                }
                let composition = AVMutableComposition()
                let ct = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                try? ct?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                ct?.preferredTransform = transform
                item = AVPlayerItem(asset: composition)
                let mirrored = transform.a * transform.d - transform.b * transform.c < 0
                await MainActor.run { self?.onMirrored?(mirrored) }
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
        if playing { player.play() }
        if pushing { schedulePush() }   // the rate is known now
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// Push mode: play and deliver each new frame through `onFrame`.
    func start() {
        playing = true
        pushing = true
        player.play()
        schedulePush()
    }

    /// Pull mode: play, and hand out frames from `pull()` as they are asked for.
    func play() {
        playing = true
        player.play()
    }

    func stop() {
        playing = false
        pushing = false
        timer?.cancel()
        timer = nil
        player.pause()
    }

    /// The timer checks twice per movie frame, so no frame is missed and no
    /// frame is delivered twice, at a quarter of the wakeups of a fixed fast poll.
    private func schedulePush() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let half = max(frameInterval / 2, 0.008)
        t.schedule(deadline: .now(), repeating: half, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self, let pb = pull() else { return }
            onFrame?(pb)
        }
        t.resume()
        timer = t
    }

    /// The newest frame for this moment, or nil when the one before is still current.
    func pull() -> CVPixelBuffer? {
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        return output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    }
}
