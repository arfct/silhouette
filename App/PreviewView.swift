import AppKit
import simd

/// Displays the renderer's IOSurface directly as layer contents. No extra
/// draw pass: Core Animation scales the surface to the view. The preview is
/// mirrored like a mirror; the virtual camera output is not.
final class PreviewView: NSView {
    /// Normalised point in output space, origin top-left.
    var onPick: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    var pickingCursor = false { didSet { window?.invalidateCursorRects(for: self) } }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        if pickingCursor { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }   // 53 = Escape
    }

    private let imageLayer = CALayer()
    private let overlay = CAShapeLayer()
    /// Readout with angles, distance, and the pose matrix.
    private let readout = CATextLayer()
    /// Draw the tracking overlay at all. The tracker itself is separate.
    var showFaceOverlay = true { didSet { if !showFaceOverlay { showFace(nil) } } }
    /// Checkerboard or black, sized to the aspect-fitted image only.
    private let backdropLayer = CALayer()
    private static let aspect = CGFloat(VirtualCameraConstants.width) / CGFloat(VirtualCameraConstants.height)

    /// Where the aspect-fitted image sits inside the view (layer coordinates).
    private var imageRect: CGRect {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return b }
        if b.width / b.height > Self.aspect {
            let w = b.height * Self.aspect
            return CGRect(x: (b.width - w) / 2, y: 0, width: w, height: b.height)
        } else {
            let h = b.width / Self.aspect
            return CGRect(x: 0, y: (b.height - h) / 2, width: b.width, height: h)
        }
    }

    enum Backdrop { case checkerboard, black }

    /// Checkerboard behind the keyed image when there is no background (the
    /// virtual camera output is transparent there); black when one is composited.
    var backdrop: Backdrop = .checkerboard {
        didSet { backdropLayer.backgroundColor = backdrop == .black ? NSColor.black.cgColor : Self.checkerboard }
    }

    private static let checkerboard: CGColor = {
        let size = 16
        let image = NSImage(size: NSSize(width: size * 2, height: size * 2), flipped: false) { rect in
            NSColor(white: 0.42, alpha: 1).setFill(); rect.fill()
            NSColor(white: 0.52, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: size, height: size).fill()
            NSRect(x: size, y: size, width: size, height: size).fill()
            return true
        }
        return NSColor(patternImage: image).cgColor
    }()

    /// Mirror the preview like a mirror. Off shows exactly what the virtual camera sends.
    var mirrored = true {
        didSet {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            imageLayer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
            CATransaction.commit()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = nil
        backdropLayer.backgroundColor = Self.checkerboard
        layer?.addSublayer(backdropLayer)
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        imageLayer.transform = CATransform3DMakeScale(-1, 1, 1)
        layer?.addSublayer(imageLayer)
        overlay.fillColor = nil
        overlay.strokeColor = NSColor.systemGreen.cgColor
        overlay.lineWidth = 1.5
        overlay.lineJoin = .round
        overlay.isHidden = true
        imageLayer.addSublayer(overlay)
        readout.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        readout.fontSize = 10
        readout.foregroundColor = NSColor.white.cgColor
        readout.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        readout.cornerRadius = 5
        readout.isWrapped = true
        readout.isHidden = true
        layer?.addSublayer(readout)   // on the root layer, so the text is not mirrored
        registerForDraggedTypes([.fileURL, .URL])
    }

    /// Draw the tracked features over the preview (never in the output): landmark contours and pupils.
    func showFace(_ face: FaceState?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let all: [CALayer] = [overlay, readout]
        guard showFaceOverlay, let face, face.detected, let box = face.box else { all.forEach { $0.isHidden = true }; return }
        let r = imageRect
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: r.minX + CGFloat(x) * r.width, y: r.minY + (1 - CGFloat(y)) * r.height) }

        // 2D: contours and pupils.
        let path = CGMutablePath()
        for (name, points) in face.contours ?? [:] where points.count > 1 {
            path.move(to: pt(points[0].x, points[0].y))
            for p in points.dropFirst() { path.addLine(to: pt(p.x, p.y)) }
            if ["leftEye", "rightEye", "outerLips", "innerLips"].contains(name) { path.closeSubpath() }
        }
        for eye in [face.leftEye, face.rightEye].compactMap({ $0 }) {
            let c = pt(eye.x, eye.y)
            path.addEllipse(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
        }
        overlay.path = path
        overlay.isHidden = false

        _ = box
        readout.isHidden = true   // the numbers live in the web API; the preview shows only the features
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = bounds
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        backdropLayer.frame = imageRect
        overlay.frame = imageLayer.bounds
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError() }

    var onDrop: ((URL) -> Void)?

    func display(surface: IOSurfaceRef?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = surface
        CATransaction.commit()
    }

    private var dragStart: NSPoint = .zero
    private var dragged = false

    /// Click picks the key colour; drag moves the (title-bar-less) window.
    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        if hypot(event.locationInWindow.x - dragStart.x, event.locationInWindow.y - dragStart.y) >= 4 { dragged = true }
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragged else { return }
        let p = convert(event.locationInWindow, from: nil)
        let r = imageRect
        guard r.contains(p) else { return }
        let x = (p.x - r.minX) / r.width
        onPick?(CGPoint(x: mirrored ? 1 - x : x, y: 1 - (p.y - r.minY) / r.height))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        guard let url = urls.first else { return false }
        onDrop?(url)
        return true
    }
}
