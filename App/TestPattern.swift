import AppKit
import CoreVideo

/// Synthetic camera: a chroma-green backdrop with a few foreground shapes,
/// a moving square, and per-frame noise similar to a real sensor. Produces
/// the same 4:2:0 full-range buffers as a physical camera.
final class TestPatternSource {
    var onFrame: ((CVPixelBuffer) -> Void)?
    static let id = "test-pattern"

    private let width = 1280, height = 720
    private var baseY: [UInt8]
    private var baseC: [UInt8]
    private var pool: CVPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "\(VirtualCameraConstants.appBundleID).testpattern", qos: .userInteractive)
    private var frame = 0
    private var rng: UInt32 = 0x9E3779B9

    init() {
        (baseY, baseC) = Self.renderBase(width: width, height: height)
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
    }

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let pool else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let yRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let cRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let cw = width / 2, ch = height / 2
            // Moving square: 80 px, sweeps left to right over the backdrop.
            let sx = (frame * 6) % (width + 80) - 80, sy = 60
            for row in 0..<height {
                let dst = y.advanced(by: row * yRow).assumingMemoryBound(to: UInt8.self)
                let src = row * width
                for x in 0..<width {
                    var v = Int(baseY[src + x])
                    if row >= sy && row < sy + 80 && x >= sx && x < sx + 80 { v = 235 }
                    dst[x] = UInt8(clamping: v + noise(3))
                }
            }
            for row in 0..<ch {
                let dst = c.advanced(by: row * cRow).assumingMemoryBound(to: UInt8.self)
                let src = row * cw * 2
                for x in 0..<cw {
                    var cb = Int(baseC[src + x * 2]), cr = Int(baseC[src + x * 2 + 1])
                    if row * 2 >= sy && row * 2 < sy + 80 && x * 2 >= sx && x * 2 < sx + 80 { cb = 128; cr = 128 }
                    dst[x * 2] = UInt8(clamping: cb + noise(2))
                    dst[x * 2 + 1] = UInt8(clamping: cr + noise(2))
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        frame += 1
        onFrame?(pb)
    }

    /// Uniform noise in -amplitude...amplitude from a xorshift generator.
    @inline(__always) private func noise(_ amplitude: Int) -> Int {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Int(rng % UInt32(2 * amplitude + 1)) - amplitude
    }

    /// Draw the static scene with Core Graphics, then convert to Y and CbCr planes.
    private static func renderBase(width: Int, height: Int) -> ([UInt8], [UInt8]) {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(red: 0.0, green: 0.69, blue: 0.25, alpha: 1)      // chroma green
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Unevenly lit backdrop: a slightly darker band.
            ctx.setFillColor(red: 0.0, green: 0.58, blue: 0.22, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: 140))

            // Torso and head.
            ctx.setFillColor(red: 0.25, green: 0.27, blue: 0.32, alpha: 1)
            ctx.fill(CGRect(x: 420, y: 0, width: 440, height: 300))
            ctx.setFillColor(red: 0.88, green: 0.67, blue: 0.55, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: 500, y: 260, width: 280, height: 340))
            // Hair: thin dark strokes against green for fine-edge testing.
            ctx.setStrokeColor(red: 0.2, green: 0.12, blue: 0.08, alpha: 1)
            for i in 0..<40 {
                ctx.setLineWidth(CGFloat(1 + i % 3))
                ctx.move(to: CGPoint(x: 510 + i * 7, y: 560))
                ctx.addLine(to: CGPoint(x: 490 + i * 7 + (i % 5) * 4, y: 640 + (i % 4) * 10))
                ctx.strokePath()
            }
            // Soft edge: gradient from green to white (how softness/tolerance behave).
            let colors = [CGColor(red: 0, green: 0.69, blue: 0.25, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 1)] as CFArray
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 960, y: 200, width: 240, height: 80))
            ctx.drawLinearGradient(grad, start: CGPoint(x: 960, y: 0), end: CGPoint(x: 1200, y: 0), options: [])
            ctx.restoreGState()
            // Colour chips including a yellow-green near the key colour and green spill on gray.
            let chips: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.1, 0.1), (0.1, 0.2, 0.9), (0.6, 0.85, 0.2), (0.5, 0.6, 0.5), (0.95, 0.95, 0.95), (0.05, 0.05, 0.05)]
            for (i, c) in chips.enumerated() {
                ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
                ctx.fill(CGRect(x: 80, y: 560 - i * 70, width: 60, height: 60))
            }
        }
        var yPlane = [UInt8](repeating: 0, count: width * height)
        var cPlane = [UInt8](repeating: 128, count: (width / 2) * (height / 2) * 2)
        func ycc(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return (y, (b - y) / 1.8556 + 0.5, (r - y) / 1.5748 + 0.5)
        }
        for row in 0..<height {
            // Core Graphics draws with origin bottom-left; flip so the pattern is upright.
            let src = (height - 1 - row) * width * 4
            for x in 0..<width {
                let i = src + x * 4
                let (y, _, _) = ycc(Float(rgba[i]) / 255, Float(rgba[i + 1]) / 255, Float(rgba[i + 2]) / 255)
                yPlane[row * width + x] = UInt8(clamping: Int(y * 255 + 0.5))
            }
        }
        for row in 0..<(height / 2) {
            let src = (height - 1 - row * 2) * width * 4
            for x in 0..<(width / 2) {
                let i = src + x * 8
                let (_, cb, cr) = ycc(Float(rgba[i]) / 255, Float(rgba[i + 1]) / 255, Float(rgba[i + 2]) / 255)
                cPlane[(row * (width / 2) + x) * 2] = UInt8(clamping: Int(cb * 255 + 0.5))
                cPlane[(row * (width / 2) + x) * 2 + 1] = UInt8(clamping: Int(cr * 255 + 0.5))
            }
        }
        return (yPlane, cPlane)
    }
}
