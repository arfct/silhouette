import Vision
import CoreVideo
import QuartzCore
import simd

struct FacePoint: Codable { var x: Float; var y: Float }
struct FaceEye: Codable { var x: Float; var y: Float; var open: Float }
struct FaceBox: Codable { var x: Float; var y: Float; var w: Float; var h: Float }
struct FacePoint3: Codable { var x: Float; var y: Float; var z: Float }

/// Everything in output-space normalised coordinates (0...1, origin top-left,
/// the frame the virtual camera emits). Angles in degrees. Left and right
/// are as seen in the image.
struct FaceState: Codable {
    var t: Double
    var detected: Bool
    var box: FaceBox?
    var center: FacePoint?
    var roll: Float?
    var yaw: Float?
    var pitch: Float?
    var leftEye: FaceEye?
    var rightEye: FaceEye?
    var nose: FacePoint?
    var mouth: FaceEye?
    /// Metres from the camera, estimated from eye separation (or box height
    /// when an eye is hidden). Assumes a 63 mm interpupillary distance and the
    /// field of view in `FaceTracker.assumedHorizontalFOV`.
    var distance: Float?
    /// Head centre in camera space, metres: x right, y up, z away from the camera.
    var position: FacePoint3?
    /// Head pose as a column-major 4×4 matrix in camera space: rotation from
    /// yaw, pitch and roll, translation from `position`.
    var pose: [Float]?
    /// Column-major 4×4 perspective projection for the assumed camera (16:9,
    /// near 0.1 m, far 10 m). `projection × pose × point` lands in clip space.
    var projection: [Float]?
    /// Landmark polylines in output coordinates, keyed by Vision's region names.
    var contours: [String: [FacePoint]]?
}

/// Face, head pose, and eye tracking with Vision on the Neural Engine.
/// Runs beside the renderer; never blocks the frame path.
final class FaceTracker {
    /// Delivered on the main queue.
    var onUpdate: ((FaceState) -> Void)?
    var isEnabled = false

    private let queue = DispatchQueue(label: "\(VirtualCameraConstants.appBundleID).vision", qos: .userInitiated)
    private let handler = VNSequenceRequestHandler()
    private let lock = NSLock()
    private var busy = false
    private var lastDetection: VNFaceObservation?
    private var framesSinceDetection = 0
    /// Detect every N tracking frames; landmarks fit to the last box in between.
    var detectEvery = 4
    /// Assumed camera optics for the distance and pose estimate.
    static let assumedHorizontalFOV: Float = 70   // degrees
    static let assumedIPD: Float = 0.063          // metres
    static let outputAspect = Float(VirtualCameraConstants.width) / Float(VirtualCameraConstants.height)

    /// `pixelBuffer` is a small RGB copy of the full camera frame (the renderer
    /// makes it on the GPU). `camScale`/`camOffset` map output uv to camera uv.
    func process(_ pixelBuffer: CVPixelBuffer, camScale: SIMD2<Float>, camOffset: SIMD2<Float>) {
        guard isEnabled else { return }
        lock.lock()
        let skip = busy
        if !skip { busy = true }
        lock.unlock()
        guard !skip else { return }

        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.unlock() }
            // The detector (box + roll/yaw/pitch) is the expensive Neural Engine
            // pass; run it every few frames or when there is no face to follow.
            // Landmarks fit every frame to the most recent box.
            framesSinceDetection += 1
            if lastDetection == nil || framesSinceDetection >= detectEvery {
                let pose = VNDetectFaceRectanglesRequest()
                try? handler.perform([pose], on: pixelBuffer, orientation: .up)
                lastDetection = (pose.results ?? []).max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
                framesSinceDetection = 0
            }
            var face: VNFaceObservation? = nil
            if let box = lastDetection {
                let landmarks = VNDetectFaceLandmarksRequest()
                landmarks.inputFaceObservations = [box]
                try? handler.perform([landmarks], on: pixelBuffer, orientation: .up)
                face = landmarks.results?.first
                if face?.landmarks == nil { lastDetection = nil }   // lost it: detect next time
            }
            let state = Self.state(from: face, pose: lastDetection, camScale: camScale, camOffset: camOffset)
            DispatchQueue.main.async { self.onUpdate?(state) }
        }
    }

    private static func state(from face: VNFaceObservation?, pose: VNFaceObservation?, camScale: SIMD2<Float>, camOffset: SIMD2<Float>) -> FaceState {
        let now = CACurrentMediaTime()
        guard let face else { return FaceState(t: now, detected: false) }

        // Vision: normalised, origin bottom-left, camera image. Output: origin top-left, aspect-filled.
        func out(_ p: CGPoint) -> FacePoint {
            let cam = SIMD2<Float>(Float(p.x), 1 - Float(p.y))
            let o = (cam - camOffset) / camScale
            return FacePoint(x: o.x, y: o.y)
        }
        func eye(_ region: VNFaceLandmarkRegion2D?) -> FaceEye? {
            guard let region, region.pointCount >= 4 else { return nil }
            let pts = region.pointsInImage(imageSize: CGSize(width: 1, height: 1))
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let w = max(xs.max()! - xs.min()!, 1e-4), h = ys.max()! - ys.min()!
            let c = out(CGPoint(x: (xs.max()! + xs.min()!) / 2, y: (ys.max()! + ys.min()!) / 2))
            return FaceEye(x: c.x, y: c.y, open: Float(h / w))
        }

        let b = face.boundingBox
        let tl = out(CGPoint(x: b.minX, y: b.maxY)), br = out(CGPoint(x: b.maxX, y: b.minY))
        var s = FaceState(t: now, detected: true)
        s.box = FaceBox(x: tl.x, y: tl.y, w: br.x - tl.x, h: br.y - tl.y)
        s.center = FacePoint(x: (tl.x + br.x) / 2, y: (tl.y + br.y) / 2)
        let deg = Float(180 / Double.pi)
        let p = pose ?? face
        s.roll = (p.roll ?? face.roll).map { Float(truncating: $0) * deg }
        s.yaw = (p.yaw ?? face.yaw).map { Float(truncating: $0) * deg }
        s.pitch = (p.pitch ?? face.pitch).map { Float(truncating: $0) * deg }

        if let lm = face.landmarks {
            var eyes = [eye(lm.leftEye), eye(lm.rightEye)].compactMap { $0 }
            // Prefer pupil positions for the eye centre when available.
            if let lp = lm.leftPupil?.pointsInImage(imageSize: CGSize(width: 1, height: 1)).first, eyes.count > 0 {
                let p = out(lp); eyes[0].x = p.x; eyes[0].y = p.y
            }
            if let rp = lm.rightPupil?.pointsInImage(imageSize: CGSize(width: 1, height: 1)).first, eyes.count > 1 {
                let p = out(rp); eyes[1].x = p.x; eyes[1].y = p.y
            }
            eyes.sort { $0.x < $1.x }
            s.leftEye = eyes.first
            s.rightEye = eyes.count > 1 ? eyes[1] : nil
            if let nose = lm.nose?.pointsInImage(imageSize: CGSize(width: 1, height: 1)), !nose.isEmpty {
                let cx = nose.map(\.x).reduce(0, +) / CGFloat(nose.count), cy = nose.map(\.y).reduce(0, +) / CGFloat(nose.count)
                s.nose = out(CGPoint(x: cx, y: cy))
            }
            s.mouth = eye(lm.innerLips ?? lm.outerLips)
            var contours: [String: [FacePoint]] = [:]
            let regions: [(String, VNFaceLandmarkRegion2D?)] = [
                ("faceContour", lm.faceContour), ("leftEyebrow", lm.leftEyebrow), ("rightEyebrow", lm.rightEyebrow),
                ("noseCrest", lm.noseCrest), ("nose", lm.nose), ("leftEye", lm.leftEye), ("rightEye", lm.rightEye),
                ("outerLips", lm.outerLips), ("innerLips", lm.innerLips), ("medianLine", lm.medianLine),
            ]
            for (name, region) in regions {
                guard let region, region.pointCount > 1 else { continue }
                contours[name] = region.pointsInImage(imageSize: CGSize(width: 1, height: 1)).map(out)
            }
            s.contours = contours
        }
        addGeometry(&s)
        return s
    }

    /// Distance, camera-space position, pose matrix and projection, all from the
    /// assumed optics. Rough by nature: webcams differ, so do heads.
    private static func addGeometry(_ s: inout FaceState) {
        guard let box = s.box, let c = s.center else { return }
        let fovH = assumedHorizontalFOV * Float.pi / 180
        let tanH = tan(fovH / 2), tanV = tanH / outputAspect
        let yaw = (s.yaw ?? 0) * Float.pi / 180, pitch = (s.pitch ?? 0) * Float.pi / 180, roll = (s.roll ?? 0) * Float.pi / 180

        // Eye separation in horizontal normalised units, widened back for yaw.
        var distance: Float
        if let l = s.leftEye, let r = s.rightEye {
            let dx = r.x - l.x, dy = (r.y - l.y) / outputAspect
            let sep = (dx * dx + dy * dy).squareRoot() / max(cos(yaw), 0.3)
            let theta = sep * fovH
            distance = (assumedIPD / 2) / max(tan(theta / 2), 1e-4)
        } else {
            let faceHeight: Float = 0.19   // metres, chin to brow line, roughly what the box spans
            distance = (faceHeight / 2) / max(tan(box.h * 2 * atan(tanV) / 2), 1e-4)
        }
        distance = min(max(distance, 0.15), 5)
        s.distance = distance

        let X = (c.x - 0.5) * 2 * distance * tanH
        let Y = -(c.y - 0.5) * 2 * distance * tanV
        s.position = FacePoint3(x: X, y: Y, z: distance)

        // R = Rz(roll) · Ry(-yaw) · Rx(pitch); forward (toward the camera) is R·(0,0,-1).
        let cy = cos(-yaw), sy = sin(-yaw), cp = cos(pitch), sp = sin(pitch), cr = cos(roll), sr = sin(roll)
        let ry = simd_float3x3(rows: [SIMD3(cy, 0, sy), SIMD3(0, 1, 0), SIMD3(-sy, 0, cy)])
        let rx = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cp, -sp), SIMD3(0, sp, cp)])
        let rz = simd_float3x3(rows: [SIMD3(cr, -sr, 0), SIMD3(sr, cr, 0), SIMD3(0, 0, 1)])
        let r = rz * ry * rx
        s.pose = [r[0].x, r[0].y, r[0].z, 0,
                  r[1].x, r[1].y, r[1].z, 0,
                  r[2].x, r[2].y, r[2].z, 0,
                  X, Y, distance, 1]

        let near: Float = 0.1, far: Float = 10, f = 1 / tanV
        s.projection = [f / outputAspect, 0, 0, 0,
                        0, f, 0, 0,
                        0, 0, (far + near) / (near - far), -1,
                        0, 0, 2 * far * near / (near - far), 0]
    }
}
