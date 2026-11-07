import CoreImage
import CoreML
import MetalKit
import Metal
import QuartzCore
import Vision
import simd

/// Animates the face in the foreground image from the tracked camera face.
///
/// The image's own face landmarks are found once with Vision. Each face update
/// moves a grid mesh laid over the image: the head is lifted onto an ellipsoid
/// and turned by the camera face's yaw, pitch and roll (smoothed), and moved
/// with it at its drawn size, fading out away from the face; eyes, brows, lips
/// and chin add their change of shape from the neutral pose (not smoothed),
/// spread to nearby grid points with Gaussian weights. The renderer
/// draws the mesh into a texture of the image's size, which then stands in for
/// the foreground. No model; the cost is the Vision landmarks the tracker
/// already runs and one draw of a few thousand triangles.
final class FacePuppet {
    static let regions = ["faceContour", "leftEyebrow", "rightEyebrow", "noseCrest", "nose",
                          "leftEye", "rightEye", "outerLips", "innerLips", "medianLine"]
    /// Grid vertices per side.
    private static let grid = 97
    /// The skull: the back half of an ellipsoid behind the face sheet, as two
    /// quarter shells (one per side) so each samples its own side's hair.
    private static let shellA = 10, shellB = 24
    private static var shellCount: Int { 2 * shellA * shellB }
    /// How far each region's motion spreads, in eye distances. Eyelids and lips
    /// need a tight spread or the upper and lower edges average each other out.
    private static let spread: [String: Float] = [
        "leftEye": 0.07, "rightEye": 0.07, "innerLips": 0.07, "outerLips": 0.09,
        "leftEyebrow": 0.12, "rightEyebrow": 0.12, "nose": 0.15, "noseCrest": 0.15,
        "faceContour": 0.25, "medianLine": 0.25]

    private struct Frame {
        var center: SIMD2<Float>, x: SIMD2<Float>, y: SIMD2<Float>, scale: Float
        func local(_ p: SIMD2<Float>) -> SIMD2<Float> { let d = p - center; return SIMD2(simd_dot(d, x), simd_dot(d, y)) / scale }
        func world(_ l: SIMD2<Float>) -> SIMD2<Float> { center + (l.x * x + l.y * y) * scale }
    }
    /// `uv2` is the mirrored sample and `mix` how much of it to use (see `solve`).
    private struct Vertex { var pos: SIMD2<Float>; var uv: SIMD2<Float>; var depth: Float; var mix: Float = 0; var uv2: SIMD2<Float> = .zero }

    private let device: MTLDevice
    private let library: MTLLibrary?
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    private var vertexBuffers: [MTLBuffer] = []
    private var current = 0
    private var output: MTLTexture?
    private var depthTexture: MTLTexture?
    private var depthState: MTLDepthStencilState?
    /// The undistorted image as a full-frame quad at the back of the depth range.
    private lazy var backdrop: MTLBuffer = {
        let quad = [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)].map { Vertex(pos: $0, uv: $0, depth: -1.05, mix: -1, uv2: $0) }
        return device.makeBuffer(bytes: quad, length: quad.count * MemoryLayout<Vertex>.stride, options: .storageModeShared)!
    }()
    private let lock = NSLock()

    // Under `lock`.
    private var source: ObjectIdentifier?
    private var imageSize = SIMD2<Float>(1, 1)
    private var imagePoints: [String: [SIMD2<Float>]] = [:]
    private var imageFrame: Frame?
    private var neutral: [String: [SIMD2<Float>]]?
    private var neutralFrame: Frame?
    private var displacement: [SIMD2<Float>]
    /// Height of each grid point toward the viewer on the turned head, -1…1.
    private var depth: [Float]
    /// Mirror fill per grid point: the mirrored sample position (pixels) and its weight.
    private var mirrorUV: [SIMD2<Float>]
    private var mirrorMix: [Float]
    /// Skull vertices for the current frame: position and texture in pixels, depth.
    private var shellPos: [SIMD2<Float>] = Array(repeating: .zero, count: FacePuppet.shellCount)
    private var shellUV: [SIMD2<Float>] = Array(repeating: .zero, count: FacePuppet.shellCount)
    private var shellDepth: [Float] = Array(repeating: -1, count: FacePuppet.shellCount)
    /// The cutout on the grid before it was grown, to measure the head.
    private var personRaw: [Float]?
    /// Relative depth of the image at each grid point (larger is nearer), from
    /// a monocular depth model run once per image; nil when the model is absent.
    private var depthGrid: [Float]?
    /// Depth at the nose tip and averaged along the face contour, to scale it.
    private var depthNose: Float = 1, depthEdge: Float = 0
    /// Time the depth model took on the last image, for the log.
    private(set) var lastDepthMilliseconds: Double = 0
    /// Time the cutout and the clean plate took on the last image, for the log.
    private(set) var lastPlateMilliseconds: Double = 0

    // Prepared once per image (under `lock`): the subject's cutout, sampled on
    // the grid and as a texture, and the background with the subject removed.
    private var personGrid: [Float]?
    private var maskTexture: MTLTexture?
    private var plateTexture: MTLTexture?
    private var whiteTexture: MTLTexture?
    private var rawForMeasure: [Float]?

    static var lamaModelURL: URL? = Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc")
    private lazy var lamaModel: MLModel? = Self.lamaModelURL.flatMap { try? MLModel(contentsOf: $0) }
    private lazy var ciContext = CIContext(mtlDevice: device)

    /// Depth Anything V2 Small as Core ML (Apple's conversion, Apache 2.0),
    /// compiled into the app when `scripts/fetch-depth-model.sh` has fetched it.
    static var depthModelURL: URL? = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc")
    private lazy var depthModel: VNCoreMLModel? = {
        guard let url = Self.depthModelURL else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        return (try? MLModel(contentsOf: url, configuration: config)).flatMap { try? VNCoreMLModel(for: $0) }
    }()
    private var lastFace: Double = 0
    private var neutralYaw: Float = 0, neutralPitch: Float = 0
    /// Smoothed head pose relative to the neutral one: radians and image pixels.
    private struct Pose {
        var yaw: Float = 0, pitch: Float = 0, roll: Float = 0, move = SIMD2<Float>.zero
        mutating func ease(toward t: Pose, by a: Float) {
            yaw += (t.yaw - yaw) * a; pitch += (t.pitch - pitch) * a
            roll += (t.roll - roll) * a; move += (t.move - move) * a
        }
    }
    private var pose = Pose()

    /// CPU time of the last `drive`, for the stats line.
    private(set) var lastDriveMilliseconds: Double = 0
    var enabled = false {
        didSet { lock.lock(); neutral = nil; lock.unlock() }
    }
    /// The smoothed head pose being applied: yaw, pitch, roll in degrees.
    private(set) var lastPoseDegrees = SIMD3<Float>(0, 0, 0)

    /// The puppet's geometry for the preview overlay, in output coordinates
    /// (0…1, as the face tracker's contours): the image's landmark contours
    /// where the warp has moved them, and a coarse wireframe of the head mesh.
    func overlayPolylines() -> [[SIMD2<Float>]] {
        lock.lock()
        let pts = imagePoints, size = imageSize, disp = displacement, ok = enabled && imageFrame != nil
        lock.unlock()
        guard ok else { return [] }
        let g = Self.grid
        // The image is aspect-filled into the 16:9 output.
        let imgAspect = size.x / size.y, outAspect = Float(VirtualCameraConstants.width) / Float(VirtualCameraConstants.height)
        var scale = SIMD2<Float>(1, 1)
        if imgAspect > outAspect { scale.x = outAspect / imgAspect } else { scale.y = imgAspect / outAspect }
        let offset = (SIMD2<Float>(1, 1) - scale) / 2
        func toOut(_ uv: SIMD2<Float>) -> SIMD2<Float> { (uv - offset) / scale }
        func warped(_ px: SIMD2<Float>) -> SIMD2<Float> {
            // Bilinear sample of the grid displacement at an image pixel.
            let f = px / size * Float(g - 1)
            let c0 = min(max(Int(f.x), 0), g - 2), r0 = min(max(Int(f.y), 0), g - 2)
            let t = f - SIMD2(Float(c0), Float(r0))
            let d00 = disp[r0 * g + c0], d10 = disp[r0 * g + c0 + 1], d01 = disp[(r0 + 1) * g + c0], d11 = disp[(r0 + 1) * g + c0 + 1]
            let d = (d00 * (1 - t.x) + d10 * t.x) * (1 - t.y) + (d01 * (1 - t.x) + d11 * t.x) * t.y
            return toOut((px + d) / size)
        }
        var lines: [[SIMD2<Float>]] = []
        for (name, region) in pts {
            var l = region.map(warped)
            if ["leftEye", "rightEye", "outerLips", "innerLips"].contains(name), let first = l.first { l.append(first) }
            lines.append(l)
        }
        // Every eighth grid line, where the warp moves it.
        func point(_ r: Int, _ c: Int) -> SIMD2<Float>? {
            let i = r * g + c
            guard simd_length(disp[i]) > 0.5 else { return nil }
            return toOut((SIMD2(Float(c), Float(r)) / Float(g - 1) * size + disp[i]) / size)
        }
        for k in stride(from: 0, to: g, by: 8) {
            for horizontal in [true, false] {
                var run: [SIMD2<Float>] = []
                for j in 0..<g {
                    if let q = horizontal ? point(k, j) : point(j, k) { run.append(q) }
                    else { if run.count > 1 { lines.append(run) }; run = [] }
                }
                if run.count > 1 { lines.append(run) }
            }
        }
        return lines
    }

    /// Whether the current foreground image has a face to animate.
    var hasFace: Bool { lock.lock(); defer { lock.unlock() }; return imageFrame != nil }

    init(device: MTLDevice, library: MTLLibrary?) {
        self.device = device
        let n = Self.grid
        displacement = Array(repeating: .zero, count: n * n)
        depth = Array(repeating: 0, count: n * n)
        mirrorUV = Array(repeating: .zero, count: n * n)
        mirrorMix = Array(repeating: 0, count: n * n)
        var indices: [UInt32] = []
        for r in 0..<(n - 1) { for c in 0..<(n - 1) {
            let i = UInt32(r * n + c)
            indices += [i, i + 1, i + UInt32(n), i + 1, i + UInt32(n) + 1, i + UInt32(n)]
        } }
        // Skull indices, after the sheet's vertices.
        let A = Self.shellA, B = Self.shellB
        for half in 0..<2 { for a in 0..<(A - 1) { for b in 0..<(B - 1) {
            let i = UInt32(n * n + half * A * B + a * B + b)
            indices += [i, i + 1, i + UInt32(B), i + 1, i + UInt32(B) + 1, i + UInt32(B)]
        } } }
        indexCount = indices.count
        indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared)!
        for _ in 0..<3 { vertexBuffers.append(device.makeBuffer(length: (n * n + Self.shellCount) * MemoryLayout<Vertex>.stride, options: .storageModeShared)!) }
        self.library = library
        writeVertices()
    }

    // MARK: The foreground image

    /// Find the face in a newly loaded foreground image. `texture` is the layer's
    /// texture, so the renderer warps only the image that was analysed.
    func analyze(_ image: CGImage, texture: MTLTexture) {
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let size = SIMD2<Float>(Float(image.width), Float(image.height))
        var points: [String: [SIMD2<Float>]] = [:]
        // Largest face in the image.
        if let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }), let lm = face.landmarks {
            let map: [String: VNFaceLandmarkRegion2D?] = [
                "faceContour": lm.faceContour, "leftEyebrow": lm.leftEyebrow, "rightEyebrow": lm.rightEyebrow,
                "noseCrest": lm.noseCrest, "nose": lm.nose, "leftEye": lm.leftEye, "rightEye": lm.rightEye,
                "outerLips": lm.outerLips, "innerLips": lm.innerLips, "medianLine": lm.medianLine]
            for (name, region) in map {
                guard let region, region.pointCount > 1 else { continue }
                // Vision: normalised, origin bottom-left. Here: pixels, origin top-left.
                points[name] = region.pointsInImage(imageSize: CGSize(width: 1, height: 1)).map {
                    SIMD2(Float($0.x), 1 - Float($0.y)) * size
                }
            }
        }
        // Depth once per image, sampled onto the mesh grid.
        var grid: [Float]? = nil
        var dNose: Float = 1, dEdge: Float = 0
        if let model = depthModel, !points.isEmpty {
            let started = CACurrentMediaTime()
            let req = VNCoreMLRequest(model: model)
            req.imageCropAndScaleOption = .scaleFill
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
            if let obs = req.results?.first as? VNPixelBufferObservation {
                let pb = obs.pixelBuffer
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
                let base = CVPixelBufferGetBaseAddress(pb)!
                func at(_ uv: SIMD2<Float>) -> Float {
                    let x = min(max(uv.x * Float(w - 1), 0), Float(w - 1)), y = min(max(uv.y * Float(h - 1), 0), Float(h - 1))
                    let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
                    func px(_ xi: Int, _ yi: Int) -> Float { Float(base.advanced(by: yi * row).assumingMemoryBound(to: Float16.self)[xi]) }
                    let tx = x - Float(x0), ty = y - Float(y0)
                    return (px(x0, y0) * (1 - tx) + px(x1, y0) * tx) * (1 - ty) + (px(x0, y1) * (1 - tx) + px(x1, y1) * tx) * ty
                }
                let g = Self.grid
                var values = [Float](repeating: 0, count: g * g)
                for r in 0..<g { for c in 0..<g { values[r * g + c] = at(SIMD2(Float(c), Float(r)) / Float(g - 1)) } }
                if let nose = points["nose"], let contour = points["faceContour"], !nose.isEmpty, !contour.isEmpty {
                    dNose = at(nose.reduce(.zero, +) / Float(nose.count) / size)
                    dEdge = contour.map { at($0 / size) }.reduce(0, +) / Float(contour.count)
                    if dNose - dEdge > 1e-4 { grid = values }
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            }
            lastDepthMilliseconds = (CACurrentMediaTime() - started) * 1000
        }

        // Cutout and clean plate, once per image: Vision's person segmentation
        // gives the subject; LaMa fills the background where the subject was, so
        // a turning head uncovers scenery rather than a ghost of itself.
        var pGrid: [Float]? = nil, maskTex: MTLTexture? = nil, plateTex: MTLTexture? = nil
        if !points.isEmpty {
            let started = CACurrentMediaTime()
            (pGrid, maskTex, plateTex) = prepareCutout(image)
            lastPlateMilliseconds = (CACurrentMediaTime() - started) * 1000
        }

        lock.lock()
        personGrid = pGrid; maskTexture = maskTex; plateTexture = plateTex
        personRaw = pGrid == nil ? nil : rawForMeasure
        depthGrid = grid; depthNose = dNose; depthEdge = dEdge
        source = ObjectIdentifier(texture)
        imageSize = size
        imagePoints = points
        imageFrame = Self.frame(points)
        neutral = nil
        pose = Pose()
        displacement = Array(repeating: .zero, count: Self.grid * Self.grid)
        depth = Array(repeating: 0, count: Self.grid * Self.grid)
        mirrorMix = Array(repeating: 0, count: Self.grid * Self.grid)
        lock.unlock()
        writeVertices()
    }

    private func prepareCutout(_ image: CGImage) -> ([Float]?, MTLTexture?, MTLTexture?) {
        let seg = VNGeneratePersonSegmentationRequest()
        seg.qualityLevel = .accurate
        seg.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([seg])
        guard let maskPB = seg.results?.first?.pixelBuffer else { return (nil, nil, nil) }

        // The mask as a texture, and sampled on the mesh grid.
        CVPixelBufferLockBaseAddress(maskPB, .readOnly)
        let mw = CVPixelBufferGetWidth(maskPB), mh = CVPixelBufferGetHeight(maskPB), row = CVPixelBufferGetBytesPerRow(maskPB)
        let base = CVPixelBufferGetBaseAddress(maskPB)!.assumingMemoryBound(to: UInt8.self)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: mw, height: mh, mipmapped: false)
        td.usage = .shaderRead
        let maskTex = device.makeTexture(descriptor: td)
        maskTex?.replace(region: MTLRegionMake2D(0, 0, mw, mh), mipmapLevel: 0, withBytes: base, bytesPerRow: row)
        let g = Self.grid
        var grid = [Float](repeating: 0, count: g * g)
        for r in 0..<g { for c in 0..<g {
            // A small box average so the turn weight has no hard step at the edge.
            var sum = 0, n = 0
            let cx = Int(Float(c) / Float(g - 1) * Float(mw - 1)), cy = Int(Float(r) / Float(g - 1) * Float(mh - 1))
            for dy in -3...3 { for dx in -3...3 {
                let x = min(max(cx + dx * 2, 0), mw - 1), y = min(max(cy + dy * 2, 0), mh - 1)
                sum += Int(base[y * row + x]); n += 1
            } }
            grid[r * g + c] = Float(sum) / Float(n * 255)
        } }
        CVPixelBufferUnlockBaseAddress(maskPB, .readOnly)
        // Grow it by two grid cells, so the mesh cells along the hair's edge move
        // whole with the head and the cutout's edge stays a clean line instead of
        // tearing into a sawtooth between moving and still vertices.
        rawForMeasure = grid
        var grown = grid
        for r in 0..<g { for c in 0..<g {
            var v: Float = 0
            for dr in -2...2 { for dc in -2...2 {
                let rr = min(max(r + dr, 0), g - 1), cc = min(max(c + dc, 0), g - 1)
                v = max(v, grid[rr * g + cc])
            } }
            grown[r * g + c] = v
        } }
        grid = grown

        // Clean plate: LaMa at its fixed 800×800, fed the whole image and the
        // mask grown by about 2% of the width so no edge of the subject is left,
        // then scaled back and blended in only where the subject was.
        guard let lama = lamaModel,
              let imgConstraint = lama.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              let maskConstraint = lama.modelDescription.inputDescriptionsByName["mask"]?.imageConstraint else { return (grid, maskTex, nil) }
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let maskCI = CIImage(cvPixelBuffer: maskPB)
            .transformed(by: CGAffineTransform(scaleX: W / CGFloat(mw), y: H / CGFloat(mh)))
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(W, H) * 0.02])
            .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        guard let grownMask = ciContext.createCGImage(maskCI, from: maskCI.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()),
              let imageValue = try? MLFeatureValue(cgImage: image, constraint: imgConstraint, options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue]),
              let maskValue = try? MLFeatureValue(cgImage: grownMask, constraint: maskConstraint, options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue]),
              let input = try? MLDictionaryFeatureProvider(dictionary: ["image": imageValue, "mask": maskValue]),
              let out = try? lama.prediction(from: input),
              let filled = out.featureValue(for: "output")?.imageBufferValue else { return (grid, maskTex, nil) }
        let filledCI = CIImage(cvPixelBuffer: filled)
        let fs = filledCI.extent.size
        let scaledFill = filledCI.transformed(by: CGAffineTransform(scaleX: W / fs.width, y: H / fs.height))
        let soft = maskCI.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(W, H) * 0.006]).cropped(to: maskCI.extent)
        let plate = scaledFill.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(cgImage: image), kCIInputMaskImageKey: soft])
            .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        guard let plateCG = ciContext.createCGImage(plate, from: plate.extent),
              let plateTex = try? MTKTextureLoader(device: device).newTexture(cgImage: plateCG, options: [
                .SRGB: false, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)]) else { return (grid, maskTex, nil) }
        return (grid, maskTex, plateTex)
    }

    func clear() {
        lock.lock(); source = nil; imageFrame = nil; imagePoints = [:]; lock.unlock()
    }

    /// Eye-based frame: centre between the eyes, x from the left eye to the right
    /// eye, y toward the mouth. Mirroring and roll fall out of it, so the camera
    /// and the image compare in the face's own terms.
    private static func frame(_ pts: [String: [SIMD2<Float>]]) -> Frame? {
        func mean(_ a: [SIMD2<Float>]?) -> SIMD2<Float>? { guard let a, !a.isEmpty else { return nil }; return a.reduce(.zero, +) / Float(a.count) }
        guard let l = mean(pts["leftEye"]), let r = mean(pts["rightEye"]), let m = mean(pts["outerLips"] ?? pts["innerLips"]) else { return nil }
        let c = (l + r) / 2, d = r - l, s = simd_length(d)
        guard s > 1e-6 else { return nil }
        let x = d / s
        var y = SIMD2(-x.y, x.x)
        if simd_dot(y, m - c) < 0 { y = -y }
        return Frame(center: c, x: x, y: y, scale: s)
    }

    // MARK: The camera face

    private let queue = DispatchQueue(label: "\(VirtualCameraConstants.appBundleID).puppet", qos: .userInitiated)
    private var driving = false

    /// Called on each face update (main queue) with landmarks in output
    /// coordinates (0…1). The mesh is solved off the main thread; an update
    /// that arrives while one is solving is dropped.
    func drive(_ state: FaceState) {
        guard enabled else { return }
        lock.lock()
        if driving { lock.unlock(); return }
        driving = true
        lock.unlock()
        queue.async { [self] in
            solve(state)
            lock.lock(); driving = false; lock.unlock()
        }
    }

    /// Synchronous form for tests.
    func driveNow(_ state: FaceState) { guard enabled else { return }; solve(state) }

    private func solve(_ state: FaceState) {
        let started = CACurrentMediaTime()
        defer { lastDriveMilliseconds = (CACurrentMediaTime() - started) * 1000 }
        lock.lock()
        guard let img = imageFrame else { lock.unlock(); return }
        guard state.detected, let contours = state.contours else {
            // No face: ease back to the image as drawn.
            pose = Pose()
            for i in 0..<displacement.count { displacement[i] *= 0.6; depth[i] *= 0.6; mirrorMix[i] *= 0.6 }
            // The skull has no rest pose to ease to; hide it until the face returns.
            shellPos = Array(repeating: .zero, count: Self.shellCount)
            lock.unlock(); writeVertices(); return
        }
        let out = SIMD2<Float>(Float(VirtualCameraConstants.width), Float(VirtualCameraConstants.height))
        var cam: [String: [SIMD2<Float>]] = [:]
        for (k, v) in contours { cam[k] = v.map { SIMD2($0.x, $0.y) * out } }
        guard let cf = Self.frame(cam) else { lock.unlock(); return }
        // The neutral pose: the first face looking at the camera after enabling,
        // loading, or a few seconds without a face.
        let facing = max(abs(state.yaw ?? 0), abs(state.pitch ?? 0)) < 12
        if facing && (neutral == nil || CACurrentMediaTime() - lastFace > 3) {
            neutral = cam; neutralFrame = cf; neutralYaw = state.yaw ?? 0; neutralPitch = state.pitch ?? 0
            pose = Pose()
        }
        guard neutral != nil else { lock.unlock(); return }
        lastFace = CACurrentMediaTime()
        let nf = neutralFrame!, base = neutral!
        let points = imagePoints, size = imageSize
        let dGrid = depthGrid, dNose = depthNose, dEdge = depthEdge, pGrid = personGrid, pRaw = personRaw
        var smoothed = pose
        let yaw0 = neutralYaw, pitch0 = neutralPitch
        lock.unlock()

        // Rigid head pose relative to the neutral one. The camera and the image
        // can differ in handedness (a mirrored camera), which flips yaw and roll.
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
        let hand: Float = (cross(nf.x, nf.y) > 0 ? 1 : -1) * (cross(img.x, img.y) > 0 ? 1 : -1)
        let rad = Float.pi / 180
        var target = Pose()
        target.yaw = min(max(((state.yaw ?? 0) - yaw0) * hand, -60), 60) * rad
        target.pitch = min(max((state.pitch ?? 0) - pitch0, -40), 40) * rad
        target.roll = min(max(atan2(cross(nf.x, cf.x), simd_dot(nf.x, cf.x)) * hand, -30 * rad), 30 * rad)
        // Translation in the face's own units; head size stays as drawn.
        var move = img.world(nf.local(cf.center)) - img.center
        let limit = img.scale * 0.6
        if simd_length(move) > limit { move = simd_normalize(move) * limit }
        target.move = move
        // Head pose is smoothed; eyes and mouth below are not.
        smoothed.ease(toward: target, by: 0.35)
        let pz = smoothed
        let rot = simd_float2x2(rows: [SIMD2(cos(pz.roll), -sin(pz.roll)), SIMD2(sin(pz.roll), cos(pz.roll))])
        let cy = cos(pz.yaw), sy = sin(pz.yaw), cp = cos(pz.pitch), sp = sin(pz.pitch)

        // Expression: each feature's change of shape about its own centre (eyes,
        // lips), brows relative to the eye below them, and the chin following
        // the lower lip. Measured in the face's frame, so head motion and roll
        // cancel; faded out on a strongly turned face, where landmarks slip.
        let turn = max(abs((state.yaw ?? 0) - yaw0), abs((state.pitch ?? 0) - pitch0))
        let trust = 1 - smoothstep(25, 45, turn)
        func mean(_ a: [SIMD2<Float>]) -> SIMD2<Float> { a.reduce(.zero, +) / Float(max(a.count, 1)) }
        var anchors: [SIMD2<Float>] = [], offsets: [SIMD2<Float>] = [], spreads: [Float] = []
        func add(_ name: String, relativeTo ref: String? = nil) {
            guard let ip = points[name], let n = base[name], let c = cam[name], ip.count == n.count, n.count == c.count else { return }
            let refC = ref.flatMap { cam[$0] }.map(mean) ?? mean(c)
            let refN = ref.flatMap { base[$0] }.map(mean) ?? mean(n)
            let spread = 1 / (2 * pow(img.scale * (Self.spread[name] ?? 0.2), 2))
            for i in 0..<ip.count {
                var dl = (cf.local(c[i]) - cf.local(refC)) - (nf.local(n[i]) - nf.local(refN))
                dl *= trust
                if simd_length(dl) > 0.35 { dl = simd_normalize(dl) * 0.35 }
                anchors.append(ip[i]); spreads.append(spread)
                offsets.append(rot * ((dl.x * img.x + dl.y * img.y) * img.scale))
            }
        }
        add("leftEye"); add("rightEye"); add("innerLips"); add("outerLips")
        add("leftEyebrow", relativeTo: "leftEye"); add("rightEyebrow", relativeTo: "rightEye")
        // Chin: the contour below the mouth moves with the lower lip's drop.
        if let ip = points["faceContour"], let lipsI = points["outerLips"], let lipsN = base["outerLips"], let lipsC = cam["outerLips"], lipsN.count == lipsC.count {
            let centreN = nf.local(mean(lipsN)), centreC = cf.local(mean(lipsC))
            var drop: Float = 0, count: Float = 0
            for i in 0..<lipsN.count where nf.local(lipsN[i]).y > centreN.y {
                drop += (cf.local(lipsC[i]).y - centreC.y) - (nf.local(lipsN[i]).y - centreN.y); count += 1
            }
            drop = min(max(drop / max(count, 1) * trust, -0.1), 0.35)
            let mouthY = simd_dot(mean(lipsI) - img.center, img.y)
            let spread = 1 / (2 * pow(img.scale * 0.3, 2))
            for q in ip where simd_dot(q - img.center, img.y) > mouthY {
                anchors.append(q); spreads.append(spread)
                offsets.append(rot * (img.y * drop * img.scale))
            }
        }

        // Head as an ellipsoid centred near the nose, wide enough to carry the
        // hair. Each grid point inside is lifted onto it, turned by yaw and
        // pitch, and projected back; the depth goes to the depth test so the
        // near side of a turned head draws over the far side.
        let headC = img.center + img.y * (img.scale * 0.35)
        let ra = img.scale * 1.25, rb = img.scale * 1.6, rc = img.scale * 0.95
        // The nose stands off the ellipsoid, so a turned head swings it across
        // the cheek the way a real one does.
        let noseTip = points["nose"].map(mean) ?? (img.center + img.y * img.scale * 0.6)
        let noseSpread = 1 / (2 * pow(img.scale * 0.28, 2))
        let noseHeight = img.scale * 0.45
        // Depth normalised by the tallest point (nose tip on the ellipsoid), so
        // nothing ever passes the near plane and gets clipped away.
        let depthRange0 = rc + noseHeight
        // The skull, measured from the cutout: from the head centre out to the
        // edge of the hair on each side and to its top. Its depth behind the
        // image plane is 0.9 of the half-width, about a real head's proportion
        // given the face sheet in front.
        var skull: (left: Float, right: Float, top: Float)? = nil
        if let pRaw {
            let g = Self.grid
            func inside(_ q: SIMD2<Float>) -> Bool {
                let f = q / size * Float(g - 1)
                let c = Int(f.x.rounded()), r = Int(f.y.rounded())
                guard c >= 0, r >= 0, c < g, r < g else { return false }
                return pRaw[r * g + c] > 0.5
            }
            func reach(_ dir: SIMD2<Float>) -> Float {
                var t: Float = 0
                let step = img.scale * 0.03
                while t < img.scale * 4, inside(headC + dir * (t + step)) { t += step }
                return t
            }
            let l = reach(-img.x), r = reach(img.x), t = reach(-img.y)
            if l > img.scale * 0.4, r > img.scale * 0.4, t > img.scale * 0.4 { skull = (l * 0.92, r * 0.92, t * 0.92) }
        }
        let skullDepth = skull.map { 0.9 * ($0.left + $0.right) / 2 } ?? 0
        let depthRange = max(depthRange0, skullDepth) * 1.05

        // Mirror fill. A face drawn three-quarter on shows one cheek narrow; when
        // the head turns that side toward the viewer, the narrow strip stretches.
        // There it blends in the other side, reflected across the midline and
        // scaled by the width ratio so eyes and mouth corners line up.
        let midC = points["noseCrest"].map(mean) ?? noseTip
        var halfWidth = SIMD2<Float>(img.scale, img.scale)   // (negative side, positive side) in pixels
        if let contour = points["faceContour"], !contour.isEmpty {
            let xs = contour.map { simd_dot($0 - midC, img.x) }
            halfWidth = SIMD2(max(-(xs.min() ?? 0), img.scale * 0.3), max(xs.max() ?? 0, img.scale * 0.3))
        }
        let g = Self.grid
        var next = [SIMD2<Float>](repeating: .zero, count: g * g)
        var nextDepth = [Float](repeating: 0, count: g * g)
        var nextMirror = [SIMD2<Float>](repeating: .zero, count: g * g)
        var nextMix = [Float](repeating: 0, count: g * g)
        for r in 0..<g { for c in 0..<g {
            let v = SIMD2(Float(c) / Float(g - 1), Float(r) / Float(g - 1)) * size
            let d = simd_length(v - img.center) / img.scale
            // Fade out away from the face, and pin the image edges so the mesh
            // never pulls away from the frame and shows a gap.
            let uv = v / size
            let edge = min(min(uv.x, 1 - uv.x), min(uv.y, 1 - uv.y))
            let m = (1 - smoothstep(2.0, 3.6, d)) * smoothstep(0, 0.12, edge)
            guard m > 0 || (pGrid?[r * g + c] ?? 0) > 0.05 else { continue }

            let rel = v - headC
            let lx = simd_dot(rel, img.x), ly = simd_dot(rel, img.y)
            let e = (lx * lx) / (ra * ra) + (ly * ly) / (rb * rb)
            let nq = v - noseTip
            let z: Float
            if let dGrid {
                // The depth model's surface, scaled so the face contour sits at
                // 0.4 of the head's depth and the nose tip at the front.
                let zEdge = 0.4 * rc
                z = min(max((dGrid[r * g + c] - dEdge) / (dNose - dEdge) * (depthRange0 - zEdge) + zEdge, 0), depthRange0)
            } else {
                z = (e < 1 ? rc * (1 - e).squareRoot() : 0) + noseHeight * exp(-simd_dot(nq, nq) * noseSpread)
            }
            // With a cutout, the whole head turns with the face, hair included,
            // fading out only down the neck so the body stays put; without one,
            // the turn fades out past an ellipse around the face.
            let hw: Float = pGrid.map { pg in
                smoothstep(0.05, 0.35, pg[r * g + c]) * (1 - smoothstep(rb * 0.8, rb * 1.5, ly))
            } ?? 1
            let w3 = pGrid == nil ? 1 - smoothstep(0.85, 1.6, e.squareRoot()) : hw
            // Yaw about the face's vertical axis, then pitch about its horizontal axis.
            let x1 = lx * cy + z * sy, z1 = -lx * sy + z * cy
            let y2 = ly * cp + z1 * sp, z2 = -ly * sp + z1 * cp
            let turned = headC + (lx + w3 * (x1 - lx)) * img.x + (ly + w3 * (y2 - ly)) * img.y
            let rigid = headC + pz.move + rot * (turned - headC)

            var sum = SIMD2<Float>.zero, wsum: Float = 0
            if d < 3 {
                for j in 0..<anchors.count {
                    let q = v - anchors[j]
                    let w = exp(-simd_dot(q, q) * spreads[j])
                    sum += w * offsets[j]; wsum += w
                }
            }
            let expression = sum / (wsum + 0.15)
            next[r * g + c] = pGrid == nil ? m * (rigid - v + expression) : hw * (rigid - v) + m * expression
            nextDepth[r * g + c] = min(max(m * w3 * z2 / depthRange, -1), 1)

            // Which side of the midline, how narrow it is against the other,
            // and how far the turn brings it toward the viewer.
            let mx = simd_dot(v - midC, img.x)
            let side: Float = mx < 0 ? -1 : 1
            let this = side < 0 ? halfWidth.x : halfWidth.y, other = side < 0 ? halfWidth.y : halfWidth.x
            let narrow = max(0, 1 - this / other)
            let reveal = min(max(-side * sin(pz.yaw) * 2.5, 0), 1)
            let outward = smoothstep(0.15, 0.7, abs(mx) / this)
            let amount = min(narrow * 2.5, 1) * reveal * outward * w3 * m
            if amount > 0.01 {
                let mirrored = v - (mx + mx * other / this) * img.x   // reflect, then stretch to the other side's width
                nextMirror[r * g + c] = mirrored
                nextMix[r * g + c] = amount
            }
        } }
        // The skull, rigid with the head. Each vertex samples hair just inside
        // the outline at its own height and side, so the exposed back of the
        // head shows the hair it would have rather than the face.
        var sPos = [SIMD2<Float>](repeating: headC, count: Self.shellCount)
        var sUV = [SIMD2<Float>](repeating: headC, count: Self.shellCount)
        var sDepth = [Float](repeating: -1, count: Self.shellCount)
        if let skull {
            let A = Self.shellA, B = Self.shellB
            for half in 0..<2 {
                let side: Float = half == 0 ? 1 : -1
                let rx = side > 0 ? skull.right : skull.left
                for a in 0..<A { for b in 0..<B {
                    // a: from the side (0) round to the back (pi/2); b: from the
                    // crown down to the jaw.
                    let alpha = Float(a) / Float(A - 1) * .pi / 2
                    let beta = Float(b) / Float(B - 1) * .pi * 0.8
                    let lx = side * rx * cos(alpha) * sin(beta)
                    let ly = -skull.top * cos(beta)
                    let z = -skullDepth * sin(alpha) * sin(beta)
                    let x1 = lx * cy + z * sy, z1 = -lx * sy + z * cy
                    let y2 = ly * cp + z1 * sp, z2 = -ly * sp + z1 * cp
                    let turned = headC + x1 * img.x + y2 * img.y
                    let i = half * A * B + a * B + b
                    sPos[i] = headC + pz.move + rot * (turned - headC)
                    // Inward from the outline as it rounds to the back, so the
                    // hair band is sampled across its width rather than along
                    // one line, which streaks.
                    let k = 0.96 - 0.18 * sin(alpha)
                    sUV[i] = headC + k * (side * rx * sin(beta) * img.x + ly * img.y)
                    sDepth[i] = min(max(z2 / depthRange, -1), 1)
                } }
            }
        }

        lock.lock()
        pose = smoothed
        lastPoseDegrees = SIMD3(pz.yaw, pz.pitch, pz.roll) * (180 / .pi)
        displacement = next
        depth = nextDepth
        shellPos = sPos; shellUV = sUV; shellDepth = sDepth
        mirrorUV = nextMirror
        mirrorMix = nextMix
        lock.unlock()
        writeVertices()
    }

    private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
    }

    private func writeVertices() {
        lock.lock()
        let g = Self.grid, size = imageSize, disp = displacement, dep = depth, mUV = mirrorUV, mMix = mirrorMix
        let sPos = shellPos, sUV = shellUV, sDepth = shellDepth
        let index = (current + 1) % vertexBuffers.count
        lock.unlock()
        let p = vertexBuffers[index].contents().bindMemory(to: Vertex.self, capacity: g * g + Self.shellCount)
        for i in 0..<Self.shellCount {
            let uv = size.x > 0 ? sUV[i] / size : .zero
            p[g * g + i] = Vertex(pos: size.x > 0 ? sPos[i] / size : .zero, uv: uv, depth: sDepth[i], uv2: uv)
        }
        for r in 0..<g { for c in 0..<g {
            let uv = SIMD2(Float(c) / Float(g - 1), Float(r) / Float(g - 1))
            let i = r * g + c
            p[i] = Vertex(pos: uv + disp[i] / size, uv: uv, depth: dep[i], mix: mMix[i], uv2: mMix[i] > 0 ? mUV[i] / size : uv)
        } }
        lock.lock(); current = index; lock.unlock()
    }

    // MARK: Rendering

    /// Draw the warped foreground into a texture of the same size. Returns nil
    /// (use the layer unchanged) when off, before analysis, or for another image.
    func encode(_ cmd: MTLCommandBuffer, source tex: MTLTexture) -> MTLTexture? {
        lock.lock()
        let ready = enabled && source == ObjectIdentifier(tex) && imageFrame != nil
        let buffer = vertexBuffers[current]
        let mask = maskTexture, plate = plateTexture
        lock.unlock()
        guard ready else { return nil }
        // Output in the layer's own pixel format, so sRGB images stay sRGB.
        let format = tex.pixelFormat
        if pipelines[format] == nil {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library?.makeFunction(name: "puppetVertex")
            desc.fragmentFunction = library?.makeFunction(name: "puppetFragment")
            desc.colorAttachments[0].pixelFormat = format
            desc.depthAttachmentPixelFormat = .depth32Float
            pipelines[format] = try? device.makeRenderPipelineState(descriptor: desc)
        }
        guard let pipeline = pipelines[format] else { return nil }
        if output == nil || output!.width != tex.width || output!.height != tex.height || output!.pixelFormat != format {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: tex.width, height: tex.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            output = device.makeTexture(descriptor: d)
            let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: tex.width, height: tex.height, mipmapped: false)
            dd.usage = .renderTarget; dd.storageMode = .private
            depthTexture = device.makeTexture(descriptor: dd)
        }
        guard let output, let depthTexture else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setRenderPipelineState(pipeline)
        if depthState == nil {
            let ds = MTLDepthStencilDescriptor(); ds.depthCompareFunction = .lessEqual; ds.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: ds)
        }
        enc.setDepthStencilState(depthState)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        if whiteTexture == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
            whiteTexture = device.makeTexture(descriptor: d)
            var one: UInt8 = 255
            whiteTexture?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &one, bytesPerRow: 1)
        }
        // With a cutout only the subject is meshed; the rest shows the plate.
        enc.setFragmentTexture(mask ?? whiteTexture, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: 0)
        // Fill any hole a sharply turned head leaves with the image as drawn,
        // behind the mesh, so the camera never shows through the layer.
        // With a clean plate that is the background with the subject removed.
        enc.setFragmentTexture(plate ?? tex, index: 0)
        enc.setVertexBuffer(backdrop, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        return output
    }
}
