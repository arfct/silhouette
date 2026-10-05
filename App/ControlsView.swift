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

    private let knobRadius: CGFloat = 7
    private var activeThumb = 0

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 20) }

    private func x(for v: Float) -> CGFloat {
        let t = min(max((v - minValue) / (maxValue - minValue), 0), 1)   // typed values may sit outside the track
        return knobRadius + CGFloat(t) * (bounds.width - 2 * knobRadius)
    }
    private func value(forX x: CGFloat) -> Float {
        let t = Float((x - knobRadius) / max(bounds.width - 2 * knobRadius, 1))
        return min(max(minValue + t * (maxValue - minValue), minValue), maxValue)
    }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        if let colorAt {
            drawColorTrack(colorAt, midY: midY)
        } else {
            let track = NSRect(x: knobRadius, y: midY - 2, width: bounds.width - 2 * knobRadius, height: 4)
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
        let h: CGFloat = 10
        let track = NSRect(x: knobRadius, y: midY - h / 2, width: bounds.width - 2 * knobRadius, height: h)
        let clip = NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3)
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

final class ControlsView: NSView, NSComboBoxDelegate {
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
    var onChromakeyOpen: ((Bool) -> Void)?
    var onFaceOverlay: ((Bool) -> Void)?
    /// 0 = chroma key, 1 = person segmentation.
    var onMatteSource: ((Int) -> Void)?
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

    let urlField = NSComboBox(frame: .zero)
    let fgField = NSComboBox(frame: .zero)
    private var recentURLs: [String] = []
    /// The list shows the end of long entries; this maps what it shows back to the value.
    private var displayToValue: [String: String] = [:]

    private let cameraPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let supersampleSwitch = NSSwitch()
    private let trackSwitch = NSSwitch()
    private let overlaySwitch = NSSwitch()
    private let freezeButton = NSButton(title: "", target: nil, action: nil)
    private var overlayRow: NSView!
    private let highRateSwitch = NSSwitch()
    private var highRateRow: NSView!
    private let depthSwitch = NSSwitch()
    private let shadowSwitch = NSSwitch()
    private var shadowBody: NSView!
    private var shadowGroup: NSView!
    private let keySwitch = NSSwitch()
    private var keyTools: NSStackView!
    private let matteControl = NSSegmentedControl(labels: ["Green screen", "Person"], trackingMode: .selectOne, target: nil, action: nil)
    private let mirrorSwitch = NSSwitch()
    private let sinkDot = StatusDot()
    private var sinkGroup: NSView!
    private var showSinkDetail = false
    /// Title-bar indicator shown while the virtual camera is live; tapping it shows the detail.
    private let connectedButton = NSButton(title: "Connected", target: nil, action: nil)
    private let connectedDot = StatusDot()
    private var chromaBody: NSView!
    private var connectedRow: NSStackView!
    private let chromaDisclosure = NSButton(title: "", target: nil, action: nil)
    private let offsetValue = ValueField(frame: .zero)
    private let keySwatch = NSButton(title: "", target: nil, action: nil)
    private let keyHint = NSTextField(wrappingLabelWithString: "")
    private let autoButton = NSButton(title: "Auto", target: nil, action: nil)
    private var hintTimer: Timer?
    private let keyRange = RangeSlider()
    private let offsetPad = OffsetPad()
    /// `scale` and `decimals` turn the stored value into what the field shows (percent, pixels).
    private var cells: [WritableKeyPath<KeyParams, Float>: (slider: NSSlider, cell: ControlCell, range: ClosedRange<Float>, scale: Float, decimals: Int)] = [:]
    private let keyLow = ValueField(frame: .zero)
    private let keyHigh = ValueField(frame: .zero)
    private var keyFieldWidths: [NSLayoutConstraint] = []
    private var keyRangeCell: ControlCell!
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

        // Source: camera, then switch rows.
        cameraPopup.target = self
        cameraPopup.action = #selector(cameraChanged)
        supersampleSwitch.target = self; supersampleSwitch.action = #selector(supersampleChanged)
        trackSwitch.target = self; trackSwitch.action = #selector(trackChanged)
        cameraPopup.toolTip = "Video source: a camera, a movie file, or the built-in test pattern."
        mirrorSwitch.target = self; mirrorSwitch.action = #selector(mirrorChanged)
        let toggles = NSStackView(views: [
            inlineSwitch("4K", supersampleSwitch, tip: "Capture and key at 3840×2160 when the camera supports it, then downsample to the 1080p output. Finer hair and edges, about four times the GPU work."),
            inlineSwitch("Mirror", mirrorSwitch, tip: "Mirror the preview of a live camera like a mirror. Movies and the test pattern always show as recorded, and the virtual camera output is never mirrored."),
        ])
        toggles.spacing = 14
        toggles.distribution = .equalSpacing
        freezeButton.bezelStyle = .accessoryBarAction
        freezeButton.isBordered = false
        freezeButton.imagePosition = .imageOnly
        freezeButton.target = self
        freezeButton.action = #selector(freezeTapped)
        frozen = false
        stack.addArrangedSubview(group("Source", trailing: freezeButton, rows: [cameraPopup, toggles]))

        // Layers: one combo box each for the background (behind the keyed camera)
        // and the foreground (over it). None, the test page, recent URLs, files and
        // colours, and Choose File…; or type a URL, a path, or a hex colour.
        for (field, what) in [(urlField, "behind you"), (fgField, "in front of you")] {
            field.placeholderString = "URL, file path, or #hex"
            field.isEditable = true
            field.completes = false
            field.numberOfVisibleItems = 13
            field.target = self
            field.action = #selector(urlEntered(_:))
            field.delegate = self
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingHead
            field.cell?.lineBreakMode = .byTruncatingHead
            field.stringValue = Self.noneTitle
            field.toolTip = "What shows \(what): nothing, the bundled test page, a web page URL, an image or movie file, or a hex colour like #1E90FF (8 digits for alpha). Pick from the list or type and press Return."
        }
        rebuildURLItems()
        stack.addArrangedSubview(group("Layers", trailing: nil, rows: [labeled("Background", urlField), labeled("Foreground", fgField)]))

        // Key: swatch, Pick and Auto in the header; range and spill below.
        keySwatch.isBordered = false
        keySwatch.wantsLayer = true
        keySwatch.layer?.cornerRadius = 4
        keySwatch.layer?.borderWidth = 1
        keySwatch.layer?.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor
        keySwatch.widthAnchor.constraint(equalToConstant: 36).isActive = true   // a mini switch's width
        keySwatch.heightAnchor.constraint(equalToConstant: 18).isActive = true
        keySwatch.target = self
        keySwatch.action = #selector(pickKeyTapped)
        keySwatch.toolTip = "The backdrop colour being removed. Click to show the unkeyed image, then click the backdrop in the preview. Esc cancels."
        autoButton.title = "Auto"; autoButton.target = self; autoButton.action = #selector(autoKeyTapped); autoButton.controlSize = .mini
        autoButton.toolTip = "Find the backdrop colour and range from the edges of the frame over about a second, avoiding the face and body. Runs by itself when a new source is chosen."
        keySwitch.target = self; keySwitch.action = #selector(keyToggled)
        keySwitch.controlSize = .mini
        keySwitch.toolTip = "Key out the backdrop. Off passes the camera through untouched, so the background and shadow have no effect."
        let keyTools = NSStackView(views: [keySwatch, autoButton, keySwitch]); keyTools.spacing = 8
        self.keyTools = keyTools
        keyHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keyHint.textColor = .secondaryLabelColor
        keyHint.preferredMaxLayoutWidth = Self.width - 48
        keyHint.isHidden = true
        keyRange.minValue = 0; keyRange.maxValue = 0.3
        keyRange.onChange = { [weak self] lo, hi in
            self?.onParam?(\.tolerance, lo); self?.onParam?(\.softness, hi - lo); self?.updateCompositeValues()
        }
        keyRangeCell = rangeCell("Color Range", keyRange, tip: "How close a colour must be to the key colour to be removed, in percent of the full chroma span. Left value: fully removed. Right value: where the transition to opaque ends. Typical keys sit between 5 and 20; type or arrow past 30 if needed.")
        // Chromakey: key colour and matte in one collapsible group.
        matteControl.target = self
        matteControl.action = #selector(matteChanged)
        matteControl.selectedSegment = 0
        matteControl.segmentDistribution = .fillEqually
        matteControl.controlSize = .small
        matteControl.toolTip = "Green screen keys a real backdrop by colour. Person finds you with on-device segmentation and needs no backdrop; it costs a few milliseconds per frame on the Neural Engine and edges are softer."
        let body = NSStackView(views: [
            matteControl,
            keyRangeCell,
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
        chromaDisclosure.bezelStyle = .disclosure
        chromaDisclosure.setButtonType(.pushOnPushOff)
        chromaDisclosure.target = self
        chromaDisclosure.action = #selector(chromaToggled)
        chromaDisclosure.toolTip = "Show or hide the chromakey controls"
        stack.addArrangedSubview(group("Chromakey", leading: chromaDisclosure, trailing: keyTools, rows: [body, keyHint]))   // hint stays visible when collapsed
        chromakeyOpen = false

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
        stack.addArrangedSubview(group("Face tracking", trailing: trackSwitch, rows: [overlayRow, highRateRow], tip: trackSwitch.toolTip))

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
    private func group(_ title: String, leading: NSView? = nil, trailing: NSView?, rows: [NSView], tip: String? = nil) -> NSView {
        let header = NSTextField(labelWithString: title.uppercased())
        header.toolTip = tip
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
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

    /// Label and compact switch side by side, for several on one line.
    private func inlineSwitch(_ title: String, _ toggle: NSSwitch, tip: String) -> NSView {
        toggle.controlSize = .mini
        toggle.toolTip = tip
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.toolTip = tip
        let row = NSStackView(views: [label, toggle])
        row.spacing = 5
        return row
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

    /// Two fields, low and high, in percent of the chroma span (stored value × 100).
    /// Typed or stepped values may go past the slider's track.
    private func rangeCell(_ title: String, _ slider: RangeSlider, tip: String) -> ControlCell {
        let dash = NSTextField(labelWithString: "–")
        dash.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        dash.textColor = .secondaryLabelColor
        for field in [keyLow, keyHigh] {   // sized to their text; see updateCompositeValues
            let w = field.widthAnchor.constraint(equalToConstant: 14)
            w.isActive = true
            keyFieldWidths.append(w)
            field.toolTip = tip
        }
        keyHigh.alignment = .left   // hugs the dash from the right as the low field does from the left
        let cell = ControlCell(title: title, control: slider, valueViews: [keyLow, dash, keyHigh])
        cell.toolTip = tip; cell.label.toolTip = tip; slider.toolTip = tip
        func apply(lo: Float, hi: Float) {
            let lo = max(lo, 0), hi = max(hi, lo + slider.minGap)
            slider.lower = lo; slider.upper = hi
            slider.onChange?(lo, hi)
        }
        keyLow.onCommit = { [weak self] text in
            if let v = Float(text.trimmingCharacters(in: .whitespaces)) { apply(lo: v / 100, hi: max(slider.upper, v / 100 + slider.minGap)) }
            self?.updateCompositeValues()
        }
        keyHigh.onCommit = { [weak self] text in
            if let v = Float(text.trimmingCharacters(in: .whitespaces)) { apply(lo: min(slider.lower, v / 100 - slider.minGap), hi: v / 100) }
            self?.updateCompositeValues()
        }
        keyLow.onStep = { d in apply(lo: slider.lower + d / 100, hi: max(slider.upper, slider.lower + d / 100 + slider.minGap)) }
        keyHigh.onStep = { d in apply(lo: min(slider.lower, slider.upper + d / 100 - slider.minGap), hi: slider.upper + d / 100) }
        return cell
    }

    private func set(_ keyPath: WritableKeyPath<KeyParams, Float>, _ v: Float) {
        guard let (slider, cell, _, scale, decimals) = cells[keyPath] else { return }
        slider.floatValue = v
        cell.value.stringValue = Self.format(v, scale: scale, decimals: decimals)
        onParam?(keyPath, v)
    }

    private func updateCompositeValues() {
        keyLow.stringValue = String(format: "%.0f", keyRange.lower * 100)
        keyHigh.stringValue = String(format: "%.0f", keyRange.upper * 100)
        for (field, width) in zip([keyLow, keyHigh], keyFieldWidths) {   // editable fields have no intrinsic width
            width.constant = ceil((field.stringValue as NSString).size(withAttributes: [.font: field.font!]).width) + 6
        }
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

    var chromakeyOpen: Bool = false {
        didSet {
            chromaBody.isHidden = !chromakeyOpen
            chromaDisclosure.state = chromakeyOpen ? .on : .off
        }
    }

    // MARK: State in

    /// Items: devices, separator, Test pattern, Sample video, recent movies, separator, Video file…
    func setDevices(_ devices: [AVCaptureDevice], selected: AVCaptureDevice?, testPattern: Bool = false,
                    sample: Bool = false, videos: [String] = [], selectedVideo: String? = nil) {
        self.devices = devices
        videoPaths = videos
        cameraPopup.removeAllItems()
        cameraPopup.addItems(withTitles: devices.map(\.localizedName))
        cameraPopup.menu?.addItem(.separator())
        cameraPopup.addItem(withTitle: "Test pattern")
        cameraPopup.addItem(withTitle: "Sample video")
        cameraPopup.lastItem?.toolTip = "A short green screen clip bundled with Silhouette, for trying the key without a backdrop."
        for path in videos {
            let item = NSMenuItem(title: (path as NSString).lastPathComponent, action: nil, keyEquivalent: "")
            item.toolTip = path
            cameraPopup.menu?.addItem(item)
        }
        cameraPopup.menu?.addItem(.separator())
        cameraPopup.addItem(withTitle: "Video file…")
        if testPattern {
            cameraPopup.selectItem(at: devices.count + 1)
        } else if sample {
            cameraPopup.selectItem(at: devices.count + 2)
        } else if let selectedVideo, let i = videos.firstIndex(of: selectedVideo) {
            cameraPopup.selectItem(at: devices.count + 3 + i)
        } else if let selected, let i = devices.firstIndex(where: { $0.uniqueID == selected.uniqueID }) {
            cameraPopup.selectItem(at: i)
        }
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

    /// What a layer's box shows: None, Test page, a URL, a path, or a hex colour.
    func showLayer(_ slot: LayerSlot, _ value: String) {
        (slot == .foreground ? fgField : urlField).stringValue = value
    }

    /// "#abc", "#aabbcc", "#aabbccdd", or the same without the hash → "#AABBCC[DD]".
    static func hexColor(_ text: String) -> String? {
        var t = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard [3, 4, 6, 8].contains(t.count), t.allSatisfy(\.isHexDigit) else { return nil }
        if t.count <= 4 { t = t.map { "\($0)\($0)" }.joined() }
        return "#" + t.uppercased()
    }

    /// Recent URLs and file paths, most recent first.
    func setRecents(_ items: [String]) {
        recentURLs = items
        rebuildURLItems()
    }

    private func rebuildURLItems() {
        let current = urlField.stringValue
        displayToValue = [:]
        let shown = recentURLs.map { value -> String in
            let display = Self.elideHead(value)
            displayToValue[display] = value
            return display
        }
        let fgCurrent = fgField.stringValue
        for field in [urlField, fgField] {
            field.removeAllItems()
            field.addItems(withObjectValues: [Self.noneTitle, Self.testPageTitle] + shown + [Self.chooseTitle])
        }
        urlField.stringValue = current
        fgField.stringValue = fgCurrent
    }

    /// Keep the tail of a long path or URL: that is the part that differs.
    private static func elideHead(_ text: String, max: Int = 32) -> String {
        text.count <= max ? text : "…" + text.suffix(max - 1)
    }


    var supersample: Bool {
        get { supersampleSwitch.state == .on }
        set { supersampleSwitch.state = newValue ? .on : .off }
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
        get { mirrorSwitch.state == .on }
        set { mirrorSwitch.state = newValue ? .on : .off }
    }

    var status: String {
        get { statusLabel.stringValue }
        set { statusLabel.stringValue = newValue; updateSinkVisibility() }
    }

    var sinkConnected: Bool = false {
        didSet {
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

    @objc private func cameraChanged() {
        let i = cameraPopup.indexOfSelectedItem
        let firstVideo = devices.count + 3
        if devices.indices.contains(i) { onCameraSelected?(devices[i]) }
        else if i == devices.count + 1 { onTestPatternSelected?() }
        else if i == devices.count + 2 { onSampleSelected?() }
        else if i >= firstVideo && i < firstVideo + videoPaths.count { onVideoSelected?(videoPaths[i - firstVideo]) }
        else if i == cameraPopup.numberOfItems - 1 { onChooseVideo?() }
    }

    @objc private func supersampleChanged() { onSupersample?(supersampleSwitch.state == .on) }
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

    /// Dim and disable what a switched-off feature makes moot: with the key off,
    /// its controls and the whole Shadow group; with the shadow off, its body.
    private func refreshEnabledStates() {
        let keyOn = keySwitch.state == .on
        let shadowOn = shadowSwitch.state == .on
        func set(_ view: NSView, _ on: Bool, except: NSControl? = nil) {
            view.alphaValue = on ? 1 : 0.45
            func walk(_ v: NSView) {
                if let c = v as? NSControl, c !== except { c.isEnabled = on }
                v.subviews.forEach(walk)
            }
            walk(view)
        }
        set(chromaBody, keyOn)
        set(keyTools, keyOn, except: keySwitch)
        keySwitch.isEnabled = true
        set(shadowGroup, keyOn)
        if keyOn { set(shadowBody, shadowOn) }
        set(overlayRow, trackSwitch.state == .on)
        set(highRateRow, trackSwitch.state == .on)
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
            let name = frozen ? "play.fill" : "pause.fill"
            freezeButton.image = NSImage(systemSymbolName: name, accessibilityDescription: frozen ? "Resume live video" : "Freeze frame")
            freezeButton.contentTintColor = frozen ? .controlAccentColor : .secondaryLabelColor
            freezeButton.toolTip = frozen
                ? "Frozen on one frame. Click to go back to live video."
                : "Freeze the current frame so you can tune the key without movement. The virtual camera shows the frozen frame until you resume."
        }
    }
    @objc private func freezeTapped() { frozen.toggle(); onFreeze?(frozen) }

    /// Which matte the chromakey group is set up for. Person hides the colour tools.
    var matteSource: Int {
        get { matteControl.selectedSegment }
        set {
            matteControl.selectedSegment = newValue
            let person = newValue == 1
            keyRangeCell.isHidden = person
            keySwatch.isHidden = person
            autoButton.isHidden = person
            cells[\.spill]?.cell.isHidden = person   // spill suppression is a chroma idea
        }
    }
    @objc private func matteChanged() { matteSource = matteControl.selectedSegment; onMatteSource?(matteControl.selectedSegment) }

    /// Auto is running: the button shows it and ignores clicks.
    var autoRunning: Bool = false {
        didSet {
            autoButton.isEnabled = !autoRunning
            autoButton.title = autoRunning ? "Auto…" : "Auto"
        }
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

    @objc private func mirrorChanged() { onMirrorPreview?(mirrorSwitch.state == .on) }

    @objc private func connectedTapped() {
        showSinkDetail.toggle()
        sinkGroup.isHidden = !showSinkDetail
    }

    @objc private func chromaToggled() {
        chromakeyOpen = chromaDisclosure.state == .on
        onChromakeyOpen?(chromakeyOpen)
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

    private func slot(of field: AnyObject?) -> LayerSlot { field === fgField ? .foreground : .background }

    @objc private func urlEntered(_ sender: NSComboBox) { commitLayer(slot(of: sender), sender.stringValue) }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSComboBox else { return }
        let i = field.indexOfSelectedItem
        guard i >= 0, let item = field.itemObjectValue(at: i) as? String else { return }
        commitLayer(slot(of: field), displayToValue[item] ?? item)
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
