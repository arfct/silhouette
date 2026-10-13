import AppKit
import AVFoundation

// MARK: - Two-thumb range slider

final class RangeSlider: NSControl {
    var minValue: Float = 0
    var maxValue: Float = 1
    var minGap: Float = 0.01
    var lower: Float = 0 { didSet { needsDisplay = true } }
    var upper: Float = 1 { didSet { needsDisplay = true } }
    var onChange: ((Float, Float) -> Void)?
    /// When set, the track shows this colour for each value, made transparent
    /// below `lower` and fading to opaque at `upper`: the key's effect, drawn.
    var colorAt: ((Float) -> NSColor)? { didSet { needsDisplay = true } }

    /// Track height: a mini switch's, so the swatch and Auto beside it line up.
    static let trackHeight: CGFloat = 18
    private let knobRadius: CGFloat = 7
    /// Thumb centres stay this far from the ends, inside the capsule.
    private var inset: CGFloat { Self.trackHeight / 2 }
    private var activeThumb = 0

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.trackHeight) }

    private func x(for v: Float) -> CGFloat {
        let t = min(max((v - minValue) / (maxValue - minValue), 0), 1)   // typed values may sit outside the track
        return inset + CGFloat(t) * (bounds.width - 2 * inset)
    }
    private func value(forX x: CGFloat) -> Float {
        let t = Float((x - inset) / max(bounds.width - 2 * inset, 1))
        return min(max(minValue + t * (maxValue - minValue), minValue), maxValue)
    }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        if let colorAt {
            drawColorTrack(colorAt, midY: midY)
        } else {
            let track = NSRect(x: 0, y: midY - 2, width: bounds.width, height: 4)
            NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            let selected = NSRect(x: x(for: lower), y: midY - 2, width: max(x(for: upper) - x(for: lower), 0), height: 4)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: selected, xRadius: 2, yRadius: 2).fill()
        }
        for v in [lower, upper] {
            let r = NSRect(x: x(for: v) - knobRadius, y: midY - knobRadius, width: 2 * knobRadius, height: 2 * knobRadius)
            let path = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            NSColor.white.setFill(); path.fill()
            if let colorAt {   // thumbs wear the colour they sit on
                colorAt(v).setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: 2.5, dy: 2.5)).fill()
            }
            NSColor.black.withAlphaComponent(0.25).setStroke(); path.lineWidth = 1; path.stroke()
        }
    }

    /// A strip of the colours at each distance from the key: the key colour at
    /// the left, through neutral, toward its complement on the right.
    private func drawColorTrack(_ colorAt: (Float) -> NSColor, midY: CGFloat) {
        let h = Self.trackHeight - 1
        // Full width, as tall as a switch, with fully rounded ends; the thumbs sit inside it.
        let track = NSRect(x: 0.5, y: midY - h / 2, width: bounds.width - 1, height: h)
        let clip = NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        let step: CGFloat = 0.5
        var px = track.minX
        while px < track.maxX {
            colorAt(value(forX: px + step / 2)).setFill()
            NSRect(x: px, y: track.minY, width: step, height: h).fill()
            px += step
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        clip.lineWidth = 1
        clip.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        activeThumb = abs(p.x - x(for: lower)) <= abs(p.x - x(for: upper)) ? 1 : 2
        update(with: p)
    }
    override func mouseDragged(with event: NSEvent) { update(with: convert(event.locationInWindow, from: nil)) }
    private func update(with p: NSPoint) {
        let v = value(forX: p.x)
        if activeThumb == 1 { lower = min(v, upper - minGap) } else { upper = max(v, lower + minGap) }
        onChange?(lower, upper)
    }
}

// MARK: - 2D offset pad

final class OffsetPad: NSControl {
    var range: Float = 0.15
    /// Mirror the horizontal axis (the preview is mirrored; the pad should match it).
    var flipX = false { didSet { needsDisplay = true } }
    var value = SIMD2<Float>(0, 0) { didSet { needsDisplay = true } }
    var onChange: ((SIMD2<Float>) -> Void)?
    override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 64) }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.secondarySystemFill.setFill(); bg.fill()
        NSColor.separatorColor.setStroke(); bg.stroke()
        NSColor.tertiaryLabelColor.setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: bounds.midX, y: 6)); cross.line(to: NSPoint(x: bounds.midX, y: bounds.maxY - 6))
        cross.move(to: NSPoint(x: 6, y: bounds.midY)); cross.line(to: NSPoint(x: bounds.maxX - 6, y: bounds.midY))
        cross.lineWidth = 1; cross.stroke()
        let p = point(for: value)
        let marker = NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
        NSColor.controlBackgroundColor.setFill(); marker.fill()
        NSColor.secondaryLabelColor.setStroke(); marker.lineWidth = 1.5; marker.stroke()
    }
    private var radius: CGFloat { bounds.width / 2 - 8 }
    private func point(for v: SIMD2<Float>) -> NSPoint {
        let sx: CGFloat = flipX ? -1 : 1
        return NSPoint(x: bounds.midX + sx * CGFloat(v.x / range) * radius, y: bounds.midY - CGFloat(v.y / range) * radius)
    }
    private func set(from p: NSPoint) {
        let x = Float((p.x - bounds.midX) / radius) * range * (flipX ? -1 : 1)
        let y = Float(-(p.y - bounds.midY) / radius) * range
        value = SIMD2(min(max(x, -range), range), min(max(y, -range), range))
        onChange?(value)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { value = .zero; onChange?(value); return }
        set(from: convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) { set(from: convert(event.locationInWindow, from: nil)) }
}

// MARK: - Editable value field with arrow stepping

/// Right-aligned numeric text. Return commits; ↑/↓ step (⇧ for 10×).
final class ValueField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onStep: ((Float) -> Void)?   // +1 / -1 (×10 with shift)

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        alignment = .right
        font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textColor = .secondaryLabelColor
        delegate = self
        target = self
        action = #selector(commit)
        cell?.sendsActionOnEndEditing = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func commit() { onCommit?(stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let onStep else { return false }
        let big: Float = NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? 10 : 1
        switch selector {
        case #selector(NSResponder.moveUp(_:)): onStep(big); return true
        case #selector(NSResponder.moveDown(_:)): onStep(-big); return true
        default: return false
        }
    }
}

// MARK: - Control cell: label + value over a control

final class ControlCell: NSView {
    let label = NSTextField(labelWithString: "")
    let value = ValueField(frame: .zero)
    let control: NSView

    /// `valueViews` replaces the single value field, e.g. two fields for a range.
    init(title: String, control: NSView, valueViews: [NSView]? = nil) {
        self.control = control
        super.init(frame: .zero)
        label.stringValue = title
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let top = NSStackView(views: [label] + (valueViews ?? [value]))
        top.spacing = 4
        top.distribution = .fill
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(valueViews == nil ? .required : NSLayoutConstraint.Priority(1), for: .horizontal)
        let stack = NSStackView(views: [top, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            control.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Controls sidebar

final class ControlsView: NSView {
    static let width: CGFloat = 316
    static let testPageTitle = "Test page"
    static let noneTitle = "None"
    static let chooseTitle = "Choose File…"

    var onCameraSelected: ((AVCaptureDevice) -> Void)?
    var onTestPatternSelected: (() -> Void)?
    var onSampleSelected: (() -> Void)?
    var onChooseVideo: (() -> Void)?
    /// A movie from the recent list, by path.
    var onVideoSelected: ((String) -> Void)?
    var onTrackFace: ((Bool) -> Void)?
    var onShadowFollowsFace: ((Bool) -> Void)?
    var onMirrorPreview: ((Bool) -> Void)?
    var onFaceOverlay: ((Bool) -> Void)?
    /// 0 = chroma key, 1 = person segmentation.
    var onMatteSource: ((Int) -> Void)?
    /// Apple Chromakey was chosen: explain the Video Effects setup.
    var onAppleChromakey: (() -> Void)?
    var onTemperatureAuto: ((Bool) -> Void)?
    /// True freezes the current frame for tuning; false goes back to live video.
    var onFreeze: ((Bool) -> Void)?
    var onFaceHighRate: ((Bool) -> Void)?
    var onSupersample: ((Bool) -> Void)?
    /// Layer combo boxes: what the user committed, for the background or the foreground.
    var onLayerNone: ((LayerSlot) -> Void)?
    var onLayerChooseFile: ((LayerSlot) -> Void)?
    var onLayerWeb: ((LayerSlot, String) -> Void)?
    var onLayerFile: ((LayerSlot, String) -> Void)?
    var onLayerColor: ((LayerSlot, String) -> Void)?
    var onParam: ((WritableKeyPath<KeyParams, Float>, Float) -> Void)?
    var onInstall: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onPickKey: (() -> Void)?
    var onAutoKey: (() -> Void)?

    /// Option buttons drawn over the tiles.
    private let supersampleButton = OverlayButton(text: "HD", tip: "HD keys at 1080p. 4K captures and keys at 3840×2160 when the camera supports it, then downsamples to the 1080p output: finer hair and edges, about four times the GPU work.")
    private let mirrorButton = OverlayButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", tip: "Mirror the preview like a mirror. The sources, the layers, and the virtual camera output are never mirrored.")
    private let freezeButton = OverlayButton(symbol: "pause.fill", tip: "Freeze frame")
    private let fgMaskButton = OverlayButton(symbol: "person.and.background.dotted", tip: "Mask: confine the foreground layer to your silhouette, so a colour with alpha or a web page lights or tints you rather than covering the frame. Off, the foreground covers everything.")
    private let fgBlendButton = OverlayButton(symbol: "camera.filters", tip: "Blend: how the foreground combines with what is under it, as in an image editor. Normal lays it on top.")
    private var fgBlendValue = 0
    /// Background, Source, and Foreground, shown above the preview rather than in the sidebar.
    private(set) var sourceTile: LayerTile!
    private(set) var backgroundTile: LayerTile!
    private(set) var foregroundTile: LayerTile!
    /// The row of three tiles; the window places it above the preview.
    let layerStrip = NSStackView()
    /// Mirror and Pause, which the window places on the preview's bottom-right corner.
    let previewButtons = NSStackView()
    private let picker = PickerPopover()
    private enum PickerTarget { case source, layer(LayerSlot) }
    private var pickerTarget: PickerTarget?
    private var recentURLs: [String] = []
    private var layerValues: [LayerSlot: String] = [.background: ControlsView.noneTitle, .foreground: ControlsView.noneTitle]
    private var sourceSelection: String?
    /// The live camera frame, for the current camera's tile.
    var currentFrameImage: (() -> NSImage?)?
    /// The current web page of a layer, for its tile.
    var layerSnapshot: ((LayerSlot) -> NSImage?)?
    /// Forget a layer recent (URL, path, or colour), or a recent movie source by path.
    var onRemoveRecent: ((String) -> Void)?
    var onRemoveVideo: ((String) -> Void)?
    private let trackSwitch = NSSwitch()
    private let overlaySwitch = NSSwitch()
    private let temperatureAutoSwitch = NSButton()
    private let colorSwitch = NSSwitch()
    /// Foreground blend modes, in the shader's order; Normal is 0.
    static let blendModes = ["Normal", "Multiply", "Screen", "Overlay", "Soft Light", "Hard Light", "Color Dodge", "Color Burn", "Add", "Lighten", "Darken", "Difference", "Exclusion"]
    private var colorBody: NSView!
    private var temperatureCell: NSView!
    private var overlayRow: NSView!
    private let highRateSwitch = NSSwitch()
    private var highRateRow: NSView!
    private let depthSwitch = NSSwitch()
    private let shadowSwitch = NSSwitch()
    private var shadowBody: NSView!
    private var shadowGroup: NSView!
    private let keySwitch = NSSwitch()
    /// The Chromakey section's title, as a pull-down: Chromakey, Background Removal, Apple Chromakey…
    private let matteMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private var keyRangeRow: NSView!
    /// Apple mode: open Video Effects, save the green image, and a status line.
    var onOpenVideoEffects: (() -> Void)?
    var onSaveGreenImage: (() -> Void)?
    private let sinkDot = StatusDot()
    private var sinkGroup: NSView!
    private var showSinkDetail = false
    /// Title-bar indicator shown while the virtual camera is live; tapping it shows the detail.
    private let connectedButton = NSButton(title: "Connected", target: nil, action: nil)
    private let connectedDot = StatusDot()
    private var chromaBody: NSView!
    private var connectedRow: NSStackView!
    private let offsetValue = ValueField(frame: .zero)
    private let keySwatch = NSButton(title: "", target: nil, action: nil)
    private let keyHint = NSTextField(wrappingLabelWithString: "")
    private let autoButton = NSButton(title: "Auto", target: nil, action: nil)
    private var hintTimer: Timer?
    private let keyRange = RangeSlider()
    private let offsetPad = OffsetPad()
    /// `scale` and `decimals` turn the stored value into what the field shows (percent, pixels).
    private var cells: [WritableKeyPath<KeyParams, Float>: (slider: NSSlider, cell: ControlCell, range: ClosedRange<Float>, scale: Float, decimals: Int)] = [:]
    private static let keyRangeTip = "Color Range: how close a colour must be to the key colour to be removed, in percent of the full chroma span. The left thumb is fully removed; the right thumb is where the transition to opaque ends. Typical keys sit between 5 and 20."
    private let sinkStatus = NSTextField(labelWithString: "Not connected")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: "Install", target: nil, action: nil)
    private let settingsButton = NSButton(title: "System Settings…", target: nil, action: nil)
    private var sinkButtons: NSStackView!
    private var devices: [AVCaptureDevice] = []
    private var videoPaths: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 12, bottom: 14, right: 12)   // under the traffic lights
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Virtual camera: status in the header; buttons and help only while not live.
        sinkStatus.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = Self.width - 56
        installButton.target = self; installButton.action = #selector(installTapped); installButton.controlSize = .small
        settingsButton.target = self; settingsButton.action = #selector(settingsTapped); settingsButton.controlSize = .small
        sinkButtons = NSStackView(views: [installButton, settingsButton]); sinkButtons.spacing = 8
        let statusRow = NSStackView(views: [sinkDot, sinkStatus]); statusRow.spacing = 6
        statusRow.toolTip = "Whether the Silhouette camera extension is receiving frames. Live means other apps can pick the Silhouette camera."
        sinkStatus.toolTip = statusRow.toolTip
        sinkGroup = group("Virtual camera", trailing: statusRow, rows: [sinkButtons, statusLabel])
        stack.addArrangedSubview(sinkGroup)

        // Title-area indicator (top right of the sidebar), only while live.
        connectedDot.color = .systemGreen
        connectedButton.isBordered = false
        connectedButton.font = .systemFont(ofSize: 11, weight: .medium)
        connectedButton.contentTintColor = .secondaryLabelColor
        connectedButton.target = self
        connectedButton.action = #selector(connectedTapped)
        connectedButton.toolTip = "The virtual camera is live. Click for details."
        let connectedRow = NSStackView(views: [connectedDot, connectedButton])
        connectedRow.spacing = 5
        connectedRow.translatesAutoresizingMaskIntoConstraints = false
        connectedRow.identifier = NSUserInterfaceItemIdentifier("connectedRow")
        connectedRow.isHidden = true
        self.connectedRow = connectedRow

        trackSwitch.target = self; trackSwitch.action = #selector(trackChanged)

        // Background, Source, Foreground: tiles above the preview. Each has a
        // picker button at its top right and its options at the bottom right.
        supersampleButton.target = self; supersampleButton.action = #selector(supersampleChanged)
        mirrorButton.target = self; mirrorButton.action = #selector(mirrorChanged)
        freezeButton.target = self; freezeButton.action = #selector(freezeTapped)
        fgMaskButton.target = self; fgMaskButton.action = #selector(fgMaskToggled)
        fgBlendButton.target = self; fgBlendButton.action = #selector(fgBlendTapped)
        frozen = false
        sourceTile = LayerTile(title: "Source", options: [supersampleButton])
        // Mirror and Pause act on the preview, so they sit on it rather than on the Source tile.
        for button in [mirrorButton, freezeButton] { previewButtons.addArrangedSubview(button) }
        previewButtons.spacing = 6
        previewButtons.translatesAutoresizingMaskIntoConstraints = false
        backgroundTile = LayerTile(title: "Background", options: [])
        foregroundTile = LayerTile(title: "Foreground", options: [fgMaskButton, fgBlendButton])
        sourceTile.onPick = { [weak self] in self?.showSourcePicker() }
        backgroundTile.onPick = { [weak self] in self?.showLayerPicker(.background) }
        foregroundTile.onPick = { [weak self] in self?.showLayerPicker(.foreground) }
        for tile in [backgroundTile!, sourceTile!, foregroundTile!] {   // back to front, as they stack in the output
            layerStrip.addArrangedSubview(tile.column)
            // Exactly a third of the row, so nothing (a long caption, the fill-height rule) can widen a tile.
            tile.column.widthAnchor.constraint(equalTo: layerStrip.widthAnchor, multiplier: 1.0 / 3.0, constant: -20.0 / 3.0).isActive = true
        }
        layerStrip.orientation = .horizontal
        layerStrip.distribution = .fillEqually
        layerStrip.alignment = .top
        layerStrip.setClippingResistancePriority(.defaultLow, for: .horizontal)
        layerStrip.setHuggingPriority(NSLayoutConstraint.Priority(800), for: .vertical)   // never stretch to fill height
        layerStrip.spacing = 10
        layerStrip.translatesAutoresizingMaskIntoConstraints = false
        picker.onSelect = { [weak self] value in self?.pickerChose(value) }
        picker.onRemove = { [weak self] value in self?.pickerRemoved(value) }
        picker.onAdd = { [weak self] kind, text in self?.pickerAdded(kind, text) }
        showLayer(.background, Self.noneTitle)
        showLayer(.foreground, Self.noneTitle)

        // Key: swatch, Pick and Auto in the header; range and spill below.
        keySwatch.isBordered = false
        keySwatch.wantsLayer = true
        keySwatch.layer?.cornerRadius = RangeSlider.trackHeight / 2   // a capsule, like the track beside it
        keySwatch.layer?.borderWidth = 1
        keySwatch.layer?.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor
        keySwatch.widthAnchor.constraint(equalToConstant: 36).isActive = true   // a mini switch's width
        keySwatch.heightAnchor.constraint(equalToConstant: RangeSlider.trackHeight).isActive = true
        keySwatch.target = self
        keySwatch.action = #selector(pickKeyTapped)
        keySwatch.toolTip = "The backdrop colour being removed. Click to show the unkeyed image, then click the backdrop in the preview. Esc cancels."
        // Auto: a small text button the size of the switch above it.
        autoButton.title = "Auto"
        autoButton.isBordered = false
        autoButton.wantsLayer = true
        autoButton.layer?.cornerRadius = RangeSlider.trackHeight / 2
        autoButton.font = .systemFont(ofSize: 10, weight: .medium)
        autoButton.contentTintColor = .labelColor
        autoButton.target = self; autoButton.action = #selector(autoKeyTapped)
        autoButton.setContentHuggingPriority(.required, for: .horizontal)
        autoButton.widthAnchor.constraint(equalToConstant: 36).isActive = true   // the switch's visible size
        autoButton.heightAnchor.constraint(equalToConstant: RangeSlider.trackHeight).isActive = true
        updateAutoButtonFill()
        autoButton.toolTip = "Find the backdrop colour and range from the edges of the frame over about a second, avoiding the face and body. Runs by itself when a new source is chosen."
        keySwitch.target = self; keySwitch.action = #selector(keyToggled)
        keySwitch.controlSize = .mini
        keySwitch.toolTip = "Key out the backdrop. Off passes the camera through untouched, so the background and shadow have no effect."
        keyHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keyHint.textColor = .secondaryLabelColor
        keyHint.preferredMaxLayoutWidth = Self.width - 48
        keyHint.isHidden = true
        keyRange.minValue = 0; keyRange.maxValue = 0.3
        keyRange.onChange = { [weak self] lo, hi in
            self?.onParam?(\.tolerance, lo); self?.onParam?(\.softness, hi - lo); self?.updateCompositeValues()
        }
        keyRange.setAccessibilityElement(true)
        keyRange.setAccessibilityRole(.slider)
        keyRange.setAccessibilityLabel("Color Range")
        // Chromakey: the title is a pull-down for the matte, the swatch sits at
        // its left, Auto sits beside the Color Range.
        matteMenu.pullsDown = true
        matteMenu.isBordered = false
        matteMenu.addItem(withTitle: "")   // the pull-down's title, set in matteSource
        for (title, tag) in [("Chromakey", 0), ("Background Removal", 1)] {
            matteMenu.addItem(withTitle: title)
            matteMenu.lastItem?.tag = tag
            matteMenu.lastItem?.target = self
            matteMenu.lastItem?.action = #selector(matteChosen(_:))
        }
        matteMenu.menu?.addItem(.separator())
        matteMenu.addItem(withTitle: "Apple Chromakey…")
        matteMenu.lastItem?.target = self
        matteMenu.lastItem?.action = #selector(appleChromakeyChosen)
        matteMenu.lastItem?.toolTip = "Use the Mac's own Background effect with a plain green image, then key that green: the best edges without a backdrop, on cameras that support it."
        matteMenu.toolTip = "Chromakey removes a real backdrop by colour. Background Removal finds you with on-device segmentation and needs no backdrop. Apple Chromakey sets up the Mac's Background effect with a green image to key."
        matteMenu.setContentHuggingPriority(.required, for: .horizontal)
        let keyRangeRow = NSStackView(views: [keySwatch, keyRange, autoButton])
        keyRangeRow.spacing = 8
        keyRangeRow.alignment = .centerY
        keyRange.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        self.keyRangeRow = keyRangeRow
        let body = NSStackView(views: [
            keyRangeRow,
            columns([sliderCell("Shrink", \.edge, 0...4, decimals: 1, tip: "Pulls the matte edge in by this many pixels (at 1920×1080) to trim fringes. The same value means the same amount on a 720p or 4K source."),
                     sliderCell("Blur", \.feather, 0...4, decimals: 1, tip: "Softens the matte edge, in pixels at 1920×1080.")]),
            columns([sliderCell("Desaturate", \.spill, 0...1, scale: 100, decimals: 0, tip: "Removes the backdrop's tint reflected onto hair and clothing, in percent."),
                     sliderCell("Stabilize", \.temporal, 0...0.9, scale: 100, decimals: 0, tip: "Blends the matte with the previous frame where the picture is static, to stop edge flicker from sensor noise. Percent of the previous frame kept; movement passes straight through.")]),
        ])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        for v in body.arrangedSubviews { v.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        chromaBody = body
        stack.addArrangedSubview(group("Chromakey", titleView: matteMenu, trailing: keySwitch, rows: [body, keyHint]))
        matteSource = 0

        // Colour: corrections applied to the keyed camera image only, after the matte.
        colorSwitch.target = self; colorSwitch.action = #selector(colorToggled)
        colorSwitch.controlSize = .mini
        colorSwitch.toolTip = "Apply the colour corrections. Off leaves your image's colour as the camera sends it."
        temperatureAutoSwitch.setButtonType(.pushOnPushOff)
        temperatureAutoSwitch.bezelStyle = .rounded
        temperatureAutoSwitch.controlSize = .small
        temperatureAutoSwitch.title = "Auto"
        temperatureAutoSwitch.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        temperatureAutoSwitch.target = self; temperatureAutoSwitch.action = #selector(temperatureAutoChanged)
        temperatureAutoSwitch.toolTip = "Match the background: measure the background's average colour and shift your image's temperature toward it. Off, set it yourself."
        temperatureAutoSwitch.setContentHuggingPriority(.required, for: .horizontal)
        let temperatureCell = sliderCell("Temperature", \.temperature, -1...1, scale: 100, decimals: 0,
                                         tip: "Colour temperature of your image only. Left is cooler (bluer), right is warmer (more amber). Brightness stays the same. Layers are not affected.")
        self.temperatureCell = temperatureCell
        let temperatureRow = NSStackView(views: [temperatureCell, temperatureAutoSwitch])
        temperatureRow.spacing = 8
        temperatureRow.alignment = .bottom   // the button sits level with the slider, not the title
        let relightRow = columns([
            sliderCell("Relight", \.relight, 0...1, scale: 100, decimals: 0,
                       tip: "Lets the background light you: its colour wraps around your edges, and its brightest areas light your head from their direction, following where you face when face tracking is on. Needs a background layer."),
            sliderCell("Highlights", \.highlights, 0...1, scale: 100, decimals: 0,
                       tip: "How much the relight brightens the lit areas as well as tinting them. 0 keeps your brightness; 100 adds strong highlights."),
        ])
        let colorStack = NSStackView(views: [temperatureRow, relightRow])
        colorStack.orientation = .vertical
        colorStack.alignment = .leading
        colorStack.spacing = 8
        for v in colorStack.arrangedSubviews { v.widthAnchor.constraint(equalTo: colorStack.widthAnchor).isActive = true }
        colorBody = colorStack
        stack.addArrangedSubview(group("Lighting", trailing: colorSwitch, rows: [colorStack], tip: "Lighting and colour corrections applied to your image after keying, so it sits in the background."))

        // Shadow: distance switch in the header; opacity and blur beside the pad.
        offsetPad.onChange = { [weak self] v in
            self?.onParam?(\.shadowOffset.x, v.x); self?.onParam?(\.shadowOffset.y, v.y); self?.updateCompositeValues()
        }
        let padColumn = NSStackView(views: [offsetPad, offsetValue]); padColumn.orientation = .vertical; padColumn.alignment = .centerX; padColumn.spacing = 2
        offsetValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        offsetValue.textColor = .secondaryLabelColor
        offsetValue.alignment = .center
        offsetValue.widthAnchor.constraint(equalToConstant: 86).isActive = true   // editable fields have no intrinsic width
        offsetValue.onCommit = { [weak self] text in
            guard let self else { return }
            let parts = text.replacingOccurrences(of: "+", with: "").split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Float($0) }
            guard parts.count == 2 else { updateCompositeValues(); return }
            offsetPad.value = SIMD2(parts[0], parts[1]) / 100; offsetPad.onChange?(offsetPad.value)
        }
        // Two rows of sliders on the left; the pad spans both rows on the right.
        offsetPad.toolTip = "Drag to position the shadow. Double-click to reset. Matches the mirrored preview."
        offsetValue.toolTip = "Shadow offset in percent of the frame, x then y."
        depthSwitch.target = self; depthSwitch.action = #selector(depthChanged)
        depthSwitch.controlSize = .mini
        depthSwitch.toolTip = "Scale offset and size with face size: nearer is longer and softer, farther is shorter, sharper, denser"
        let depthLabel = NSTextField(labelWithString: "Vary with distance"); depthLabel.font = .systemFont(ofSize: 11)
        depthLabel.toolTip = depthSwitch.toolTip
        depthLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let depthRow = NSStackView(views: [depthLabel, depthSwitch]); depthRow.spacing = 6
        let shadowRow = NSGridView(views: [
            [sliderCell("Opacity", \.shadowOpacity, 0...1, scale: 100, decimals: 0, tip: "Strength of the drop shadow behind the subject, in percent."), padColumn],
            [sliderCell("Size", \.shadowBlur, 0...24, decimals: 0, tip: "How far the shadow spreads, in output pixels, independent of the source resolution. Larger is softer and fainter at the edge."), NSGridCell.emptyContentView],
            [depthRow, NSGridCell.emptyContentView],
        ])
        shadowRow.mergeCells(inHorizontalRange: NSRange(location: 1, length: 1), verticalRange: NSRange(location: 0, length: 3))
        shadowRow.rowSpacing = 8
        shadowRow.columnSpacing = 12
        shadowRow.xPlacement = .fill
        shadowRow.yPlacement = .top
        shadowRow.rowAlignment = .none
        shadowRow.column(at: 1).width = 86
        shadowRow.column(at: 1).xPlacement = .center
        shadowRow.cell(atColumnIndex: 1, rowIndex: 0).yPlacement = .center
        shadowSwitch.target = self; shadowSwitch.action = #selector(shadowToggled)
        shadowSwitch.controlSize = .mini
        shadowSwitch.toolTip = "Draw a soft shadow of the subject on the background"
        shadowBody = shadowRow
        shadowGroup = group("Shadow", trailing: shadowSwitch, rows: [shadowRow])
        stack.addArrangedSubview(shadowGroup)

        // Face tracking: switch in the header, one line on what it feeds.
        trackSwitch.controlSize = .mini
        trackSwitch.toolTip = "Face box and eyes on the preview; pose and eye data for web pages and the shadow."
        overlaySwitch.target = self; overlaySwitch.action = #selector(overlayChanged)
        overlaySwitch.controlSize = .mini
        overlaySwitch.toolTip = "Draw what the tracker knows on the preview: landmark contours, pupils, pose axes, and the distance and pose matrix. Never in the output."
        let overlayLabel = NSTextField(labelWithString: "Show on preview"); overlayLabel.font = .systemFont(ofSize: 11)
        overlayLabel.toolTip = overlaySwitch.toolTip
        overlayLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        overlayRow = NSStackView(views: [overlayLabel, overlaySwitch]); (overlayRow as! NSStackView).spacing = 6
        highRateSwitch.target = self; highRateSwitch.action = #selector(highRateChanged)
        highRateSwitch.controlSize = .mini
        highRateSwitch.toolTip = "Track every frame (30 Hz) with a face detection every other frame, instead of every second frame with a detection every fourth. Smoother pose and eye data for about twice the Neural Engine work."
        let highRateLabel = NSTextField(labelWithString: "High frame rate"); highRateLabel.font = .systemFont(ofSize: 11)
        highRateLabel.toolTip = highRateSwitch.toolTip
        highRateLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        highRateRow = NSStackView(views: [highRateLabel, highRateSwitch]); (highRateRow as! NSStackView).spacing = 6
        stack.addArrangedSubview(group("Face tracking", trailing: trackSwitch, rows: [highRateRow, overlayRow], tip: trackSwitch.toolTip))

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false   // content starts at the very top
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        doc.addSubview(connectedRow)   // in the document, so it scrolls with the groups
        scroll.documentView = doc
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            connectedRow.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -16),
            connectedRow.topAnchor.constraint(equalTo: doc.topAnchor, constant: 14),
        ])
        for v in stack.arrangedSubviews { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        updateSinkVisibility()
    }

    /// The inset-box look shared by the sidebar groups and the preview frame.
    /// A standard box, as System Settings draws its groups. NSBox follows the
    /// appearance on its own, so light and dark need no extra work.
    static func makeBox() -> NSBox {
        let box = NSBox()
        box.boxType = .primary
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        return box
    }

    /// Settings-style group: an inset box with a header row (title left,
    /// optional trailing view right) and a vertical list of rows.
    private func group(_ title: String, leading: NSView? = nil, titleView: NSView? = nil, trailing: NSView?, rows: [NSView], tip: String? = nil) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.toolTip = tip
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let header: NSView
        if let titleView {
            // A custom title (the Chromakey pull-down) hugs its text; a spacer stretches instead.
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            let titled = NSStackView(views: [titleView, spacer])
            titled.spacing = 0
            header = titled
        } else {
            header = label
        }
        // The title stretches; whatever sits on the trailing edge stays right-aligned.
        header.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        trailing?.setContentHuggingPriority(.required, for: .horizontal)
        trailing?.setContentCompressionResistancePriority(.required, for: .horizontal)
        leading?.setContentHuggingPriority(.required, for: .horizontal)
        let headerRow = NSStackView(views: (leading.map { [$0] } ?? []) + [header] + (trailing.map { [$0] } ?? []))
        headerRow.spacing = 8
        headerRow.distribution = .fill

        let box = Self.makeBox()
        let content = NSStackView(views: [headerRow] + rows)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            content.topAnchor.constraint(equalTo: box.topAnchor),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        for v in [headerRow] + rows { v.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true }
        return box
    }


    /// A list row: label on the left, a compact switch on the right.
    private func switchRow(_ title: String, _ toggle: NSSwitch, tip: String) -> NSView {
        toggle.controlSize = .mini
        toggle.toolTip = tip
        let label = NSTextField(labelWithString: title)
        label.toolTip = tip
        label.font = .systemFont(ofSize: 12)
        label.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, toggle])
        row.spacing = 8
        row.distribution = .fill
        return row
    }

    /// Cells side by side, equal widths.
    /// A small label on the left and a stretching control on the right.
    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 74).isActive = true
        label.toolTip = control.toolTip
        let row = NSStackView(views: [label, control])
        row.spacing = 6
        return row
    }

    private func columns(_ cells: [NSView]) -> NSView {
        let row = NSStackView(views: cells)
        row.spacing = 10
        row.distribution = .fillEqually
        row.alignment = .top
        return row
    }

    /// Shown value = stored × scale, with `decimals`. Typing or arrowing may leave the slider's range.
    private func sliderCell(_ title: String, _ keyPath: WritableKeyPath<KeyParams, Float>, _ range: ClosedRange<Float>,
                            scale: Float = 1, decimals: Int = 2, tip: String) -> ControlCell {
        let s = NSSlider(value: Double(range.lowerBound), minValue: Double(range.lowerBound),
                         maxValue: Double(range.upperBound), target: self, action: #selector(sliderChanged))
        s.isContinuous = true
        s.controlSize = .small
        let cell = ControlCell(title: title, control: s)
        cell.toolTip = tip; cell.label.toolTip = tip; s.toolTip = tip; cell.value.toolTip = tip
        cell.value.stringValue = Self.format(0, scale: scale, decimals: decimals)
        cell.value.onCommit = { [weak self] text in
            guard let self else { return }
            if let v = Float(text.trimmingCharacters(in: .whitespaces)) { set(keyPath, max(v / scale, range.lowerBound)) }
            else { cell.value.stringValue = Self.format(s.floatValue, scale: scale, decimals: decimals) }
        }
        cell.value.onStep = { [weak self] d in
            guard let self else { return }
            let step = powf(10, -Float(decimals)) / scale   // one shown unit
            set(keyPath, max(s.floatValue + d * step, range.lowerBound))
        }
        cells[keyPath] = (s, cell, range, scale, decimals)
        return cell
    }

    private static func format(_ v: Float, scale: Float, decimals: Int) -> String {
        String(format: "%.\(decimals)f", v * scale)
    }

    private func set(_ keyPath: WritableKeyPath<KeyParams, Float>, _ v: Float) {
        guard let (slider, cell, _, scale, decimals) = cells[keyPath] else { return }
        slider.floatValue = v
        cell.value.stringValue = Self.format(v, scale: scale, decimals: decimals)
        onParam?(keyPath, v)
    }

    private func updateCompositeValues() {
        // No readout above the track any more; the values live in its tooltip.
        let range = String(format: "%.0f – %.0f", keyRange.lower * 100, keyRange.upper * 100)
        keyRange.toolTip = "\(range)\n\n" + Self.keyRangeTip
        keyRange.setAccessibilityValue(range)
        offsetValue.stringValue = String(format: "%+.0f, %+.0f", offsetPad.value.x * 100, offsetPad.value.y * 100)
    }

    /// Match the pad's horizontal axis to the (mirrored) preview.
    var mirrorOffsetPad: Bool {
        get { offsetPad.flipX }
        set { offsetPad.flipX = newValue }
    }

    /// Live: the group hides behind the title-area indicator unless the user asked
    /// for detail. Not live: the group shows with its buttons and help.
    private func updateSinkVisibility() {
        sinkButtons.isHidden = sinkConnected
        statusLabel.isHidden = sinkConnected || statusLabel.stringValue.isEmpty
        if !sinkConnected { showSinkDetail = false }
        sinkGroup?.isHidden = sinkConnected && !showSinkDetail
        connectedRow?.isHidden = !sinkConnected
    }


    // MARK: State in

    /// The source choices: cameras and the test pattern, then the sample and recent movies.
    func setDevices(_ devices: [AVCaptureDevice], selected: AVCaptureDevice?, testPattern: Bool = false,
                    sample: Bool = false, videos: [String] = [], selectedVideo: String? = nil) {
        self.devices = devices
        videoPaths = videos
        if testPattern { sourceSelection = "testpattern" }
        else if sample { sourceSelection = "sample" }
        else if let selectedVideo { sourceSelection = "video:" + selectedVideo }
        else if let selected { sourceSelection = "camera:" + selected.uniqueID }
        else { sourceSelection = nil }
        let sections = sourceSections()
        if let current = sections.flatMap(\.items).first(where: { $0.value == sourceSelection }) {
            var shown = current
            if case .image = current.thumbnail { shown.thumbnail = .symbol("web.camera") }   // no stale frame in the sidebar
            sourceTile.show(shown)
            scheduleSourceThumbnail()
        } else {
            sourceTile.show(PickerItem(value: "", title: "None", thumbnail: .symbol("plus")))
        }
        if case .source? = pickerTarget { picker.update(sections: sections, selected: sourceSelection) }
    }

    private func sourceSections() -> [PickerSection] {
        var cameras: [PickerItem] = devices.map { device in
            let value = "camera:" + device.uniqueID
            let live = value == sourceSelection ? currentFrameImage?() : nil
            return PickerItem(value: value, title: device.localizedName, thumbnail: live.map { .image($0) } ?? .symbol("web.camera"))
        }
        cameras.append(PickerItem(value: "testpattern", title: "Test pattern", thumbnail: .symbol("rectangle.split.3x3"),
                                  tooltip: "A moving test pattern, for setting up without a camera."))
        var videos: [PickerItem] = []
        if let sample = Bundle.main.url(forResource: "Sample", withExtension: "mp4") {
            videos.append(PickerItem(value: "sample", title: "Sample video", thumbnail: .file(sample),
                                     tooltip: "A short green screen clip bundled with Silhouette, for trying the key without a backdrop."))
        }
        videos += videoPaths.map {
            PickerItem(value: "video:" + $0, title: PickerLabel.file($0), thumbnail: .file(URL(fileURLWithPath: $0)), tooltip: $0, removable: true)
        }
        return [PickerSection(title: "Cameras", items: cameras), PickerSection(title: "Videos", items: videos, add: .video)]
    }

    func apply(params: KeyParams) {
        for (keyPath, (slider, cell, _, scale, decimals)) in cells {
            let v = params[keyPath: keyPath]
            slider.floatValue = v
            cell.value.stringValue = Self.format(v, scale: scale, decimals: decimals)
        }
        keyRange.lower = params.tolerance
        keyRange.upper = params.tolerance + params.softness
        offsetPad.value = params.shadowOffset
        shadowSwitch.state = params.shadowEnabled > 0.5 ? .on : .off
        keySwitch.state = params.keyEnabled > 0.5 ? .on : .off
        colorSwitch.state = params.colorEnabled > 0.5 ? .on : .off
        fgMaskButton.isOn = params.fgMasked > 0.5
        fgBlendValue = min(max(Int(params.fgBlend + 0.5), 0), Self.blendModes.count - 1)
        fgBlendButton.isOn = fgBlendValue != 0
        fgBlendButton.toolTip = "Blend: \(Self.blendModes[fgBlendValue]). How the foreground combines with what is under it, as in an image editor." 
        refreshEnabledStates()
        updateCompositeValues()
        let cb = params.keyCbCr.x - 0.5, cr = params.keyCbCr.y - 0.5, luma = params.keyLuma
        let keyColor = Self.rgb(cb: cb, cr: cr, y: luma)
        keySwatch.layer?.backgroundColor = keyColor.cgColor

        // Track colours: walk from the key colour through neutral toward its
        // complement, which is the direction the chroma distance grows fastest.
        let len = max((cb * cb + cr * cr).squareRoot(), 1e-4)
        let dir = SIMD2<Float>(-cb / len, -cr / len)
        keyRange.colorAt = { d in Self.rgb(cb: cb + dir.x * d, cr: cr + dir.y * d, y: luma) }
    }

    /// Full-range BT.709 chroma offsets (−0.5…0.5) at a fixed mid luma, for the swatch and track.
    private static func rgb(cb: Float, cr: Float, y: Float = 0.6) -> NSColor {
        func c(_ v: Float) -> CGFloat { CGFloat(min(max(v, 0), 1)) }
        return NSColor(srgbRed: c(y + 1.5748 * cr), green: c(y - 0.1873 * cb - 0.4681 * cr), blue: c(y + 1.8556 * cb), alpha: 1)
    }

    /// What a layer shows: None, Test page, a URL, a path, or a hex colour.
    func showLayer(_ slot: LayerSlot, _ value: String) {
        layerValues[slot] = value
        var item = layerItem(value, slot: slot)
        if case .image = item.thumbnail, value != Self.testPageTitle { item.thumbnail = .web(URL(string: value) ?? URL(string: "https://example.com")!) }
        if case .image = item.thumbnail, value == Self.testPageTitle { item.thumbnail = .symbol("face.smiling") }
        // On the tile, an empty layer shows a plus: an invitation to pick something.
        if Self.layerKind(value) == .none { item.thumbnail = .symbol("plus") }
        let tile = slot == .foreground ? foregroundTile : backgroundTile
        tile?.show(item)
        tile?.optionsHidden = Self.layerKind(value) == .none
        if case .layer(let s)? = pickerTarget, s == slot { picker.update(sections: layerSections(slot), selected: value) }
    }

    /// "#abc", "#aabbcc", "#aabbccdd", or the same without the hash → "#AABBCC[DD]".
    static func hexColor(_ text: String) -> String? {
        var t = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard [3, 4, 6, 8].contains(t.count), t.allSatisfy(\.isHexDigit) else { return nil }
        if t.count <= 4 { t = t.map { "\($0)\($0)" }.joined() }
        return "#" + t.uppercased()
    }

    /// Recent URLs, file paths, and colours, most recent first.
    func setRecents(_ items: [String]) {
        recentURLs = items
        if case .layer(let slot)? = pickerTarget { picker.update(sections: layerSections(slot), selected: layerValues[slot]) }
    }

    private enum LayerKind { case none, testPage, file, web, color }
    private static func layerKind(_ value: String) -> LayerKind {
        if value == noneTitle || value.isEmpty { return .none }
        if value == testPageTitle { return .testPage }
        if hexColor(value) != nil { return .color }
        if value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix("file://") { return .file }
        return .web
    }

    /// The tile for a layer value. The current web page of `slot` shows its snapshot.
    private func layerItem(_ value: String, slot: LayerSlot?) -> PickerItem {
        let current = slot.map { layerValues[$0] == value } ?? false
        let snapshot = current ? slot.flatMap { layerSnapshot?($0) } : nil
        switch Self.layerKind(value) {
        case .none:
            return PickerItem(value: Self.noneTitle, title: "None", thumbnail: .symbol("nosign"))
        case .testPage:
            return PickerItem(value: value, title: "Test page", thumbnail: snapshot.map { .image($0) } ?? .symbol("face.smiling"),
                              tooltip: "The bundled face tracking demo page, transparent so it works as either layer.")
        case .color:
            let hex = Self.hexColor(value) ?? value
            return PickerItem(value: value, title: hex, thumbnail: .color(Self.nsColor(hex: hex) ?? .clear), removable: true)
        case .file:
            let path = value.hasPrefix("file://") ? (URL(string: value)?.path ?? value) : (value as NSString).expandingTildeInPath
            return PickerItem(value: value, title: PickerLabel.file(path), thumbnail: .file(URL(fileURLWithPath: path)), tooltip: path, removable: true)
        case .web:
            let url = URL(string: value.contains("://") ? value : "https://" + value) ?? URL(string: "https://example.com")!
            return PickerItem(value: value, title: PickerLabel.web(value), thumbnail: snapshot.map { .image($0) } ?? .web(url), tooltip: value, removable: true)
        }
    }

    private func layerSections(_ slot: LayerSlot) -> [PickerSection] {
        var files: [PickerItem] = [], webs: [PickerItem] = [], colors: [PickerItem] = []
        for value in recentURLs {
            let item = layerItem(value, slot: slot)
            switch Self.layerKind(value) {
            case .file: files.append(item)
            case .web: webs.append(item)
            case .color: colors.append(item)
            default: break
            }
        }
        return [
            PickerSection(title: "Built in", items: [layerItem(Self.noneTitle, slot: slot), layerItem(Self.testPageTitle, slot: slot)]),
            PickerSection(title: "Images and movies", items: files, add: .file),
            PickerSection(title: "Web pages", items: webs, add: .web),
            PickerSection(title: "Colors", items: colors, add: .color),
        ]
    }

    static func nsColor(hex: String) -> NSColor? {
        guard let normalized = hexColor(hex), let v = UInt64(normalized.dropFirst(), radix: 16) else { return nil }
        let hasAlpha = normalized.count == 9
        let rgb = hasAlpha ? v >> 8 : v
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: hasAlpha ? CGFloat(v & 0xFF) / 255 : 1)
    }

    // MARK: Picker

    func closePicker() { if picker.isShown { picker.close() } }

    @objc private func sourceTapped() { showSourcePicker() }
    @objc private func backgroundTapped() { showLayerPicker(.background) }
    @objc private func foregroundTapped() { showLayerPicker(.foreground) }

    func showSourcePicker() {
        pickerTarget = .source
        picker.show(title: "Source", sections: sourceSections(), selected: sourceSelection, from: sourceTile, edge: .minY)
    }

    /// Open a layer's picker; `entry` opens the web or colour field at once.
    func showLayerPicker(_ slot: LayerSlot, entry: PickerAddKind? = nil) {
        pickerTarget = .layer(slot)
        picker.show(title: slot == .foreground ? "Foreground" : "Background", sections: layerSections(slot),
                    selected: layerValues[slot], from: (slot == .foreground ? foregroundTile : backgroundTile)!, edge: .minY, openEntry: entry)
    }

    private func pickerChose(_ value: String) {
        switch pickerTarget {
        case .source?:
            if value.hasPrefix("camera:"), let device = devices.first(where: { "camera:" + $0.uniqueID == value }) { onCameraSelected?(device) }
            else if value == "testpattern" { onTestPatternSelected?() }
            else if value == "sample" { onSampleSelected?() }
            else if value.hasPrefix("video:") { onVideoSelected?(String(value.dropFirst(6))) }
        case .layer(let slot)?:
            commitLayer(slot, value)
        case nil: break
        }
    }

    private func pickerRemoved(_ value: String) {
        if value.hasPrefix("video:") { onRemoveVideo?(String(value.dropFirst(6))) } else { onRemoveRecent?(value) }
    }

    private func pickerAdded(_ kind: PickerAddKind, _ text: String?) {
        switch (kind, pickerTarget) {
        case (.video, _): onChooseVideo?()
        case (.file, .layer(let slot)?): onLayerChooseFile?(slot)
        case (.web, .layer(let slot)?), (.color, .layer(let slot)?):
            if let text { commitLayer(slot, text) }
        default: break
        }
    }



    var supersample: Bool {
        get { supersampleButton.isOn }
        set { supersampleButton.isOn = newValue; supersampleButton.setText(newValue ? "4K" : "HD") }
    }
    var trackFace: Bool {
        get { trackSwitch.state == .on }
        set { trackSwitch.state = newValue ? .on : .off; refreshEnabledStates() }
    }
    var shadowFollowsFace: Bool {
        get { depthSwitch.state == .on }
        set { depthSwitch.state = newValue ? .on : .off }
    }
    var mirrorPreview: Bool {
        get { mirrorButton.isOn }
        set { mirrorButton.isOn = newValue }
    }

    var status: String {
        get { statusLabel.stringValue }
        set { statusLabel.stringValue = newValue; updateSinkVisibility() }
    }

    var sinkConnected: Bool = false {
        didSet {
            guard sinkConnected != oldValue else { return }   // polled every second; relayout only on a change
            sinkStatus.stringValue = sinkConnected ? "Live" : "Not connected"
            sinkStatus.textColor = sinkConnected ? .labelColor : .secondaryLabelColor
            sinkDot.color = sinkConnected ? .systemGreen : .tertiaryLabelColor
            updateSinkVisibility()
        }
    }

    var highlightSettings: Bool = false {
        didSet { settingsButton.bezelColor = highlightSettings ? .controlAccentColor : nil }
    }

    var pickingKey: Bool = false {
        didSet {
            keyHint.stringValue = "Showing the unkeyed image. Click the backdrop in the preview; Esc cancels."
            keyHint.isHidden = !pickingKey
            keySwatch.layer?.borderColor = (pickingKey ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.2)).cgColor
            keySwatch.layer?.borderWidth = pickingKey ? 2 : 1
        }
    }

    // MARK: Actions


    @objc private func supersampleChanged() { supersample.toggle(); onSupersample?(supersample) }
    @objc private func trackChanged() { refreshEnabledStates(); onTrackFace?(trackSwitch.state == .on) }
    @objc private func depthChanged() { onShadowFollowsFace?(depthSwitch.state == .on) }
    @objc private func shadowToggled() {
        refreshEnabledStates()
        onParam?(\.shadowEnabled, shadowSwitch.state == .on ? 1 : 0)
    }
    @objc private func keyToggled() {
        refreshEnabledStates()
        onParam?(\.keyEnabled, keySwitch.state == .on ? 1 : 0)
    }
    @objc private func fgMaskToggled() { fgMaskButton.isOn.toggle(); onParam?(\.fgMasked, fgMaskButton.isOn ? 1 : 0) }

    /// The blend modes as a menu under the button, the current one checked.
    @objc private func fgBlendTapped() {
        let menu = NSMenu()
        for (i, name) in Self.blendModes.enumerated() {
            let item = NSMenuItem(title: name, action: #selector(fgBlendChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == fgBlendValue ? .on : .off
            menu.addItem(item)
            if i == 0 { menu.addItem(.separator()) }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: fgBlendButton)
    }

    @objc private func fgBlendChosen(_ sender: NSMenuItem) {
        fgBlendValue = sender.tag
        fgBlendButton.isOn = sender.tag != 0
        fgBlendButton.toolTip = "Blend: \(Self.blendModes[sender.tag]). How the foreground combines with what is under it, as in an image editor."
        onParam?(\.fgBlend, Float(sender.tag))
    }
    @objc private func colorToggled() {
        refreshEnabledStates()
        onParam?(\.colorEnabled, colorSwitch.state == .on ? 1 : 0)
    }

    /// Collapse what a switched-off section makes moot, leaving its header.
    /// Section switches are never disabled, so a section can always be turned
    /// back on. With the key off, the Shadow body collapses too, since there is
    /// no matte to cast it.
    private func refreshEnabledStates() {
        let keyOn = keySwitch.state == .on
        let shadowOn = shadowSwitch.state == .on
        let colorOn = colorSwitch.state == .on
        let trackOn = trackSwitch.state == .on
        chromaBody.isHidden = !keyOn
        shadowBody.isHidden = !(keyOn && shadowOn)
        overlayRow.isHidden = !trackOn
        highRateRow.isHidden = !trackOn
        colorBody.isHidden = !colorOn
        for toggle in [keySwitch, shadowSwitch, colorSwitch, trackSwitch] { toggle.isEnabled = true }
        // Within Color, Auto drives the temperature, so the slider dims while it is on.
        let manual = temperatureAutoSwitch.state == .off
        temperatureCell.alphaValue = manual ? 1 : 0.45
        func enable(_ v: NSView) { (v as? NSControl)?.isEnabled = manual; v.subviews.forEach(enable) }
        enable(temperatureCell)
    }

    var temperatureAuto: Bool {
        get { temperatureAutoSwitch.state == .on }
        set { temperatureAutoSwitch.state = newValue ? .on : .off; refreshEnabledStates() }
    }
    @objc private func temperatureAutoChanged() { refreshEnabledStates(); onTemperatureAuto?(temperatureAutoSwitch.state == .on) }

    /// Show the automatic temperature in the slider without treating it as a user change.
    func showTemperature(_ value: Float) {
        guard let (slider, cell, _, scale, decimals) = cells[\.temperature] else { return }
        slider.floatValue = value
        cell.value.stringValue = Self.format(value, scale: scale, decimals: decimals)
    }

    var faceHighRate: Bool {
        get { highRateSwitch.state == .on }
        set { highRateSwitch.state = newValue ? .on : .off }
    }
    @objc private func highRateChanged() { onFaceHighRate?(highRateSwitch.state == .on) }

    var faceOverlay: Bool {
        get { overlaySwitch.state == .on }
        set { overlaySwitch.state = newValue ? .on : .off }
    }
    @objc private func overlayChanged() { onFaceOverlay?(overlaySwitch.state == .on) }
    /// Pause shows while live; play shows while frozen.
    var frozen: Bool = false {
        didSet {
            freezeButton.setSymbol(frozen ? "play.fill" : "pause.fill", description: frozen ? "Resume live video" : "Freeze frame")
            freezeButton.isOn = frozen
            freezeButton.toolTip = frozen
                ? "Frozen on one frame. Click to go back to live video."
                : "Freeze the current frame so you can tune the key without movement. The virtual camera shows the frozen frame until you resume."
        }
    }
    @objc private func freezeTapped() { frozen.toggle(); onFreeze?(frozen) }

    /// Which matte the chromakey group is set up for. Person hides the colour tools.
    var matteSource: Int {
        get { matteSourceValue }
        set {
            matteSourceValue = newValue == 1 ? 1 : 0   // Apple Chromakey keys like Chromakey
            let person = matteSourceValue == 1
            let title = person ? "Background Removal" : "Chromakey"
            var titleColor = NSColor.labelColor.withAlphaComponent(0.72)
            effectiveAppearance.performAsCurrentDrawingAppearance {   // resolve now; the title keeps the resolved colour
                titleColor = NSColor(cgColor: NSColor.labelColor.withAlphaComponent(0.72).cgColor) ?? titleColor
            }
            matteMenu.item(at: 0)?.attributedTitle = NSAttributedString(string: title.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: titleColor])   // the pull-down dims its title; this lands on the other headers' grey
            for item in matteMenu.itemArray where item.action == #selector(matteChosen(_:)) {
                item.state = item.tag == matteSourceValue ? .on : .off
            }
            keyRangeRow.isHidden = person   // background removal has no key colour or range
            if let spill = cells[\.spill]?.cell {   // same slider, different job per mode
                spill.label.stringValue = person ? "Decontaminate" : "Desaturate"
                let tip = person
                    ? "Removes the background colour mixed into the subject's edge pixels, in percent. Hair and soft edges stop carrying the room's colour."
                    : "Removes the backdrop's tint reflected onto hair and clothing, in percent."
                spill.toolTip = tip; spill.label.toolTip = tip; spill.value.toolTip = tip; spill.control.toolTip = tip
            }
        }
    }
    private var matteSourceValue = 0

    @objc private func matteChosen(_ sender: NSMenuItem) {
        guard sender.tag != matteSourceValue else { return }
        matteSource = sender.tag
        onMatteSource?(sender.tag)
    }

    @objc private func appleChromakeyChosen() { onAppleChromakey?() }

    /// Auto is running: the button shows it and ignores clicks.
    var autoRunning: Bool = false {
        didSet {
            autoButton.isEnabled = !autoRunning
            updateAutoButtonFill()
        }
    }

    /// Capsule fill for Auto: a quiet grey, accent while it runs; re-resolved for light and dark.
    private func updateAutoButtonFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            autoButton.layer?.backgroundColor = (autoRunning ? NSColor.controlAccentColor.withAlphaComponent(0.35) : NSColor.quaternaryLabelColor).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAutoButtonFill()
        // The pull-down's attributed title holds a resolved colour; redraw it for this appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance { matteSource = matteSourceValue }
    }

    /// A line under the Chromakey controls, cleared after `seconds` (nil keeps it).
    func showKeyHint(_ text: String?, for seconds: TimeInterval? = nil) {
        hintTimer?.invalidate(); hintTimer = nil
        guard let text else { keyHint.isHidden = true; return }
        keyHint.stringValue = text
        keyHint.isHidden = false
        if let seconds {
            hintTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.keyHint.isHidden = true }
        }
    }

    @objc private func mirrorChanged() { mirrorButton.isOn.toggle(); onMirrorPreview?(mirrorButton.isOn) }

    /// The current camera's tile shows a still from it, taken once frames are flowing.
    private func scheduleSourceThumbnail() {
        guard let selection = sourceSelection, selection.hasPrefix("camera:") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, sourceSelection == selection, let image = currentFrameImage?(),
                  var item = sourceSections().flatMap(\.items).first(where: { $0.value == selection }) else { return }
            item.thumbnail = .image(image)
            sourceTile.show(item)
        }
    }

    @objc private func connectedTapped() {
        showSinkDetail.toggle()
        sinkGroup.isHidden = !showSinkDetail
    }


    /// Route a committed combo value: a fixed item, a colour, a file path, or a URL.
    private func commitLayer(_ slot: LayerSlot, _ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case Self.noneTitle, "": onLayerNone?(slot)
        case Self.chooseTitle: onLayerChooseFile?(slot)
        case Self.testPageTitle: onLayerWeb?(slot, "")
        default:
            if let hex = Self.hexColor(text) {
                onLayerColor?(slot, hex)
            } else if text.hasPrefix("/") || text.hasPrefix("~") {
                onLayerFile?(slot, (text as NSString).expandingTildeInPath)
            } else if text.hasPrefix("file://"), let url = URL(string: text) {
                onLayerFile?(slot, url.path)
            } else {
                onLayerWeb?(slot, text)
            }
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let (keyPath, entry) = cells.first(where: { $0.value.slider === sender }) else { return }
        entry.cell.value.stringValue = Self.format(sender.floatValue, scale: entry.scale, decimals: entry.decimals)
        onParam?(keyPath, sender.floatValue)
    }

    @objc private func installTapped() { onInstall?() }
    @objc private func settingsTapped() { onOpenSettings?() }
    @objc private func pickKeyTapped() { onPickKey?() }
    @objc private func autoKeyTapped() { onAutoKey?() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Small filled circle for status.
final class StatusDot: NSView {
    var color: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
