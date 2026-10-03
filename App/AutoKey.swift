import CoreVideo
import Vision
import simd

/// What Auto decided, plus how sure it is.
struct AutoKeyResult {
    var keyCbCr: SIMD2<Float>
    var keyLuma: Float
    var tolerance: Float
    var softness: Float
    /// Shrink and Blur in 1080p output pixels, from the measured fringe width.
    var edge: Float
    var feather: Float
    /// Desaturate (0…1), from key-coloured bounce measured on the subject.
    var spill: Float
    /// Fraction of the perimeter samples the chosen range removes.
    var edgeCoverage: Float
    /// 0…1. Low when the perimeter is not one colour or the colour is nearly grey.
    var confidence: Float
    var colorName: String
}

/// Finds the backdrop colour and a Color Range from a few frames.
///
/// Backdrop candidates come from a ring around the frame, minus a corridor
/// under the face where the subject's body meets the bottom edge, and minus
/// the face itself. The dominant chroma of that ring is the key. Tolerance is
/// set so nearly all of the ring is removed; softness ends well short of the
/// nearest skin tone so the face is never eaten. Full-resolution row scans
/// give the width of the backdrop-to-subject fringe, which sets Shrink and
/// Blur, and the key-coloured tint on the subject sets Desaturate.
final class AutoKeyAnalyzer {
    private struct Sample { var cb: Float; var cr: Float; var y: Float }

    private var backdrop: [Sample] = []
    private var foreground: [SIMD2<Float>] = []
    /// Everything that is neither ring nor face: clothes, hair, props.
    private var subject: [SIMD2<Float>] = []
    /// Full-resolution chroma along a few rows, for the fringe measurement.
    private var rowScans: [[SIMD2<Float>]] = []
    private var chromaWidth = 0
    private(set) var frameCount = 0
    private var faceBox: CGRect?   // camera uv, origin top-left; the latest detection

    private lazy var faceRequest = VNDetectFaceRectanglesRequest()

    /// Pool one frame. Runs face detection on it so the body corridor and the
    /// skin samples follow the subject.
    func add(_ frame: CVPixelBuffer) {
        if let face = detectFace(frame) { faceBox = face }
        sample(frame)
        frameCount += 1
    }

    private func detectFace(_ frame: CVPixelBuffer) -> CGRect? {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up)
        try? handler.perform([faceRequest])
        guard let best = (faceRequest.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else { return nil }
        let b = best.boundingBox   // Vision: origin bottom-left
        return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
    }

    private func sample(_ frame: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(frame) >= 2 else { return }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let cbase = CVPixelBufferGetBaseAddressOfPlane(frame, 1), let ybase = CVPixelBufferGetBaseAddressOfPlane(frame, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(frame, 1), h = CVPixelBufferGetHeightOfPlane(frame, 1)
        let cbpr = CVPixelBufferGetBytesPerRowOfPlane(frame, 1), ybpr = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
        let lumaH = CVPixelBufferGetHeightOfPlane(frame, 0), lumaW = CVPixelBufferGetWidthOfPlane(frame, 0)
        let videoRange = CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let step = max(w / 160, 1)

        // Where the body meets the bottom edge: under the face, or the bottom centre.
        let face = faceBox
        let bodyU = Float(face?.midX ?? 0.5)
        let bodyHalf = max(Float(face?.width ?? 0.14) * 1.6, 0.22)
        let faceExpanded = face.map { $0.insetBy(dx: -$0.width * 0.3, dy: -$0.height * 0.3) }
        let faceInner = face.map { $0.insetBy(dx: $0.width * 0.2, dy: $0.height * 0.2) }

        chromaWidth = w
        var y = 0
        while y < h {
            let crow = cbase.advanced(by: y * cbpr).assumingMemoryBound(to: UInt8.self)
            let yrow = ybase.advanced(by: min(y * 2, lumaH - 1) * ybpr).assumingMemoryBound(to: UInt8.self)
            let v = (Float(y) + 0.5) / Float(h)
            var x = 0
            while x < w {
                let u = (Float(x) + 0.5) / Float(w)
                var cb = Float(crow[x * 2]) / 255, cr = Float(crow[x * 2 + 1]) / 255
                var luma = Float(yrow[min(x * 2, lumaW - 1)]) / 255
                if videoRange {
                    cb = (cb - 0.5) * (255 / 224) + 0.5; cr = (cr - 0.5) * (255 / 224) + 0.5
                    luma = (luma - 16 / 255) * (255 / 219)
                }
                let point = CGPoint(x: CGFloat(u), y: CGFloat(v))
                let inFace = faceExpanded?.contains(point) ?? false
                let inRing = u < 0.08 || u > 0.92 || v < 0.08 || v > 0.92
                let inBodyCorridor = v > 0.55 && abs(u - bodyU) < bodyHalf
                if inRing && !inFace && !inBodyCorridor {
                    backdrop.append(Sample(cb: cb, cr: cr, y: luma))
                } else if let faceInner, faceInner.contains(point) {
                    foreground.append(SIMD2(cb, cr))
                } else if !inRing && !inFace {
                    subject.append(SIMD2(cb, cr))
                }
                x += step
            }
            y += step
        }
        // Full-resolution scans of a few rows through the middle of the frame,
        // where the subject usually is, for the fringe measurement.
        for i in 0..<12 {
            let ry = Int(Float(h) * (0.15 + 0.7 * Float(i) / 11))
            let crow = cbase.advanced(by: ry * cbpr).assumingMemoryBound(to: UInt8.self)
            var scan: [SIMD2<Float>] = []; scan.reserveCapacity(w)
            for x in 0..<w {
                var cb = Float(crow[x * 2]) / 255, cr = Float(crow[x * 2 + 1]) / 255
                if videoRange { cb = (cb - 0.5) * (255 / 224) + 0.5; cr = (cr - 0.5) * (255 / 224) + 0.5 }
                scan.append(SIMD2(cb, cr))
            }
            rowScans.append(scan)
        }
    }

    func result() -> AutoKeyResult? {
        guard backdrop.count > 200 else { return nil }

        // Dominant chroma: histogram mode, then a robust mean around it.
        let bins = 64
        var hist = [Int](repeating: 0, count: bins * bins)
        for s in backdrop {
            let bx = min(Int(s.cb * Float(bins)), bins - 1), by = min(Int(s.cr * Float(bins)), bins - 1)
            hist[by * bins + bx] += 1
        }
        let modeIndex = hist.indices.max { hist[$0] < hist[$1] }!
        var key = SIMD2<Float>((Float(modeIndex % bins) + 0.5) / Float(bins), (Float(modeIndex / bins) + 0.5) / Float(bins))
        var radius: Float = 0.08
        for _ in 0..<3 {
            var sum = SIMD2<Float>(0, 0); var n = 0
            for s in backdrop where simd_distance(SIMD2(s.cb, s.cr), key) < radius { sum += SIMD2(s.cb, s.cr); n += 1 }
            if n > 0 { key = sum / Float(n) }
            radius = 0.06
        }

        // The backdrop set: ring samples near the key, generous enough for uneven lighting.
        let distances = backdrop.map { simd_distance(SIMD2($0.cb, $0.cr), key) }
        let near = distances.filter { $0 < 0.14 }
        let nearFraction = Float(near.count) / Float(distances.count)
        let lumaMean = zip(backdrop, distances).filter { $0.1 < 0.14 }.map(\.0.y).reduce(0, +) / Float(max(near.count, 1))

        // Tolerance removes nearly all of the backdrop; softness ends short of skin.
        let sortedNear = near.sorted()
        var tolerance = sortedNear[Int(Float(sortedNear.count - 1) * 0.97)] + 0.01
        // Skin: face-box pixels that are not backdrop showing through the box (a
        // profile view or a loose box lets plenty of green in). Trust the sample
        // only when most of the box is really face.
        let fgAll = foreground.map { simd_distance($0, key) }
        let fgDistances = fgAll.filter { $0 > 0.12 }.sorted()
        let skin: Float? = fgDistances.count > 30 && Float(fgDistances.count) > Float(fgAll.count) * 0.4
            ? fgDistances[Int(Float(fgDistances.count - 1) * 0.05)] : nil
        var upper: Float
        if let skin {
            tolerance = min(tolerance, skin * 0.7)
            upper = min(tolerance + max(0.03, (skin - tolerance) * 0.4), skin * 0.9)
        } else {
            upper = tolerance + max(0.04, tolerance * 0.5)
        }
        tolerance = max(tolerance, 0.02)
        upper = max(upper, tolerance + 0.02)
        // What the chosen range actually removes along the ring (half credit in the soft band).
        let mid = tolerance + (upper - tolerance) * 0.5
        let keyed = Float(distances.filter { $0 < mid }.count) / Float(distances.count)

        // Fringe: along each scanned row, runs of soft-band pixels sitting between
        // backdrop and subject. Their median width, in chroma pixels, is how far
        // the backdrop bleeds into the edge (chroma subsampling, lens blur, hair).
        var fringeWidths: [Int] = []
        for scan in rowScans {
            var i = 0
            while i < scan.count {
                let d = simd_distance(scan[i], key)
                if d >= tolerance && d < upper {
                    var j = i
                    while j < scan.count, simd_distance(scan[j], key) >= tolerance, simd_distance(scan[j], key) < upper { j += 1 }
                    let before = i > 0 ? simd_distance(scan[i - 1], key) : -1
                    let after = j < scan.count ? simd_distance(scan[j], key) : -1
                    let bordersBackdrop = before >= 0 && before < tolerance || after >= 0 && after < tolerance
                    let bordersSubject = before >= upper || after >= upper
                    if bordersBackdrop && bordersSubject && j - i <= 24 { fringeWidths.append(j - i) }
                    i = j
                } else {
                    i += 1
                }
            }
        }
        // Chroma pixels → 1080p output pixels (the chroma plane is half the camera width).
        let outputPerChroma = Float(1920) / Float(max(chromaWidth, 1))
        var fringe: Float = 1   // in output pixels; a sane default when no edge was found
        if fringeWidths.count >= 8 {
            let sorted = fringeWidths.sorted()
            fringe = Float(sorted[sorted.count / 2]) * outputPerChroma
        }
        let edge = min(max((fringe * 0.4 * 10).rounded() / 10, 0), 3)
        let feather = min(max((fringe * 0.3 * 10).rounded() / 10, 0.3), 2)

        // Spill: how far subject chroma leans toward the key colour. The shader
        // removes that component scaled by Desaturate, so size it to the lean.
        var spill: Float = 0.5
        let keyDir = simd_normalize(key - SIMD2<Float>(0.5, 0.5))
        let leans = subject.filter { simd_distance($0, key) >= upper }.map { simd_dot($0 - SIMD2<Float>(0.5, 0.5), keyDir) }.filter { $0 > 0 }
        if subject.count > 200 {
            let leanFraction = Float(leans.count) / Float(subject.count)
            let strong = leans.sorted()
            let p90: Float = strong.isEmpty ? 0 : strong[Int(Float(strong.count - 1) * 0.9)]
            spill = min(max(leanFraction * 2 + p90 / 0.05, 0.2), 1)
            spill = (spill * 20).rounded() / 20
        }

        // Confidence: a saturated colour that covers most of the ring.
        let saturation = simd_distance(key, SIMD2(0.5, 0.5))
        let confidence = min(nearFraction, 1) * min(saturation / 0.12, 1)

        return AutoKeyResult(keyCbCr: key, keyLuma: lumaMean, tolerance: tolerance, softness: upper - tolerance,
                             edge: edge, feather: feather, spill: spill, edgeCoverage: keyed, confidence: confidence,
                             colorName: Self.name(of: key))
    }

    /// Rough hue name from the chroma angle, for the status line.
    private static func name(of key: SIMD2<Float>) -> String {
        let cb = key.x - 0.5, cr = key.y - 0.5
        guard cb * cb + cr * cr > 0.04 * 0.04 else { return "grey" }
        let angle = atan2(cr, cb) * 180 / .pi   // 0° = +Cb (blue), 90° = +Cr (red)
        switch angle {
        case -200 ... -120, 160...200: return "green"
        case -120 ... -45: return "cyan"
        case -45...45: return "blue"
        case 45...110: return "magenta"
        case 110...160: return "red"
        default: return "green"
        }
    }
}
