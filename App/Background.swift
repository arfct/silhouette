import AppKit
import MetalKit
import WebKit

enum BackgroundMode: Int, Codable { case none = 0, image, web, color }

/// Which composited layer a controller feeds: behind the keyed camera, or over it.
enum LayerSlot { case background, foreground }

/// Supplies the background texture: a still image loaded once, or a web page
/// snapshotted a few times per second. Keying itself always runs at camera rate.
final class BackgroundController: NSObject {
    let webView: WKWebView
    private(set) var mode: BackgroundMode = .none
    private(set) var imageURL: URL?
    private(set) var webURL: URL?
    var onError: ((String) -> Void)?

    private unowned let renderer: Renderer
    let slot: LayerSlot
    private let loader: MTKTextureLoader
    private let textureQueue = DispatchQueue(label: "\(VirtualCameraConstants.appBundleID).background", qos: .utility)
    private var snapshotTimer: Timer?
    private var snapshotInFlight = false
    private var snapshotWidth = CGFloat(VirtualCameraConstants.width)
    static let snapshotsPerSecond: TimeInterval = 15
    static let idleSnapshotsPerSecond: TimeInterval = 3
    private var lastSignature: [UInt32] = []
    private var unchangedCount = 0
    private var uploadTextures: [MTLTexture] = []
    private var uploadIndex = 0
    private var videoSource: VideoFileSource?
    private var videoTextureCache: CVMetalTextureCache?
    private var videoTextures: [CVMetalTexture] = []   // keep the frame alive while sampled
    /// Bundled demo page, shown when Web mode has no URL.
    static let demoPageURL = Bundle.main.url(forResource: "face", withExtension: "html")
    private let encoder = JSONEncoder()

    private var textureOptions: [MTKTextureLoader.Option: Any] {
        [.SRGB: false,
         .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
         .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)]
    }

    init(renderer: Renderer, slot: LayerSlot = .background) {
        self.renderer = renderer
        self.slot = slot
        loader = MTKTextureLoader(device: renderer.device)
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(source: "window.__silhouetteMirrored = true;", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(WKUserScript(source: Self.obsBridge, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: VirtualCameraConstants.width,
                                          height: VirtualCameraConstants.height), configuration: config)
        webView.isHidden = true
        // Pages written for OBS browser sources sniff the user agent for "OBS".
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        webView.customUserAgent = (WKWebView().value(forKey: "userAgent") as? String ?? "Mozilla/5.0 (Macintosh)") + " OBS/\(Self.obsPluginVersion) Silhouette/\(version)"
        // No default white page background: a page covers only what it draws, so
        // the same page can serve as a foreground. Pages set their own background.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        super.init()
    }

    /// window.silhouette: pages subscribe with silhouette.on('face', fn) and
    /// silhouette.on('mirror', fn). `mirrored` says whether Silhouette's preview is
    /// mirrored, mirrored to <html class="silhouette-mirrored"> for CSS.
    private static let bridge = """
    (function(){ if (window.silhouette) return;
      const L = {};
      const apply = m => document.documentElement && document.documentElement.classList.toggle('silhouette-mirrored', m);
      window.silhouette = {
        face: null,
        mirrored: !!window.__silhouetteMirrored,
        on(evt, cb) { (L[evt] ||= []).push(cb); },
        _update(f) { this.face = f; (L.face || []).forEach(cb => cb(f)); },
        _setMirrored(m) { this.mirrored = m; apply(m); (L.mirror || []).forEach(cb => cb(m)); }
      };
      apply(window.silhouette.mirrored);
      document.addEventListener('DOMContentLoaded', () => apply(window.silhouette.mirrored));
    })();
    """

    /// The OBS browser-source version we claim, so pages that gate on it behave.
    static let obsPluginVersion = "31.0.0"

    /// window.obsstudio, as an OBS browser source provides it, so overlays built
    /// for OBS run unchanged. Every control method is a no-op; the status says a
    /// virtual camera is running; the source is always visible and active.
    private static let obsBridge = """
    (function(){ if (window.obsstudio) return;
      const scene = { name: 'Silhouette', width: 1920, height: 1080 };
      const status = { recording: false, recordingPaused: false, streaming: false, replaybuffer: false, virtualcam: true };
      const noop = () => {};
      window.obsstudio = {
        pluginVersion: '\(obsPluginVersion)',
        getCurrentScene(cb) { cb && cb(scene); },
        getScenes(cb) { cb && cb([scene.name]); },
        getStatus(cb) { cb && cb(Object.assign({}, status)); },
        getControlLevel(cb) { cb && cb(0); },
        getTransitions(cb) { cb && cb(['Cut']); },
        getCurrentTransition(cb) { cb && cb('Cut'); },
        setCurrentScene: noop, setCurrentTransition: noop,
        saveReplayBuffer: noop, startReplayBuffer: noop, stopReplayBuffer: noop,
        startRecording: noop, stopRecording: noop, pauseRecording: noop, unpauseRecording: noop,
        startStreaming: noop, stopStreaming: noop,
        startVirtualcam: noop, stopVirtualcam: noop,
        onVisibilityChange: null, onActiveChange: null
      };
      const fire = () => {
        for (const [type, detail] of [['obsSourceVisibleChanged', { visible: true }], ['obsSourceActiveChanged', { active: true }], ['obsVirtualcamStarted', undefined]]) {
          window.dispatchEvent(new CustomEvent(type, { detail }));
        }
        if (typeof window.obsstudio.onVisibilityChange === 'function') window.obsstudio.onVisibilityChange(true);
        if (typeof window.obsstudio.onActiveChange === 'function') window.obsstudio.onActiveChange(true);
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', fire); else fire();
    })();
    """

    /// Whether Silhouette's preview is mirrored, so pages can mirror text that
    /// should read correctly in it. Persisted into new page loads.
    var previewMirrored = true {
        didSet {
            guard previewMirrored != oldValue else { return }
            let ucc = webView.configuration.userContentController
            ucc.removeAllUserScripts()
            ucc.addUserScript(WKUserScript(source: "window.__silhouetteMirrored = \(previewMirrored);", injectionTime: .atDocumentStart, forMainFrameOnly: false))
            ucc.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            ucc.addUserScript(WKUserScript(source: Self.obsBridge, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            webView.evaluateJavaScript("window.silhouette && silhouette._setMirrored(\(previewMirrored));", completionHandler: nil)
        }
    }

    /// The renderer slot this layer draws into.
    private func setTexture(_ tex: MTLTexture?) {
        if slot == .foreground { renderer.foregroundTexture = tex } else { renderer.backgroundTexture = tex }
    }

    func clear() {
        stopSnapshots()
        stopVideo()
        mode = .none
        webView.isHidden = true
        setTexture(nil)
    }

    private func stopVideo() {
        videoSource?.stop()
        videoSource = nil
    }

    /// A looping movie as the background. Frames are decoded in hardware as
    /// BGRA and wrapped as Metal textures, no copies.
    func setVideo(url: URL) {
        stopSnapshots()
        stopVideo()
        mode = .image
        imageURL = url
        webView.isHidden = true
        if videoTextureCache == nil { CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, renderer.device, nil, &videoTextureCache) }
        let source = VideoFileSource(url: url, pixelFormat: kCVPixelFormatType_32BGRA)
        source.onFrame = { [weak self] pb in
            guard let self, let cache = videoTextureCache else { return }
            var cv: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm,
                                                      CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cv)
            guard let cv, let tex = CVMetalTextureGetTexture(cv) else { return }
            videoTextures = Array((videoTextures + [cv]).suffix(3))
            setTexture(tex)
        }
        videoSource = source
        source.start()
    }

    func setImage(url: URL) {
        stopSnapshots()
        stopVideo()
        mode = .image
        imageURL = url
        webView.isHidden = true
        textureQueue.async { [self] in
            do {
                let tex = try loader.newTexture(URL: url, options: textureOptions)
                setTexture(tex)
            } catch {
                DispatchQueue.main.async { self.onError?("Could not load image: \(error.localizedDescription)") }
            }
        }
    }

    /// A solid colour: a tiny texture the fill scaling stretches over the frame.
    func setColor(_ color: NSColor) {
        stopSnapshots()
        stopVideo()
        mode = .color
        webView.isHidden = true
        let c = color.usingColorSpace(.sRGB) ?? color
        let a = c.alphaComponent   // premultiplied, like every other layer texture
        func b(_ v: CGFloat) -> UInt8 { UInt8(min(max(v * a, 0), 1) * 255 + 0.5) }
        let px: [UInt8] = [b(c.blueComponent), b(c.greenComponent), b(c.redComponent), UInt8(min(max(a, 0), 1) * 255 + 0.5)]
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = renderer.device.makeTexture(descriptor: desc) else { return }
        var bytes: [UInt8] = []
        for _ in 0..<4 { bytes += px }
        tex.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 8)
        setTexture(tex)
    }

    func setWeb(url: URL) {
        stopVideo()
        mode = .web
        webURL = url
        webView.isHidden = false
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        startSnapshots()
    }

    /// Push face tracking data into the page. Cheap: a few hundred bytes of JSON.
    func send(face: FaceState) {
        guard mode == .web, let data = try? encoder.encode(face), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.silhouette && silhouette._update(\(json));", completionHandler: nil)
    }

    /// One-shot timer so the rate can adapt: fast while the page changes,
    /// slow once several snapshots in a row are identical.
    private func startSnapshots() {
        guard snapshotTimer == nil else { return }
        unchangedCount = 0
        scheduleSnapshot()
    }

    private func scheduleSnapshot() {
        let rate = unchangedCount >= Int(Self.snapshotsPerSecond) ? Self.idleSnapshotsPerSecond : Self.snapshotsPerSecond
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1 / rate, repeats: false) { [weak self] _ in
            guard let self else { return }
            snapshotTimer = nil
            snapshot()
            if mode == .web { scheduleSnapshot() }
        }
    }

    private func stopSnapshots() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    private func snapshot() {
        guard !snapshotInFlight else { return }
        snapshotInFlight = true
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.snapshotWidth = NSNumber(value: Double(snapshotWidth))
        config.afterScreenUpdates = false
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self else { return }
            defer { snapshotInFlight = false }
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            // Converge snapshotWidth (points) so the bitmap is ~output width in pixels.
            let ratio = CGFloat(VirtualCameraConstants.width) / CGFloat(cg.width)
            if abs(ratio - 1) > 0.02 { snapshotWidth *= ratio }
            textureQueue.async { self.upload(cg) }
        }
    }

    /// Copy the snapshot into a texture without Core Graphics redrawing it.
    /// Skips the upload entirely when the sampled pixels match the last frame.
    private func upload(_ cg: CGImage) {
        guard cg.bitsPerPixel == 32, cg.bitsPerComponent == 8,
              let data = cg.dataProvider?.data, let base = CFDataGetBytePtr(data) else {
            if let tex = try? loader.newTexture(cgImage: cg, options: textureOptions) { setTexture(tex) }
            return
        }
        let bpr = cg.bytesPerRow, w = cg.width, h = cg.height
        // Signature: 2048 pixels spread over the image.
        var sig = [UInt32](); sig.reserveCapacity(2048)
        let total = w * h, stride = max(total / 2048, 1)
        var i = 0
        while i < total {
            let x = i % w, y = i / w
            sig.append(base.advanced(by: y * bpr + x * 4).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee })
            i += stride
        }
        if sig == lastSignature {
            DispatchQueue.main.async { self.unchangedCount += 1 }
            return
        }
        lastSignature = sig
        DispatchQueue.main.async { self.unchangedCount = 0 }

        let littleEndian = cg.bitmapInfo.contains(.byteOrder32Little)
        let alphaFirst = [CGImageAlphaInfo.premultipliedFirst, .first, .noneSkipFirst].contains(cg.alphaInfo)
        guard littleEndian && alphaFirst else {   // not BGRA: let MetalKit sort it out
            if let tex = try? loader.newTexture(cgImage: cg, options: textureOptions) { setTexture(tex) }
            return
        }
        if uploadTextures.count < 2 || uploadTextures[0].width != w || uploadTextures[0].height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.storageMode = .shared
            d.usage = [.shaderRead]
            d.allowGPUOptimizedContents = false   // skip the driver's CPU-side compression on each upload
            uploadTextures = [renderer.device.makeTexture(descriptor: d)!, renderer.device.makeTexture(descriptor: d)!]
        }
        uploadIndex = 1 - uploadIndex
        let tex = uploadTextures[uploadIndex]
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base, bytesPerRow: bpr)
        setTexture(tex)
    }
}
