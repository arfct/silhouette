import AppKit
import AVFoundation
import UniformTypeIdentifiers
import WebKit
import os.log

/// One composited layer's saved state.
struct LayerSettings: Codable {
    var mode: BackgroundMode = .none
    var path: String?
    var webURL: String?
    var colorHex: String?
    var bookmark: Data?

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(BackgroundMode.self, forKey: .mode)) ?? .none
        path = try? c.decodeIfPresent(String.self, forKey: .path)
        webURL = try? c.decodeIfPresent(String.self, forKey: .webURL)
        colorHex = try? c.decodeIfPresent(String.self, forKey: .colorHex)
        bookmark = try? c.decodeIfPresent(Data.self, forKey: .bookmark)
    }
}

/// The key colour and range that worked for one source, restored when it comes back.
struct SourceKey: Codable {
    var cb: Float, cr: Float, luma: Float, tolerance: Float, softness: Float
    var temporal: Float?
    var edge: Float?, feather: Float?, spill: Float?
}

struct Settings: Codable {
    var params = KeyParams()
    var mode: BackgroundMode = .none
    var imagePath: String?
    var webURL: String?
    var colorHex: String?
    /// Recent movie sources, most recent first, at most ten.
    var recentVideos: [String] = []
    /// Key settings per source id (camera unique id, movie path, sample, test pattern).
    var sourceKeys: [String: SourceKey] = [:]
    var cameraID: String?
    /// Security-scoped bookmarks so the sandboxed app can reopen chosen files.
    var videoBookmark: Data?
    var imageBookmark: Data?
    var keepOnTop = false
    var supersample = false
    var sidebarVisible = true
    var trackFace = false
    var faceOverlay = true
    var faceHighRate = false
    var mirrorPreview = true
    var shadowFollowsFace = false
    /// Recent background URLs and file paths, most recent first, at most ten.
    var recentWebURLs: [String] = []
    /// Security-scoped bookmarks for the file paths in `recentWebURLs`.
    var fileBookmarks: [String: Data] = [:]
    var chromakeyOpen = false
    /// The layer over the keyed camera. The background keeps its original top-level keys.
    var foreground = LayerSettings()

    subscript(slot: LayerSlot) -> LayerSettings {
        get {
            switch slot {
            case .foreground: return foreground
            case .background:
                var l = LayerSettings(); l.mode = mode; l.path = imagePath; l.webURL = webURL; l.colorHex = colorHex; l.bookmark = imageBookmark
                return l
            }
        }
        set {
            switch slot {
            case .foreground: foreground = newValue
            case .background: mode = newValue.mode; imagePath = newValue.path; webURL = newValue.webURL; colorHex = newValue.colorHex; imageBookmark = newValue.bookmark
            }
        }
    }

    init() {}

    /// Every field is optional on read so settings saved by an older build
    /// survive new fields instead of resetting everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        params = (try? c.decodeIfPresent(KeyParams.self, forKey: .params)) ?? KeyParams()
        mode = (try? c.decodeIfPresent(BackgroundMode.self, forKey: .mode)) ?? .none
        imagePath = try? c.decodeIfPresent(String.self, forKey: .imagePath)
        webURL = try? c.decodeIfPresent(String.self, forKey: .webURL)
        colorHex = try? c.decodeIfPresent(String.self, forKey: .colorHex)
        fileBookmarks = (try? c.decodeIfPresent([String: Data].self, forKey: .fileBookmarks)) ?? [:]
        foreground = (try? c.decodeIfPresent(LayerSettings.self, forKey: .foreground)) ?? LayerSettings()
        recentVideos = (try? c.decodeIfPresent([String].self, forKey: .recentVideos)) ?? []
        sourceKeys = (try? c.decodeIfPresent([String: SourceKey].self, forKey: .sourceKeys)) ?? [:]
        cameraID = try? c.decodeIfPresent(String.self, forKey: .cameraID)
        videoBookmark = try? c.decodeIfPresent(Data.self, forKey: .videoBookmark)
        // Older builds remembered one movie source; seed the list with it.
        if recentVideos.isEmpty, let id = cameraID, id.hasPrefix(VideoFileSource.prefix) {
            let path = String(id.dropFirst(VideoFileSource.prefix.count))
            recentVideos = [path]
            if let bookmark = videoBookmark { fileBookmarks[path] = bookmark }
        }
        imageBookmark = try? c.decodeIfPresent(Data.self, forKey: .imageBookmark)
        keepOnTop = (try? c.decodeIfPresent(Bool.self, forKey: .keepOnTop)) ?? false
        supersample = (try? c.decodeIfPresent(Bool.self, forKey: .supersample)) ?? false
        sidebarVisible = (try? c.decodeIfPresent(Bool.self, forKey: .sidebarVisible)) ?? true
        trackFace = (try? c.decodeIfPresent(Bool.self, forKey: .trackFace)) ?? false
        faceOverlay = (try? c.decodeIfPresent(Bool.self, forKey: .faceOverlay)) ?? true
        faceHighRate = (try? c.decodeIfPresent(Bool.self, forKey: .faceHighRate)) ?? false
        mirrorPreview = (try? c.decodeIfPresent(Bool.self, forKey: .mirrorPreview)) ?? true
        shadowFollowsFace = (try? c.decodeIfPresent(Bool.self, forKey: .shadowFollowsFace)) ?? false
        // Keep only well-formed entries (a host with a dot, or localhost).
        chromakeyOpen = (try? c.decodeIfPresent(Bool.self, forKey: .chromakeyOpen)) ?? false
        recentWebURLs = ((try? c.decodeIfPresent([String].self, forKey: .recentWebURLs)) ?? []).filter {
            if $0.hasPrefix("/") || $0.hasPrefix("#") { return true }
            guard let host = URL(string: $0)?.host else { return false }
            return host.contains(".") || host == "localhost"
        }
    }

    private static let key = "settings"
    static func load() -> Settings {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var preview: PreviewView!
    private var splitController: NSSplitViewController!
    private var sidebarItem: NSSplitViewItem!
    private var sidebarObservation: NSKeyValueObservation?
    private var previewLeading: NSLayoutConstraint!
    /// Freeze frame: the newest camera frame, and the one being held while frozen.
    private let frameLock = NSLock()
    private var latestFrame: CVPixelBuffer?
    private var frozenFrame: CVPixelBuffer?
    private var freezeTimer: DispatchSourceTimer?
    private let freezeQueue = DispatchQueue(label: "\(VirtualCameraConstants.appBundleID).freeze", qos: .userInteractive)
    /// Auto key: pools a few frames on its own queue, then applies the result.
    private var autoAnalyzer: AutoKeyAnalyzer?
    private var autoNextSample: CFTimeInterval = 0
    private let autoQueue = DispatchQueue(label: "\(VirtualCameraConstants.appBundleID).autokey", qos: .userInitiated)
    private static let autoFrames = 6
    private static let autoFrameSpacing: CFTimeInterval = 0.2
    /// The source whose key is loaded, so a source change can restore or re-run Auto.
    private var keyedSourceID: String?
    /// fps and GPU time, in the title area above the preview.
    private let statsLabel = NSTextField(labelWithString: "")
    private let renderer = Renderer()
    private let camera = Camera()
    private lazy var background = BackgroundController(renderer: renderer, slot: .background)
    private lazy var foreground = BackgroundController(renderer: renderer, slot: .foreground)
    private var foregroundFile: ScopedFile?
    private func layer(_ slot: LayerSlot) -> BackgroundController { slot == .foreground ? foreground : background }
    private let sink = VirtualCameraSink()
    private let installer = ExtensionInstaller()
    private let faceTracker = FaceTracker()
    private var controls: ControlsView!
    private var settings = Settings.load()
    private var displayedBuffer: CVPixelBuffer?
    private var connectTimer: Timer?
    private var extensionReplaced = false
    private var pickingKey = false
    private var saveTimer: Timer?
    private var videoFile: ScopedFile?
    /// Smoothed face-size multiplier for the shadow (1 = reference size).
    private var smoothedDepth: Float = 1
    private static let referenceFaceHeight: Float = 0.40
    private var imageFile: ScopedFile?

    private var failedStartsSinceReplace = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildControls()
        buildWindow()

        renderer.keyParams = settings.params
        renderer.processScale = settings.supersample ? 2 : 1
        camera.preferHighResolution = settings.supersample
        controls.supersample = settings.supersample
        renderer.onOutput = { [weak self] buffer in self?.handleOutput(buffer) }
        camera.onSourceMirrored = { [weak self] mirrored in self?.renderer.sourceMirrored = mirrored }
        camera.onFrame = { [weak self] pixelBuffer in
            guard let self else { return }
            frameLock.lock()
            let frozen = frozenFrame != nil
            if !frozen { latestFrame = pixelBuffer }
            let analyzer = autoAnalyzer
            let wantSample = analyzer != nil && CACurrentMediaTime() >= autoNextSample
            if wantSample { autoNextSample = CACurrentMediaTime() + Self.autoFrameSpacing }
            frameLock.unlock()
            if !frozen { renderer.render(pixelBuffer) }   // frozen: the timer renders the held frame
            if wantSample, let analyzer { autoQueue.async { [weak self] in self?.autoSample(pixelBuffer, into: analyzer) } }
        }
        controls.onFreeze = { [weak self] on in self?.setFrozen(on) }
        renderer.onTrackingFrame = { [weak self] small in
            guard let self else { return }
            let m = renderer.cameraMapping
            faceTracker.process(small, camScale: m.scale, camOffset: m.offset)
        }
        renderer.onStats = { [weak self] fps, gpuMs in
            self?.statsLabel.stringValue = String(format: "%.0f fps · GPU %.2f ms/frame", fps, gpuMs)
        }
        renderer.trackingEnabled = settings.trackFace
        faceTracker.isEnabled = settings.trackFace
        controls.trackFace = settings.trackFace
        controls.faceOverlay = settings.faceOverlay
        controls.faceHighRate = settings.faceHighRate
        applyTrackingRate()
        controls.onFaceHighRate = { [weak self] on in
            guard let self else { return }
            settings.faceHighRate = on
            applyTrackingRate()
            settings.save()
        }
        preview.showFaceOverlay = settings.faceOverlay
        controls.onFaceOverlay = { [weak self] on in
            guard let self else { return }
            settings.faceOverlay = on
            preview.showFaceOverlay = on
            settings.save()
        }
        faceTracker.onUpdate = { [weak self] state in
            guard let self else { return }
            preview.showFace(state)
            background.send(face: state)
            foreground.send(face: state)
            updateShadowDepth(with: state)
        }
        controls.shadowFollowsFace = settings.shadowFollowsFace
        controls.setRecents(settings.recentWebURLs)
        controls.chromakeyOpen = settings.chromakeyOpen
        controls.onChromakeyOpen = { [weak self] open in
            self?.settings.chromakeyOpen = open
            self?.settings.save()
        }
        background.onError = { [weak self] message in self?.controls.status = message }
        foreground.onError = { [weak self] message in self?.controls.status = message }

        restoreLayer(.background)
        restoreLayer(.foreground)
        controls.apply(params: renderer.keyParams)
        updateWindowChrome()
        startCamera()

        installer.onStatus = { [weak self] status in self?.controls.status = status }
        installer.onNeedsApproval = { [weak self] in self?.controls.highlightSettings = true }
        installer.onActivated = { [weak self] in
            guard let self else { return }
            // A replaced extension leaves this process's CoreMediaIO state
            // stale; a relaunch is the reliable fix (see pollSink).
            extensionReplaced = !sink.isConnected
            failedStartsSinceReplace = 0
            controls.highlightSettings = false
            pollSink()
        }
        installer.activate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollSink() }
        pollSink()

        NotificationCenter.default.addObserver(self, selector: #selector(devicesChanged),
                                               name: AVCaptureDevice.wasConnectedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(devicesChanged),
                                               name: AVCaptureDevice.wasDisconnectedNotification, object: nil)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)   // no text field selected at launch
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        sink.disconnect()
        camera.stop()
        settings.params = renderer.keyParams
        settings.save()
    }

    // MARK: Frame flow

    private func handleOutput(_ buffer: CVPixelBuffer) {
        sink.send(buffer)
        let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        DispatchQueue.main.async { [self] in
            // Nothing to show while the window is hidden, minimised, or covered.
            guard window.occlusionState.contains(.visible) else { return }
            displayedBuffer = buffer
            preview.display(surface: surface)
        }
    }

    private func pollSink() {
        if !sink.isConnected { sink.connect() }
        controls.sinkConnected = sink.isConnected
        if extensionReplaced && !sink.isConnected && sink.startFailed {
            failedStartsSinceReplace += 1
            if failedStartsSinceReplace >= 3 { relaunch() }
        }
    }

    /// Start a fresh instance and quit this one.
    private func relaunch() {
        extensionReplaced = false
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Camera

    private func startCamera() {
        devicesChanged()   // synthetic and file sources need no permission
        camera.requestAccess { [weak self] ok in
            guard let self else { return }
            guard ok else {
                controls.status = "Camera access denied. Allow it in System Settings → Privacy & Security → Camera."
                return
            }
            devicesChanged()
        }
    }

    private func useVideo(_ url: URL, file: ScopedFile? = nil) {
        videoFile = file ?? ScopedFile(url: url)
        settings.cameraID = VideoFileSource.prefix + url.path
        settings.videoBookmark = videoFile?.bookmark
        if let bookmark = settings.videoBookmark { settings.fileBookmarks[url.path] = bookmark }
        settings.recentVideos.removeAll { $0 == url.path }
        settings.recentVideos.insert(url.path, at: 0)
        settings.recentVideos = Array(settings.recentVideos.prefix(10))
        pruneBookmarks()
        settings.save()
        devicesChanged()
    }

    /// A movie picked from the recent list.
    private func selectRecentVideo(path: String) {
        let file = settings.fileBookmarks[path].flatMap { ScopedFile(bookmark: $0) }
        let url = file?.url ?? URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            controls.status = "Can't read \(url.lastPathComponent). Use Video file… to grant access."
            devicesChanged()
            return
        }
        useVideo(url, file: file)
    }

    /// Drop bookmarks for files no recent list mentions any more.
    private func pruneBookmarks() {
        let keep = Set(settings.recentWebURLs + settings.recentVideos)
        settings.fileBookmarks = settings.fileBookmarks.filter { keep.contains($0.key) }
    }

    @objc private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url { useVideo(url) } else { devicesChanged() }
        }
    }

    @objc private func devicesChanged() {
        if controls.frozen { setFrozen(false) }   // a new source means live video again
        defer { updatePreviewMirror(); sourceDidChange() }
        let devices = Camera.availableDevices()
        let id = settings.cameraID ?? ""
        if id.hasPrefix(VideoFileSource.prefix) {
            if videoFile == nil, let bookmark = settings.videoBookmark { videoFile = ScopedFile(bookmark: bookmark) }
            let url = videoFile?.url ?? URL(fileURLWithPath: String(id.dropFirst(VideoFileSource.prefix.count)))
            let readable = FileManager.default.isReadableFile(atPath: url.path)
            Logger(subsystem: VirtualCameraConstants.appBundleID, category: "files").info("restore video \(url.path, privacy: .public) bookmark=\(self.settings.videoBookmark != nil) readable=\(readable)")
            if readable {
                if camera.currentVideoURL != url { camera.startVideo(url: url) }
                controls.setDevices(devices, selected: nil, videos: settings.recentVideos, selectedVideo: url.path)
                return
            }
            // Not readable right now (file missing, cloud-evicted, or access not
            // granted): use a camera for this session but keep the setting so
            // the video comes back when it is available again.
            Logger(subsystem: VirtualCameraConstants.appBundleID, category: "files").error("video source unavailable, keeping it remembered")
            videoFile = nil
        }
        if id == Self.sampleSourceID, let url = Self.sampleVideoURL {
            if camera.currentVideoURL != url { camera.startVideo(url: url) }
            controls.setDevices(devices, selected: nil, sample: true, videos: settings.recentVideos)
            return
        }
        if id == TestPatternSource.id || (devices.isEmpty && !camera.usingTestPattern) {
            if !camera.usingTestPattern { camera.startTestPattern() }
            controls.setDevices(devices, selected: nil, testPattern: true, videos: settings.recentVideos)
            return
        }
        let preferred = devices.first { $0.uniqueID == settings.cameraID } ?? camera.currentDevice ?? devices.first
        if let preferred, preferred.uniqueID != camera.currentDevice?.uniqueID || !devices.contains(where: { $0.uniqueID == camera.currentDevice?.uniqueID }) {
            camera.start(device: preferred)
        }
        controls.setDevices(devices, selected: preferred, videos: settings.recentVideos)
    }

    // MARK: Layers

    private func restoreLayer(_ slot: LayerSlot) {
        let saved = settings[slot]
        let controller = layer(slot)
        switch saved.mode {
        case .image:
            var file = slot == .foreground ? foregroundFile : imageFile
            if file == nil, let bookmark = saved.bookmark { file = ScopedFile(bookmark: bookmark) }
            if slot == .foreground { foregroundFile = file } else { imageFile = file }
            if let url = file?.url ?? saved.path.map({ URL(fileURLWithPath: $0) }) {
                if Self.isMovie(url) { controller.setVideo(url: url) } else { controller.setImage(url: url) }
            }
        case .web:
            setLayerWeb(slot, saved.webURL ?? "")   // empty → demo page
            return
        case .color:
            if let hex = saved.colorHex, let color = Self.color(hex: hex) { controller.setColor(color) } else { controller.clear() }
        case .none: controller.clear()
        }
        syncLayerField(slot)
    }

    /// Show a layer's current state in its combo box.
    private func syncLayerField(_ slot: LayerSlot) {
        let controller = layer(slot)
        switch controller.mode {
        case .none: controls.showLayer(slot, ControlsView.noneTitle)
        case .image: controls.showLayer(slot, controller.imageURL?.path ?? "")
        case .web:
            let url = controller.webURL
            controls.showLayer(slot, url == nil || url!.isFileURL ? ControlsView.testPageTitle : url!.absoluteString)
        case .color: controls.showLayer(slot, settings[slot].colorHex ?? "")
        }
    }

    /// "#RRGGBB" or "#RRGGBBAA" (already normalised by ControlsView.hexColor).
    private static func color(hex: String) -> NSColor? {
        guard let normalized = ControlsView.hexColor(hex) else { return nil }
        let digits = normalized.dropFirst()
        guard let v = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? v >> 8 : v
        let alpha = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    private func setLayerColor(_ slot: LayerSlot, hex: String) {
        guard let color = Self.color(hex: hex) else { controls.status = "Not a valid colour."; return }
        layer(slot).setColor(color)
        var l = settings[slot]; l.mode = .color; l.colorHex = hex; settings[slot] = l
        addRecent(hex)
        settings.save()
        syncLayerField(slot)
        updateWindowChrome()
    }

    private func setLayerNone(_ slot: LayerSlot) {
        layer(slot).clear()
        var l = settings[slot]; l.mode = .none; settings[slot] = l
        settings.save()
        syncLayerField(slot)
        updateWindowChrome()
    }

    private static func isMovie(_ url: URL) -> Bool {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// Image or movie file as a layer.
    private func setLayerImage(_ slot: LayerSlot, _ url: URL, file: ScopedFile? = nil) {
        let scoped = file ?? ScopedFile(url: url)
        if slot == .foreground { foregroundFile = scoped } else { imageFile = scoped }
        let controller = layer(slot)
        if Self.isMovie(url) { controller.setVideo(url: url) } else { controller.setImage(url: url) }
        var l = settings[slot]; l.mode = .image; l.path = url.path; l.bookmark = scoped.bookmark; settings[slot] = l
        if let bookmark = l.bookmark { settings.fileBookmarks[url.path] = bookmark }
        addRecent(url.path)
        settings.save()
        syncLayerField(slot)
        updateWindowChrome()
    }

    /// A path typed into a combo or picked from its recents. A saved bookmark
    /// gets us past the sandbox; otherwise we try the path as is.
    private func setLayerFile(_ slot: LayerSlot, path: String) {
        let url = URL(fileURLWithPath: path)
        let file = settings.fileBookmarks[path].flatMap { ScopedFile(bookmark: $0) }
        guard FileManager.default.isReadableFile(atPath: (file?.url ?? url).path) else {
            controls.status = "Can't read \(url.lastPathComponent). Use Choose File… to grant access."
            syncLayerField(slot)
            return
        }
        setLayerImage(slot, file?.url ?? url, file: file)
    }

    /// Keep the ten most recent entries and drop bookmarks for paths that fell off.
    private func addRecent(_ entry: String) {
        settings.recentWebURLs.removeAll { $0 == entry }
        settings.recentWebURLs.insert(entry, at: 0)
        settings.recentWebURLs = Array(settings.recentWebURLs.prefix(10))
        pruneBookmarks()
        controls.setRecents(settings.recentWebURLs)
    }

    /// Empty text shows the bundled face demo page.
    private func setLayerWeb(_ slot: LayerSlot, _ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty {
            guard let demo = BackgroundController.demoPageURL else { controls.status = "Demo page missing from the app bundle."; return }
            s = demo.absoluteString
        } else if !s.contains("://") {
            s = "https://" + s
        }
        guard let url = URL(string: s), url.isFileURL || (url.host?.contains(".") == true || url.host == "localhost") else {
            controls.status = "Not a valid URL."; return
        }
        layer(slot).setWeb(url: url)
        var l = settings[slot]; l.mode = .web; l.webURL = url.isFileURL ? "" : url.absoluteString; settings[slot] = l
        if !url.isFileURL { addRecent(url.absoluteString) }
        settings.save()
        syncLayerField(slot)
        updateWindowChrome()
    }

    @objc private func showDemoPage() { setLayerWeb(.background, "") }

    @objc private func openBackgroundImage() { openImage(for: .background) }

    private func openImage(for slot: LayerSlot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                syncLayerField(slot)
                return
            }
            setLayerImage(slot, url)
        }
    }

    @objc private func setWebPage() {
        if sidebarItem.isCollapsed { toggleSidebar() }
        window.makeFirstResponder(controls.urlField)
    }

    @objc private func clearBackground() { setLayerNone(.background) }

    /// With no background the keyed camera sits on a checkerboard; with one the composite covers it.
    private func updateWindowChrome() {
        preview.backdrop = background.mode == .none ? .checkerboard : .black
    }

    // MARK: Params

    /// Hold the newest frame and keep rendering it at the output rate, so key and
    /// shadow changes show immediately and the virtual camera never stalls.
    private func setFrozen(_ on: Bool) {
        frameLock.lock()
        frozenFrame = on ? latestFrame : nil
        let holding = frozenFrame != nil
        frameLock.unlock()
        freezeTimer?.cancel()
        freezeTimer = nil
        controls.frozen = holding
        guard holding else { return }
        let timer = DispatchSource.makeTimerSource(queue: freezeQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(VirtualCameraConstants.frameRate))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            frameLock.lock(); let frame = frozenFrame; frameLock.unlock()
            if let frame { renderer.render(frame) }
        }
        freezeTimer = timer
        timer.resume()
    }

    // MARK: Auto key

    /// A different source is live: restore the key that worked for it, or run
    /// Auto once frames are flowing. The first launch after this feature seeds
    /// the current source with the existing settings so nothing changes underfoot.
    private func sourceDidChange() {
        let id = currentSourceID
        guard id != keyedSourceID else { return }
        if keyedSourceID == nil && settings.sourceKeys.isEmpty { settings.sourceKeys[id] = currentSourceKey() }
        keyedSourceID = id
        cancelAutoKey()
        if let saved = settings.sourceKeys[id] {
            renderer.update { p in
                p.keyCbCr = SIMD2(saved.cb, saved.cr); p.keyLuma = saved.luma
                p.tolerance = saved.tolerance; p.softness = saved.softness
                if let t = saved.temporal { p.temporal = t }
                if let e = saved.edge { p.edge = e }
                if let f = saved.feather { p.feather = f }
                if let s = saved.spill { p.spill = s }
            }
            controls.apply(params: renderer.keyParams)
            settings.params = renderer.keyParams
            settings.save()
        } else {
            // Let exposure and focus settle on the new source before judging it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, keyedSourceID == id, autoAnalyzer == nil else { return }
                runAutoKey()
            }
        }
    }

    private var currentSourceID: String {
        settings.cameraID ?? camera.currentDevice?.uniqueID ?? "camera"
    }

    private func currentSourceKey() -> SourceKey {
        let p = renderer.keyParams
        return SourceKey(cb: p.keyCbCr.x, cr: p.keyCbCr.y, luma: p.keyLuma, tolerance: p.tolerance, softness: p.softness,
                         temporal: p.temporal, edge: p.edge, feather: p.feather, spill: p.spill)
    }

    private func rememberKeyForSource() {
        settings.sourceKeys[currentSourceID] = currentSourceKey()
    }

    /// Pool frames for about a second (or the frozen frame alone), then apply.
    private func runAutoKey() {
        cancelAutoKey()
        let analyzer = AutoKeyAnalyzer()
        controls.autoRunning = true
        controls.showKeyHint("Finding the backdrop…")
        frameLock.lock()
        let frozen = frozenFrame
        frameLock.unlock()
        if let frozen {
            autoQueue.async { [weak self] in
                analyzer.add(frozen)
                DispatchQueue.main.async { self?.finishAutoKey(analyzer) }
            }
            return
        }
        frameLock.lock()
        autoAnalyzer = analyzer
        autoNextSample = 0
        frameLock.unlock()
        // Give up if the source stops delivering frames.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, autoAnalyzer === analyzer else { return }
            frameLock.lock(); autoAnalyzer = nil; frameLock.unlock()
            autoQueue.async { [weak self] in DispatchQueue.main.async { self?.finishAutoKey(analyzer) } }
        }
    }

    private func autoSample(_ frame: CVPixelBuffer, into analyzer: AutoKeyAnalyzer) {
        analyzer.add(frame)
        guard analyzer.frameCount >= Self.autoFrames else { return }
        frameLock.lock()
        let stillCurrent = autoAnalyzer === analyzer
        if stillCurrent { autoAnalyzer = nil }
        frameLock.unlock()
        if stillCurrent { DispatchQueue.main.async { [weak self] in self?.finishAutoKey(analyzer) } }
    }

    private func cancelAutoKey() {
        frameLock.lock(); autoAnalyzer = nil; frameLock.unlock()
        controls.autoRunning = false
    }

    private func finishAutoKey(_ analyzer: AutoKeyAnalyzer) {
        controls.autoRunning = false
        guard let result = analyzer.result(), result.confidence >= 0.35 else {
            controls.showKeyHint("Auto couldn't find a plain backdrop around the edge. Click the swatch, then click the backdrop in the preview.", for: 8)
            return
        }
        renderer.update { p in
            p.keyCbCr = result.keyCbCr; p.keyLuma = result.keyLuma
            p.tolerance = result.tolerance; p.softness = result.softness
            p.edge = result.edge; p.feather = result.feather; p.spill = result.spill
        }
        controls.apply(params: renderer.keyParams)
        paramsChanged()
        let pct = Int((result.edgeCoverage * 100).rounded())
        let text = String(format: "Auto: %@ backdrop, %d%% of the edge keyed. Shrink %.1f, Blur %.1f, Desaturate %d.",
                          result.colorName, pct, result.edge, result.feather, Int((result.spill * 100).rounded()))
        controls.showKeyHint(text, for: 8)
    }

    /// Mirror the preview only for live cameras, where it should behave like a
    /// mirror. Movies and the test pattern show as recorded. The output is never mirrored.
    private func updatePreviewMirror() {
        let liveCamera = !camera.usingTestPattern && camera.currentVideoURL == nil
        let mirrored = settings.mirrorPreview && liveCamera
        preview.mirrored = mirrored
        controls.mirrorOffsetPad = mirrored
        background.previewMirrored = mirrored
        foreground.previewMirrored = mirrored
    }

    /// The bundled green screen clip, offered as a source.
    static let sampleSourceID = "sample"
    static let sampleVideoURL = Bundle.main.url(forResource: "Sample", withExtension: "mp4")

    /// 15 Hz with a detection every fourth tracked frame, or 30 Hz with one every other.
    private func applyTrackingRate() {
        renderer.trackingDivisor = settings.faceHighRate ? 1 : 2
        faceTracker.detectEvery = settings.faceHighRate ? 2 : 4
    }

    /// Face height relative to the frame → shadow multiplier, eased so
    /// detection jitter does not make the shadow breathe.
    private func updateShadowDepth(with state: FaceState) {
        guard settings.shadowFollowsFace else {
            if smoothedDepth != 1 { smoothedDepth = 1; renderer.shadowDepthScale = 1 }
            return
        }
        let target: Float
        if let box = state.box, state.detected {
            target = min(max(box.h / Self.referenceFaceHeight, 0.3), 3)
        } else {
            target = 1
        }
        smoothedDepth += (target - smoothedDepth) * 0.2
        renderer.shadowDepthScale = smoothedDepth
    }

    /// Slider drags fire many times a second; write once they settle.
    private func paramsChanged() {
        settings.params = renderer.keyParams
        rememberKeyForSource()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in self?.settings.save() }
    }

    @objc private func toggleMirrorPreview() { setMirrorPreview(!settings.mirrorPreview) }

    private func setMirrorPreview(_ on: Bool) {
        settings.mirrorPreview = on
        settings.save()
        controls.mirrorPreview = on
        updatePreviewMirror()
    }

    @objc private func toggleKeepOnTop() {
        settings.keepOnTop.toggle()
        window.level = settings.keepOnTop ? .floating : .normal
        settings.save()
    }

    /// Show the raw camera image until the user clicks a point to key on.
    private func beginKeyPick() {
        pickingKey = true
        renderer.update { $0.bypass = 1 }
        controls.pickingKey = true
        preview.pickingCursor = true
        window.makeFirstResponder(preview)
    }

    private func endKeyPick() {
        guard pickingKey else { return }
        pickingKey = false
        renderer.update { $0.bypass = 0 }
        controls.pickingKey = false
        preview.pickingCursor = false
    }

    @objc private func showControls() { toggleSidebar() }

    private func toggleSidebar() {
        sidebarItem.animator().isCollapsed.toggle()
    }


    @objc private func uninstallExtension() { installer.deactivate() }

    // MARK: UI construction

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960 + ControlsView.width, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Silhouette"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.level = settings.keepOnTop ? .floating : .normal
        window.delegate = self

        // Unified sidebar: NSSplitViewController gives the full-height sidebar
        // (Liquid Glass on macOS 26) with the controls, and a plain content area
        // for the preview.
        preview = PreviewView(frame: .zero)
        preview.mirrored = settings.mirrorPreview
        controls.mirrorOffsetPad = settings.mirrorPreview
        controls.mirrorPreview = settings.mirrorPreview
        preview.translatesAutoresizingMaskIntoConstraints = false
        // The web view must live in the window for snapshots, but never on
        // screen: park it far outside the visible area.
        for web in [background.webView, foreground.webView] {
            web.autoresizingMask = []
            web.frame.origin = NSPoint(x: -8000, y: -8000)
        }

        // One material behind both panes so the window reads as a single sheet;
        // the preview sits in a box inset like the sidebar's groups.
        let contentHost = NSView()
        let previewBox = ControlsView.makeBox()
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        let previewContent = NSView()
        previewContent.wantsLayer = true
        previewContent.layer?.cornerRadius = 5   // NSBox's own radius, so the frame clips at the corners
        previewContent.layer?.masksToBounds = true
        previewContent.addSubview(preview)
        previewBox.contentView = previewContent
        contentHost.addSubview(background.webView)
        contentHost.addSubview(foreground.webView)
        contentHost.addSubview(previewBox)
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = .tertiaryLabelColor
        statsLabel.alignment = .right
        statsLabel.toolTip = "Frames per second and GPU time per frame for the keying pipeline."
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(statsLabel)
        // 16:9 like the output, as large as the insets allow, pinned to the top.
        let aspect = CGFloat(VirtualCameraConstants.width) / CGFloat(VirtualCameraConstants.height)
        // The sidebar already pads its right edge by 12, so the box starts at the
        // pane's edge; with the sidebar hidden it takes the same 12 itself.
        let area = NSLayoutGuide()
        contentHost.addLayoutGuide(area)
        previewLeading = area.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: settings.sidebarVisible ? 0 : 12)
        let fullWidth = previewBox.widthAnchor.constraint(equalTo: area.widthAnchor)
        fullWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            previewLeading,
            area.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -12),
            area.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 44),
            area.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor, constant: -14),
            statsLabel.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -16),
            statsLabel.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 14),
            previewBox.widthAnchor.constraint(equalTo: previewBox.heightAnchor, multiplier: aspect),
            previewBox.topAnchor.constraint(equalTo: area.topAnchor),
            previewBox.leadingAnchor.constraint(equalTo: area.leadingAnchor),   // left-aligned when height-limited
            previewBox.bottomAnchor.constraint(lessThanOrEqualTo: area.bottomAnchor),
            fullWidth,
            preview.leadingAnchor.constraint(equalTo: previewContent.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewContent.trailingAnchor),
            preview.topAnchor.constraint(equalTo: previewContent.topAnchor),
            preview.bottomAnchor.constraint(equalTo: previewContent.bottomAnchor),
        ])
        let contentController = NSViewController()
        contentController.view = contentHost

        let sidebarController = NSViewController()
        sidebarController.view = controls
        sidebarItem = NSSplitViewItem(viewController: sidebarController)
        sidebarItem.minimumThickness = ControlsView.width   // fixed width: no dragging
        sidebarItem.maximumThickness = ControlsView.width
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebarItem.isCollapsed = !settings.sidebarVisible

        splitController = NSSplitViewController()
        splitController.splitView = InvisibleDividerSplitView()
        splitController.splitView.isVertical = true
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(NSSplitViewItem(viewController: contentController))

        // The whole window is one sheet of Liquid Glass (macOS 26); older systems
        // get the closest material. Both panes sit on it with no backdrop of their own.
        let root = NSViewController()
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.contentView = splitController.view
            backdrop = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .sidebar
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            splitController.view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(splitController.view)
            NSLayoutConstraint.activate([
                splitController.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                splitController.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                splitController.view.topAnchor.constraint(equalTo: effect.topAnchor),
                splitController.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            backdrop = effect
        }
        root.view = backdrop
        root.addChild(splitController)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentViewController = root
        window.contentMinSize = NSSize(width: 640, height: 300)

        sidebarObservation = sidebarItem.observe(\.isCollapsed) { [weak self] item, _ in
            guard let self else { return }
            settings.sidebarVisible = !item.isCollapsed
            previewLeading.constant = item.isCollapsed ? 12 : 0
            settings.save()
        }
        window.center()
        window.setFrameAutosaveName("MainFree")

        preview.onPick = { [weak self] uv in
            guard let self, pickingKey else { return }
            renderer.pickKey(atOutputUV: uv)
            endKeyPick()
            controls.apply(params: renderer.keyParams)
            paramsChanged()
        }
        preview.onCancel = { [weak self] in self?.endKeyPick() }
        preview.onDrop = { [weak self] url in
            guard let self else { return }
            if !url.isFileURL { setLayerWeb(.background, url.absoluteString); return }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            if type.conforms(to: .movie) || type.conforms(to: .video) { useVideo(url) } else { setLayerImage(.background, url) }
        }
    }

    private func buildControls() {
        controls = ControlsView(frame: NSRect(x: 0, y: 0, width: ControlsView.width, height: 540))
        controls.onCameraSelected = { [weak self] device in
            self?.camera.start(device: device)
            self?.settings.cameraID = device.uniqueID
            self?.settings.save()
            self?.updatePreviewMirror()
            self?.sourceDidChange()
        }
        controls.onChooseVideo = { [weak self] in self?.chooseVideo() }
        controls.onAutoKey = { [weak self] in
            guard let self else { return }
            endKeyPick()
            runAutoKey()
        }
        controls.onMirrorPreview = { [weak self] on in self?.setMirrorPreview(on) }
        controls.onShadowFollowsFace = { [weak self] on in
            guard let self else { return }
            settings.shadowFollowsFace = on
            if on && !settings.trackFace {   // needs the tracker
                settings.trackFace = true
                controls.trackFace = true
                faceTracker.isEnabled = true
                renderer.trackingEnabled = true
            }
            if !on { smoothedDepth = 1; renderer.shadowDepthScale = 1 }
            settings.save()
        }
        controls.onPickKey = { [weak self] in
            guard let self else { return }
            if pickingKey { endKeyPick() } else { beginKeyPick() }
        }
        controls.onTrackFace = { [weak self] on in
            guard let self else { return }
            settings.trackFace = on
            settings.save()
            faceTracker.isEnabled = on
            renderer.trackingEnabled = on
            if !on { preview.showFace(nil) }
        }
        controls.onSampleSelected = { [weak self] in
            guard let self else { return }
            settings.cameraID = Self.sampleSourceID
            settings.save()
            devicesChanged()
        }
        controls.onTestPatternSelected = { [weak self] in
            self?.camera.startTestPattern()
            self?.settings.cameraID = TestPatternSource.id
            self?.settings.save()
            self?.updatePreviewMirror()
            self?.sourceDidChange()
        }
        controls.onSupersample = { [weak self] on in
            guard let self else { return }
            settings.supersample = on
            settings.save()
            renderer.processScale = on ? 2 : 1
            camera.preferHighResolution = on
            if let device = camera.currentDevice { camera.start(device: device) }   // re-pick the preset
        }
        controls.onLayerNone = { [weak self] slot in self?.setLayerNone(slot) }
        controls.onLayerChooseFile = { [weak self] slot in self?.openImage(for: slot) }
        controls.onLayerWeb = { [weak self] slot, text in self?.setLayerWeb(slot, text) }
        controls.onLayerFile = { [weak self] slot, path in self?.setLayerFile(slot, path: path) }
        controls.onLayerColor = { [weak self] slot, hex in self?.setLayerColor(slot, hex: hex) }
        controls.onVideoSelected = { [weak self] path in self?.selectRecentVideo(path: path) }
        controls.onParam = { [weak self] keyPath, value in
            self?.renderer.update { $0[keyPath: keyPath] = value }
            self?.paramsChanged()
        }
        controls.onInstall = { [weak self] in self?.installer.activate() }
        controls.onOpenSettings = { ExtensionInstaller.openSystemSettings() }
    }

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Silhouette", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Uninstall Virtual Camera", action: #selector(uninstallExtension), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Silhouette", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Silhouette", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Silhouette"))

        let file = NSMenu(title: "Background")
        file.addItem(withTitle: "Open Image or Video…", action: #selector(openBackgroundImage), keyEquivalent: "o")
        file.addItem(withTitle: "Set Web Page…", action: #selector(setWebPage), keyEquivalent: "l")
        file.addItem(withTitle: "Face Demo Page", action: #selector(showDemoPage), keyEquivalent: "d")
        file.addItem(withTitle: "Clear Background", action: #selector(clearBackground), keyEquivalent: "\u{8}")
        file.addItem(.separator())
        file.addItem(withTitle: "Open Video as Camera…", action: #selector(chooseVideo), keyEquivalent: "O")
        main.addItem(submenu(file, title: "Background"))

        // Standard Edit menu: without it, text fields get no ⌘A/⌘C/⌘V/⌘Z.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Keep on Top", action: #selector(toggleKeepOnTop), keyEquivalent: "t")
        let mirror = view.addItem(withTitle: "Mirror Preview", action: #selector(toggleMirrorPreview), keyEquivalent: "M")
        mirror.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(withTitle: "Show Controls", action: #selector(showControls), keyEquivalent: "k")
        main.addItem(submenu(view, title: "View"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu

        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Silhouette Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        main.addItem(submenu(help, title: "Help"))
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleKeepOnTop): menuItem.state = settings.keepOnTop ? .on : .off
        case #selector(showControls): menuItem.state = settings.sidebarVisible ? .on : .off
        case #selector(toggleMirrorPreview): menuItem.state = settings.mirrorPreview ? .on : .off
        default: break
        }
        return true
    }
}

/// Both panes share one backdrop and the sidebar has a fixed width, so there is no divider to see or drag.
private final class InvisibleDividerSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 0 }
    override func drawDivider(in rect: NSRect) {}
}
