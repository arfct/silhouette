import Foundation
import Metal
import MetalPerformanceShaders
import CoreVideo
import simd
import QuartzCore
import os.log

private let statsLog = Logger(subsystem: VirtualCameraConstants.appBundleID, category: "stats")

/// Mirrors `KeyParams` in Shaders.metal.
struct KeyParams: Codable, Equatable {
    var keyCbCr = SIMD2<Float>(0.27, 0.23)
    var tolerance: Float = 0.10
    var softness: Float = 0.08
    var spill: Float = 0.8
    /// Erosion radius in 1920×1080 output pixels (converted to chroma texels per frame).
    var edge: Float = 0.0
    var hasBackground: Float = 0.0
    var camScale = SIMD2<Float>(1, 1)
    var camOffset = SIMD2<Float>(0, 0)
    var bgScale = SIMD2<Float>(1, 1)
    var bgOffset = SIMD2<Float>(0, 0)
    var chromaTexel = SIMD2<Float>(0, 0)
    var shadowOffset = SIMD2<Float>(0.03, 0.04)
    var shadowOpacity: Float = 0.5
    var temporal: Float = 0.0
    /// 1 shows the unkeyed camera image. Not persisted.
    var bypass: Float = 0
    /// Set per frame from the pixel buffer's format. Not persisted.
    var videoRange: Float = 0
    /// Padding of the shadow canvas as a fraction of its size. Set per pass; not persisted.
    var shadowPad = SIMD2<Float>(0, 0)
    var fgScale = SIMD2<Float>(1, 1)
    var fgOffset = SIMD2<Float>(0, 0)
    var hasForeground: Float = 0
    /// 1 when the matte comes from person segmentation. Set per frame; not persisted.
    var personMode: Float = 0
    /// Colour temperature for the camera pixels only, -1 cool … +1 warm.
    var temperature: Float = 0
    /// 1 shows the foreground layer only over the subject, as a colour wash or light on them.
    var fgMasked: Float = 0
    /// Strength of the background's light on the subject, 0…1 (0 = off).
    var relight: Float = 0
    /// 0 only tints the lit areas; 1 also brightens them.
    var highlights: Float = 0.3
    /// Relight geometry, set per frame; not persisted.
    var hasFace: Float = 0
    var aspect: Float = 16.0 / 9
    var wrapRows: Float = 54
    var illumReset: Float = 0
    var faceEllipse = SIMD4<Float>(0.5, 0.5, 0.1, 0.18)
    var faceForward = SIMD4<Float>(0, 0, -1, 0)
    var light0 = SIMD4<Float>(repeating: 0)
    var light0Color = SIMD4<Float>(repeating: 0)
    var light1 = SIMD4<Float>(repeating: 0)
    var light1Color = SIMD4<Float>(repeating: 0)
    /// Foreground blend mode: index into ControlsView.blendModes, 0 = normal.
    var fgBlend: Float = 0
    /// Gaussian sigma in shadow-buffer pixels (not passed to the shader).
    var shadowBlur: Float = 6.0
    /// Gaussian sigma applied to the matte, in output pixels (not passed to the shader).
    var feather: Float = 1.0
    /// 1 draws the shadow; 0 skips it regardless of opacity (not passed to the shader).
    var shadowEnabled: Float = 1
    /// 1 keys the camera; 0 passes it through untouched (not passed to the shader).
    var keyEnabled: Float = 1
    /// Luma of the picked backdrop, only so the swatch can show the colour as seen (not passed to the shader).
    var keyLuma: Float = 0.6
    /// 1 applies the Color section; 0 leaves the camera colour alone (not passed to the shader).
    var colorEnabled: Float = 1

    init() {}

    /// Tolerant decoding so settings saved by older builds keep their values.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func f(_ k: CodingKeys, _ d: Float) -> Float { (try? c.decodeIfPresent(Float.self, forKey: k)) ?? d }
        func v(_ k: CodingKeys, _ d: SIMD2<Float>) -> SIMD2<Float> { (try? c.decodeIfPresent(SIMD2<Float>.self, forKey: k)) ?? d }
        let d = KeyParams()
        keyCbCr = v(.keyCbCr, d.keyCbCr); tolerance = f(.tolerance, d.tolerance); softness = f(.softness, d.softness)
        spill = f(.spill, d.spill)
        edge = f(.edge, d.edge)
        shadowOffset = v(.shadowOffset, d.shadowOffset); shadowOpacity = f(.shadowOpacity, d.shadowOpacity)
        shadowBlur = f(.shadowBlur, d.shadowBlur)
        temporal = f(.temporal, d.temporal); feather = f(.feather, d.feather)
        shadowEnabled = f(.shadowEnabled, d.shadowEnabled)
        keyEnabled = f(.keyEnabled, d.keyEnabled)
        keyLuma = f(.keyLuma, d.keyLuma)
        temperature = f(.temperature, d.temperature)
        colorEnabled = f(.colorEnabled, d.colorEnabled)
        fgMasked = f(.fgMasked, d.fgMasked)
        relight = f(.relight, d.relight)
        fgBlend = f(.fgBlend, d.fgBlend)
        highlights = f(.highlights, d.highlights)
    }
}

/// Keys each camera frame and composites it into a BGRA, IOSurface-backed
/// pixel buffer. One render pass, no CPU copies.
final class Renderer {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let mattePipeline: MTLRenderPipelineState
    private let matteTexture: MTLTexture
    private let shadowTexture: MTLTexture
    private var blur: MPSImageGaussianBlur?
    private var blurSigma: Float = -1
    /// Matte at processing resolution, ping-ponged so the pass can read last frame's.
    private var fullMatte: [MTLTexture] = []
    private var featherTexture: MTLTexture!
    /// Composite at processing resolution when supersampling; nil at 1x.
    private var hiTexture: MTLTexture?
    private let downsamplePipeline: MTLRenderPipelineState
    private var procScale = 0
    private var requestedScale = 1
    private var matteIndex = 0

    // Vision input: a small 4:2:0 copy rendered on the GPU.
    private let trackPipeline: MTLRenderPipelineState
    private let trackingPool: CVPixelBufferPool
    /// Textures over the IOSurfaces of camera, output, and tracking buffers.
    private let surfaces: SurfaceTextures
    static let trackingSize = (w: 640, h: 360)
    /// When set, every other frame also produces a 640x360 BGRA buffer for face tracking.
    var trackingEnabled = false
    /// Tracking frame every N rendered frames: 2 is the default 15 Hz, 1 is every frame.
    var trackingDivisor = 2
    var onTrackingFrame: ((CVPixelBuffer) -> Void)?
    private var frameIndex = 0

    // Stats
    var onStats: ((Double, Double, Double) -> Void)?   // (fps, gpu ms, mask ms per frame), about once a second, main thread
    /// Where the matte comes from: the chroma key, or Vision's person segmentation.
    /// `.system` keys the green that Apple's Background effect paints behind the
    /// subject, so the renderer treats it exactly like `.chroma`.
    enum MatteSource: Int, Codable { case chroma = 0, person, system }
    private var matte: MatteSource = .chroma
    var matteSource: MatteSource {
        get { lock.lock(); defer { lock.unlock() }; return matte }
        set { lock.lock(); matte = newValue; lock.unlock() }
    }
    private lazy var personMatter = PersonMatter(device: device)
    private var statMaskTime: Double = 0
    /// Guided-filter upsample of the person mask, at half the camera resolution.
    private var guidedPrepPipeline: MTLComputePipelineState!
    private var guidedCoefficientsPipeline: MTLComputePipelineState!
    /// Work-resolution textures: four gathered products and their means, the
    /// background estimate and its mean, and the coefficients and their mean.
    private var guideTextures: (prep: [MTLTexture], means: [MTLTexture], bgPrep: MTLTexture, bgMeans: MTLTexture, ab: MTLTexture, meansAB: MTLTexture, wide: [MTLTexture])?
    private var guideBox: MPSImageBox?
    /// A wider box for the trimap band: about 40 px at 1080p.
    private var wideBox: MPSImageBox?
    private static let wideRadius = 10
    /// Box radius in work-resolution pixels (about 8 px at 1080p) and the filter's regularisation.
    private static let guideRadius = 3
    private static let guideEpsilon: Float = 0.001

    /// Automatic colour temperature: measure the subject's and the background's
    /// average chroma every few frames and move the subject toward the background.
    var temperatureAuto = false {
        didSet {
            // Ease from the manual value when auto starts; keep what auto settled on when it stops.
            lock.lock()
            if temperatureAuto { autoTemperature = params.temperature } else { params.temperature = autoTemperature }
            lock.unlock()
        }
    }
    /// Called on the main thread with the smoothed automatic value when it changes.
    var onAutoTemperature: ((Float) -> Void)?
    private var colorStatsPipeline: MTLComputePipelineState!
    /// Relight: the background shrunk and blurred into a light map, the matte
    /// shrunk and blurred into a soft inside map, and the brightest region of
    /// each half of the light map read back as a light.
    private var lightScratch: MTLTexture!, lightTexture: MTLTexture!
    private var wrapScratch: MTLTexture!, wrapTexture: MTLTexture!
    private var shrinkPipeline: MTLComputePipelineState!
    private var rowExtentsPipeline: MTLComputePipelineState!
    private var rowExtentsBuffer: MTLBuffer!
    /// Illumination map: ping-pong history at a fraction of the output size,
    /// and a blurred copy of the current one for the composite to sample.
    private var illumPipeline: MTLRenderPipelineState!
    private var illumHistory: [MTLTexture] = []
    private var illumBlurred: MTLTexture!
    private var illumIndex = 0
    private var illumBlur: MPSImageGaussianBlur!
    private var illumValid = false
    private static let illumSize = (w: 240, h: 135)
    private var lightBlur: MPSImageGaussianBlur!, wrapBlur: MPSImageGaussianBlur!
    private static let lightSize = (w: 64, h: 36), wrapSize = (w: 96, h: 54)
    /// Position + brightness and colour for two lights, eased; under `lock`.
    private var lights = [SIMD4<Float>](repeating: .zero, count: 4)
    private var faceEllipse = SIMD4<Float>(0.5, 0.5, 0.1, 0.18)
    private var faceForward = SIMD4<Float>(0, 0, -1, 0)
    private var faceTime: Double = 0
    private var colorStatsBuffer: MTLBuffer!
    private var autoTemperature: Float = 0
    private static let colorStatsEvery = 6
    /// Warm direction in (Cb, Cr): less blue, more red.
    private static let warmAxis = simd_normalize(SIMD2<Float>(-1, 1))

    /// Multiplier from face size (1 at the reference size). Offset and blur
    /// scale with it; opacity scales inversely so a distant subject casts a
    /// shorter, sharper, denser shadow. Set from the tracker; read per frame.
    var shadowDepthScale: Float {
        get { lock.lock(); defer { lock.unlock() }; return depthScale }
        set { lock.lock(); depthScale = newValue; lock.unlock() }
    }
    private var depthScale: Float = 1
    private var statFrames = 0
    private var statGPUTime = 0.0
    private var statStart = CACurrentMediaTime()
    private var featherBlur: MPSImageGaussianBlur?
    private var featherSigma: Float = -1
    /// Shadow buffers are this fraction of the output size.
    private static let shadowScale = 4
    /// Extra room around the shadow matte on each side, as a fraction of the frame,
    /// so blur and offset can run past the frame edge.
    private static let shadowPadFraction: Float = 0.25
    private let outputPool: CVPixelBufferPool
    private let dummyBackground: MTLTexture

    private let lock = NSLock()
    private var params = KeyParams()
    private var background: MTLTexture?
    private var lastCameraBuffer: CVPixelBuffer?
    private var lastCamScale = SIMD2<Float>(1, 1)
    private var lastCamOffset = SIMD2<Float>(0, 0)

    let outputWidth = VirtualCameraConstants.width
    let outputHeight = VirtualCameraConstants.height

    /// Called on a Metal completion thread with the finished frame.
    var onOutput: ((CVPixelBuffer) -> Void)?

    init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            fatalError("Metal is unavailable")
        }
        self.device = device
        self.commandQueue = queue

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        desc.fragmentFunction = library.makeFunction(name: "chromaKey")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)

        let matteDesc = MTLRenderPipelineDescriptor()
        matteDesc.vertexFunction = desc.vertexFunction
        matteDesc.fragmentFunction = library.makeFunction(name: "mattePass")
        matteDesc.colorAttachments[0].pixelFormat = .r8Unorm
        mattePipeline = try! device.makeRenderPipelineState(descriptor: matteDesc)

        let shadowInner = (outputWidth / Self.shadowScale, outputHeight / Self.shadowScale)
        let shadowPadPx = (Int(Float(shadowInner.0) * Self.shadowPadFraction), Int(Float(shadowInner.1) * Self.shadowPadFraction))
        let shadowTexDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: shadowInner.0 + 2 * shadowPadPx.0, height: shadowInner.1 + 2 * shadowPadPx.1, mipmapped: false)
        shadowTexDesc.storageMode = .private
        shadowTexDesc.usage = [.shaderRead, .renderTarget]
        matteTexture = device.makeTexture(descriptor: shadowTexDesc)!
        shadowTexDesc.usage = [.shaderRead, .shaderWrite]
        shadowTexture = device.makeTexture(descriptor: shadowTexDesc)!

        let downDesc = MTLRenderPipelineDescriptor()
        downDesc.vertexFunction = desc.vertexFunction
        downDesc.fragmentFunction = library.makeFunction(name: "downsample")
        downDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        downsamplePipeline = try! device.makeRenderPipelineState(descriptor: downDesc)

        colorStatsPipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "colorStats")!)
        colorStatsBuffer = device.makeBuffer(length: 6 * MemoryLayout<UInt32>.size, options: .storageModeShared)
        func small(_ format: MTLPixelFormat, _ size: (w: Int, h: Int), shared: Bool = false) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.w, height: size.h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = shared ? .shared : .private
            return device.makeTexture(descriptor: d)!
        }
        lightScratch = small(.bgra8Unorm, Self.lightSize)
        lightTexture = small(.bgra8Unorm, Self.lightSize, shared: true)
        wrapScratch = small(.r8Unorm, Self.wrapSize)
        wrapTexture = small(.r8Unorm, Self.wrapSize)
        shrinkPipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "shrinkGrid")!)
        rowExtentsPipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "rowExtents")!)
        rowExtentsBuffer = device.makeBuffer(length: Self.wrapSize.h * MemoryLayout<SIMD2<Float>>.stride, options: .storageModePrivate)
        let illumDesc = MTLRenderPipelineDescriptor()
        illumDesc.vertexFunction = desc.vertexFunction
        illumDesc.fragmentFunction = library.makeFunction(name: "relightMap")
        illumDesc.colorAttachments[0].pixelFormat = .rgba16Float
        illumPipeline = try! device.makeRenderPipelineState(descriptor: illumDesc)
        let id = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Self.illumSize.w, height: Self.illumSize.h, mipmapped: false)
        id.storageMode = .private
        id.usage = [.shaderRead, .renderTarget, .shaderWrite]
        illumHistory = [device.makeTexture(descriptor: id)!, device.makeTexture(descriptor: id)!]
        illumBlurred = device.makeTexture(descriptor: id)!
        illumBlur = MPSImageGaussianBlur(device: device, sigma: 2.5); illumBlur.edgeMode = .clamp
        lightBlur = MPSImageGaussianBlur(device: device, sigma: 2.0); lightBlur.edgeMode = .clamp
        wrapBlur = MPSImageGaussianBlur(device: device, sigma: 1.5); wrapBlur.edgeMode = .clamp
        guidedPrepPipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "guidedPrep")!)
        guidedCoefficientsPipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "guidedCoefficients")!)

        let tl = MTLRenderPipelineDescriptor()
        tl.vertexFunction = desc.vertexFunction
        tl.fragmentFunction = library.makeFunction(name: "trackRGB")
        tl.colorAttachments[0].pixelFormat = .bgra8Unorm
        trackPipeline = try! device.makeRenderPipelineState(descriptor: tl)
        let trackAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Self.trackingSize.w,
            kCVPixelBufferHeightKey: Self.trackingSize.h,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var tpool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, trackAttrs as CFDictionary, &tpool)
        trackingPool = tpool!

        surfaces = SurfaceTextures(device: device)

        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: outputWidth,
            kCVPixelBufferHeightKey: outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary,
                                poolAttrs as CFDictionary, &pool)
        outputPool = pool!

        let dummyDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        dummyBackground = device.makeTexture(descriptor: dummyDesc)!
    }

    /// 1 keys at output size; 2 keys at double size (3840x2160) and box-downsamples.
    var processScale: Int {
        get { lock.lock(); defer { lock.unlock() }; return requestedScale }
        set { lock.lock(); requestedScale = max(1, min(newValue, 2)); lock.unlock() }
    }

    /// (Re)allocate the processing-resolution textures when the scale changes.
    /// Called from the render thread only.
    /// Colour guided filter at half camera resolution: gather, five box filters,
    /// coefficients, one more box filter. Returns the averaged (a, b) texture
    /// the matte pass applies and the local background colour estimate.
    private func encodeGuidedUpsample(_ cmd: MTLCommandBuffer, luma: MTLTexture, chroma: MTLTexture, mask: MTLTexture,
                                      params: KeyParams, camW: Int, camH: Int) -> (MTLTexture, MTLTexture, [MTLTexture]) {
        let w = max(camW / 2, 1), h = max(camH / 2, 1)
        if guideTextures == nil || guideTextures!.ab.width != w || guideTextures!.ab.height != h {
            func make() -> MTLTexture {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
                d.storageMode = .private
                d.usage = [.shaderRead, .shaderWrite]
                return device.makeTexture(descriptor: d)!
            }
            guideTextures = ((0..<4).map { _ in make() }, (0..<4).map { _ in make() }, make(), make(), make(), make(), (0..<4).map { _ in make() })
            let side = 2 * Self.guideRadius + 1
            guideBox = MPSImageBox(device: device, kernelWidth: side, kernelHeight: side)
            guideBox?.edgeMode = .clamp
            let wideSide = 2 * Self.wideRadius + 1
            wideBox = MPSImageBox(device: device, kernelWidth: wideSide, kernelHeight: wideSide)
            wideBox?.edgeMode = .clamp
        }
        guard let t = guideTextures, let box = guideBox, let wide = wideBox else { return (dummyBackground, dummyBackground, Array(repeating: dummyBackground, count: 4)) }
        let grid = MTLSize(width: w, height: h, depth: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        var epsilon = Self.guideEpsilon
        var p = params

        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(guidedPrepPipeline)
            enc.setTexture(luma, index: 0); enc.setTexture(chroma, index: 1); enc.setTexture(mask, index: 2)
            for i in 0..<4 { enc.setTexture(t.prep[i], index: 3 + i) }
            enc.setTexture(t.bgPrep, index: 7)
            enc.setBytes(&p, length: MemoryLayout<KeyParams>.stride, index: 0)
            enc.dispatchThreads(grid, threadsPerThreadgroup: group)
            enc.endEncoding()
        }
        for i in 0..<4 { box.encode(commandBuffer: cmd, sourceTexture: t.prep[i], destinationTexture: t.means[i]) }
        box.encode(commandBuffer: cmd, sourceTexture: t.bgPrep, destinationTexture: t.bgMeans)
        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(guidedCoefficientsPipeline)
            for i in 0..<4 { enc.setTexture(t.means[i], index: i) }
            enc.setTexture(t.ab, index: 4)
            enc.setBytes(&epsilon, length: MemoryLayout<Float>.size, index: 0)
            enc.dispatchThreads(grid, threadsPerThreadgroup: group)
            enc.endEncoding()
        }
        box.encode(commandBuffer: cmd, sourceTexture: t.ab, destinationTexture: t.meansAB)
        // Wide means for the trimap band: guide and mask, the mask-weighted guide, and the background estimate.
        wide.encode(commandBuffer: cmd, sourceTexture: t.prep[0], destinationTexture: t.wide[0])
        wide.encode(commandBuffer: cmd, sourceTexture: t.prep[2], destinationTexture: t.wide[1])
        wide.encode(commandBuffer: cmd, sourceTexture: t.prep[3], destinationTexture: t.wide[2])
        wide.encode(commandBuffer: cmd, sourceTexture: t.bgPrep, destinationTexture: t.wide[3])
        return (t.meansAB, t.bgMeans, t.wide)
    }

    private func ensureProcessTextures() {
        lock.lock(); let scale = requestedScale; lock.unlock()
        guard scale != procScale else { return }
        procScale = scale
        let w = outputWidth * scale, h = outputHeight * scale
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        d.storageMode = .private
        d.usage = [.shaderRead, .renderTarget]
        fullMatte = [device.makeTexture(descriptor: d)!, device.makeTexture(descriptor: d)!]
        d.usage = [.shaderRead, .shaderWrite]
        featherTexture = device.makeTexture(descriptor: d)!
        if scale > 1 {
            let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            c.storageMode = .private
            c.usage = [.shaderRead, .renderTarget]
            hiTexture = device.makeTexture(descriptor: c)
        } else {
            hiTexture = nil
        }
        featherSigma = -1
    }

    private var mirrorSource = false
    /// Mirror the camera source horizontally (movies flagged as flipped).
    var sourceMirrored: Bool {
        get { lock.lock(); defer { lock.unlock() }; return mirrorSource }
        set { lock.lock(); mirrorSource = newValue; lock.unlock() }
    }

    /// Output uv → camera uv mapping of the last rendered frame (aspect fill).
    /// A mirrored source has a negative x scale.
    var cameraMapping: (scale: SIMD2<Float>, offset: SIMD2<Float>) {
        lock.lock(); defer { lock.unlock() }
        return (lastCamScale, lastCamOffset)
    }

    // MARK: Parameters

    var keyParams: KeyParams {
        get { lock.lock(); defer { lock.unlock() }; return params }
        set { lock.lock(); params = newValue; lock.unlock() }
    }

    func update(_ body: (inout KeyParams) -> Void) {
        lock.lock(); body(&params); lock.unlock()
    }

    var backgroundTexture: MTLTexture? {
        get { lock.lock(); defer { lock.unlock() }; return background }
        set { lock.lock(); background = newValue; lock.unlock() }
    }
    private var foreground: MTLTexture?
    var foregroundTexture: MTLTexture? {
        get { lock.lock(); defer { lock.unlock() }; return foreground }
        set { lock.lock(); foreground = newValue; lock.unlock() }
    }

    // MARK: Rendering

    func render(_ camera: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(camera) == 2 else { return }
        let camW = CVPixelBufferGetWidthOfPlane(camera, 0)
        let camH = CVPixelBufferGetHeightOfPlane(camera, 0)
        let chromaW = CVPixelBufferGetWidthOfPlane(camera, 1)
        let chromaH = CVPixelBufferGetHeightOfPlane(camera, 1)

        guard let lumaTexture = surfaces.texture(camera, plane: 0, format: .r8Unorm, width: camW, height: camH),
              let chromaTexture = surfaces.texture(camera, plane: 1, format: .rg8Unorm, width: chromaW, height: chromaH) else { return }
        let luma = (texture: lumaTexture, cv: camera), chroma = (texture: chromaTexture, cv: camera)

        var outBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &outBuffer)
        guard let outBuffer,
              let outTexture = surfaces.texture(outBuffer, plane: 0, format: .bgra8Unorm, width: outputWidth, height: outputHeight) else { return }
        let out = (texture: outTexture, cv: outBuffer)

        var (camScale, camOffset) = Self.fill(sourceAspect: Float(camW) / Float(camH),
                                              destAspect: Float(outputWidth) / Float(outputHeight))
        lock.lock()
        if mirrorSource { camScale.x = -camScale.x; camOffset.x = 1 - camOffset.x }
        var p = params
        let bg = background
        let fg = foreground
        let depth = depthScale
        let previousCamera = lastCameraBuffer
        lastCameraBuffer = camera
        lastCamScale = camScale
        lastCamOffset = camOffset
        if p.colorEnabled < 0.5 || bg == nil { p.relight = 0 }   // nothing to light with
        if p.relight > 0 {
            p.aspect = Float(outputWidth) / Float(outputHeight)
            p.wrapRows = Float(Self.wrapSize.h)
            p.hasFace = CACurrentMediaTime() - faceTime < 1.0 ? 1 : 0
            p.faceEllipse = faceEllipse; p.faceForward = faceForward
            p.light0 = lights[0]; p.light0Color = lights[1]; p.light1 = lights[2]; p.light1Color = lights[3]
        }
        lock.unlock()

        p.camScale = camScale
        p.camOffset = camOffset
        p.videoRange = Self.isVideoRange(camera) ? 1 : 0
        if p.shadowEnabled < 0.5 { p.shadowOpacity = 0 }
        if p.keyEnabled < 0.5 { p.bypass = 1 }   // chromakey off: plain camera, no shadow
        if depth != 1 {
            p.shadowOffset *= depth
            p.shadowBlur *= depth
            p.shadowOpacity = min(1, p.shadowOpacity / depth.squareRoot())
        }
        p.chromaTexel = SIMD2<Float>(1 / Float(chromaW), 1 / Float(chromaH))
        // Shrink is set in 1920×1080 output pixels; the shader erodes in chroma
        // texels, so convert for this source's resolution and aspect-fill scale.
        p.edge *= abs(camScale.x) * Float(chromaW) / Float(VirtualCameraConstants.width)
        if let bg {
            p.hasBackground = 1
            (p.bgScale, p.bgOffset) = Self.fill(sourceAspect: Float(bg.width) / Float(bg.height),
                                                destAspect: Float(outputWidth) / Float(outputHeight))
        } else {
            p.hasBackground = 0
        }
        if let fg {
            p.hasForeground = 1
            (p.fgScale, p.fgOffset) = Self.fill(sourceAspect: Float(fg.width) / Float(fg.height),
                                                destAspect: Float(outputWidth) / Float(outputHeight))
        } else {
            p.hasForeground = 0
        }

        // Person matte: segment this very frame before compositing it, so the
        // matte never lags the image. Vision gets the small BGRA frame, made
        // first in its own command buffer (a fraction of a millisecond on the
        // GPU), not the full camera frame it would otherwise convert on the CPU.
        var maskTexture: MTLTexture = dummyBackground
        var maskKeepAlive: Any? = nil
        var small: CVPixelBuffer? = nil
        lock.lock(); let usePerson = matte == .person; let auto = temperatureAuto && p.colorEnabled > 0.5; lock.unlock()
        if auto { p.temperature = autoTemperature }
        if p.colorEnabled < 0.5 { p.temperature = 0 }
        if usePerson, p.bypass < 0.5, let pre = commandQueue.makeCommandBuffer(),
           let frame = encodeTrackingFrame(pre, luma: luma.texture, chroma: chroma.texture, params: &p) {
            pre.commit()
            pre.waitUntilCompleted()
            small = frame
        }
        if usePerson, p.bypass < 0.5, let small, let mask = personMatter.mask(for: small) {
            maskTexture = mask.texture
            maskKeepAlive = mask.keepAlive
            p.personMode = 1
            statMaskTime += personMatter.lastMilliseconds
        } else {
            p.personMode = 0
        }

        ensureProcessTextures()
        guard let cmd = commandQueue.makeCommandBuffer() else { return }

        // Guided-filter upsample of the person mask against this frame's colour,
        // plus a local background colour estimate for edge decontamination.
        var guideTexture: MTLTexture = dummyBackground
        var backgroundEstimate: MTLTexture = dummyBackground
        var wideTextures: [MTLTexture] = Array(repeating: dummyBackground, count: 4)
        if p.personMode > 0.5 {
            (guideTexture, backgroundEstimate, wideTextures) = encodeGuidedUpsample(cmd, luma: luma.texture, chroma: chroma.texture, mask: maskTexture, params: p, camW: camW, camH: camH)
        }

        // Previous frame's luma for motion detection in the temporal blend.
        var prevLuma: (texture: MTLTexture, cv: CVPixelBuffer)? = nil
        if let previousCamera, p.temporal > 0,
           CVPixelBufferGetWidthOfPlane(previousCamera, 0) == camW, CVPixelBufferGetHeightOfPlane(previousCamera, 0) == camH,
           let t = surfaces.texture(previousCamera, plane: 0, format: .r8Unorm, width: camW, height: camH) {
            prevLuma = (t, previousCamera)
        }
        if prevLuma == nil { p.temporal = 0 }

        func encodeMatte(into target: MTLTexture, previous: MTLTexture, params: KeyParams) {
            var mp = params
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let menc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            menc.setRenderPipelineState(mattePipeline)
            menc.setFragmentTexture(luma.texture, index: 0)
            menc.setFragmentTexture(chroma.texture, index: 1)
            menc.setFragmentTexture(previous, index: 4)
            menc.setFragmentTexture(prevLuma?.texture ?? dummyBackground, index: 5)
            menc.setFragmentTexture(maskTexture, index: 6)
            menc.setFragmentTexture(guideTexture, index: 7)
            for (i, t) in wideTextures.enumerated() { menc.setFragmentTexture(t, index: 8 + i) }
            menc.setFragmentBytes(&mp, length: MemoryLayout<KeyParams>.stride, index: 0)
            menc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            menc.endEncoding()
        }

        // Key matte at full resolution, temporally blended with last frame's.
        let current = fullMatte[matteIndex]
        let previous = fullMatte[1 - matteIndex]
        matteIndex = 1 - matteIndex
        encodeMatte(into: current, previous: previous, params: p)
        var matteSource: MTLTexture = current
        if p.feather >= 0.3 {
            let sigma = p.feather * Float(procScale)   // feather is specified in output pixels
            if featherBlur == nil || featherSigma != sigma {
                featherBlur = MPSImageGaussianBlur(device: device, sigma: sigma)
                featherBlur?.edgeMode = .clamp
                featherSigma = sigma
            }
            featherBlur?.encode(commandBuffer: cmd, sourceTexture: current, destinationTexture: featherTexture)
            matteSource = featherTexture
        }

        // Shadow: low-res matte (no temporal term; the blur hides noise), then a Gaussian blur.
        var shadowSource: MTLTexture = dummyBackground
        let shadowPad = SIMD2<Float>(Float(matteTexture.width - outputWidth / Self.shadowScale) / 2 / Float(matteTexture.width),
                                     Float(matteTexture.height - outputHeight / Self.shadowScale) / 2 / Float(matteTexture.height))
        if p.shadowOpacity > 0 && p.bypass < 0.5 {
            var sp = p
            sp.temporal = 0
            sp.shadowPad = shadowPad
            encodeMatte(into: matteTexture, previous: dummyBackground, params: sp)
            if p.shadowBlur >= 0.5 {
                if blur == nil || blurSigma != p.shadowBlur {
                    blur = MPSImageGaussianBlur(device: device, sigma: p.shadowBlur)
                    blur?.edgeMode = .clamp
                    blurSigma = p.shadowBlur
                }
                blur?.encode(commandBuffer: cmd, sourceTexture: matteTexture, destinationTexture: shadowTexture)
                shadowSource = shadowTexture
            } else {
                shadowSource = matteTexture
            }
        }

        // Relight maps: the background to 64×36 and blurred, the matte to 96×54
        // and blurred. A grid-sampling kernel does the big downscale cheaply.
        let relighting = p.relight > 0 && p.bypass < 0.5 && bg != nil
        if relighting, let bg, let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(shrinkPipeline)
            for (src, dst) in [(bg, lightScratch!), (matteSource, wrapScratch!)] {
                enc.setTexture(src, index: 0); enc.setTexture(dst, index: 1)
                enc.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 6, depth: 1))
            }
            enc.endEncoding()
            lightBlur.encode(commandBuffer: cmd, sourceTexture: lightScratch, destinationTexture: lightTexture)
            wrapBlur.encode(commandBuffer: cmd, sourceTexture: wrapScratch, destinationTexture: wrapTexture)
            if let rows = cmd.makeComputeCommandEncoder() {
                rows.setComputePipelineState(rowExtentsPipeline)
                rows.setTexture(wrapTexture, index: 0)
                rows.setBuffer(rowExtentsBuffer, offset: 0, index: 0)
                rows.dispatchThreads(MTLSize(width: Self.wrapSize.h, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: Self.wrapSize.h, height: 1, depth: 1))
                rows.endEncoding()
            }
            // Illumination map, eased against last frame's, then blurred for the composite.
            let previous = illumHistory[1 - illumIndex], current = illumHistory[illumIndex]
            illumIndex = 1 - illumIndex
            p.illumReset = illumValid ? 0 : 1
            illumValid = true
            let ip = MTLRenderPassDescriptor()
            ip.colorAttachments[0].texture = current
            ip.colorAttachments[0].loadAction = .dontCare
            ip.colorAttachments[0].storeAction = .store
            if let ienc = cmd.makeRenderCommandEncoder(descriptor: ip) {
                ienc.setRenderPipelineState(illumPipeline)
                ienc.setFragmentTexture(lightTexture, index: 0)
                ienc.setFragmentTexture(wrapTexture, index: 1)
                ienc.setFragmentTexture(previous, index: 2)
                ienc.setFragmentBytes(&p, length: MemoryLayout<KeyParams>.stride, index: 0)
                ienc.setFragmentBuffer(rowExtentsBuffer, offset: 0, index: 1)
                ienc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                ienc.endEncoding()
            }
            illumBlur.encode(commandBuffer: cmd, sourceTexture: current, destinationTexture: illumBlurred)
        } else {
            illumValid = false   // next time the relight starts, it ramps in from nothing
        }
        let measureLights = relighting && frameIndex % Self.colorStatsEvery == 3

        // Colour statistics for the automatic temperature, every few frames.
        let measureColor = auto && frameIndex % Self.colorStatsEvery == 0
        if measureColor, let blit = cmd.makeBlitCommandEncoder() {
            blit.fill(buffer: colorStatsBuffer, range: 0..<colorStatsBuffer.length, value: 0)
            blit.endEncoding()
            if let enc = cmd.makeComputeCommandEncoder() {
                enc.setComputePipelineState(colorStatsPipeline)
                enc.setTexture(luma.texture, index: 0); enc.setTexture(chroma.texture, index: 1)
                enc.setTexture(matteSource, index: 2); enc.setTexture(bg ?? dummyBackground, index: 3)
                enc.setBytes(&p, length: MemoryLayout<KeyParams>.stride, index: 0)
                enc.setBuffer(colorStatsBuffer, offset: 0, index: 1)
                enc.dispatchThreads(MTLSize(width: 96, height: 54, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 9, depth: 1))
                enc.endEncoding()
            }
        }

        // Composite at processing resolution, straight into the output at 1x.
        let compositeTarget = hiTexture ?? out.texture
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = compositeTarget
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(luma.texture, index: 0)
        enc.setFragmentTexture(chroma.texture, index: 1)
        enc.setFragmentTexture(bg ?? dummyBackground, index: 2)
        enc.setFragmentTexture(shadowSource, index: 3)
        enc.setFragmentTexture(matteSource, index: 4)
        enc.setFragmentTexture(fg ?? dummyBackground, index: 5)
        enc.setFragmentTexture(backgroundEstimate, index: 6)
        enc.setFragmentTexture(illumBlurred, index: 7)
        p.shadowPad = shadowPad
        enc.setFragmentBytes(&p, length: MemoryLayout<KeyParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        if let hiTexture {
            let down = MTLRenderPassDescriptor()
            down.colorAttachments[0].texture = out.texture
            down.colorAttachments[0].loadAction = .dontCare
            down.colorAttachments[0].storeAction = .store
            if let denc = cmd.makeRenderCommandEncoder(descriptor: down) {
                denc.setRenderPipelineState(downsamplePipeline)
                denc.setFragmentTexture(hiTexture, index: 0)
                denc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                denc.endEncoding()
            }
        }

        // Small frame for face tracking, on the tracker's cadence. In person
        // mode this frame's small picture already exists.
        frameIndex &+= 1
        var trackingBuffer: CVPixelBuffer?
        if trackingEnabled && frameIndex % max(trackingDivisor, 1) == 0 {
            trackingBuffer = small ?? encodeTrackingFrame(cmd, luma: luma.texture, chroma: chroma.texture, params: &p)
        }

        let keepAlive: [Any] = [camera, outBuffer] + (prevLuma.map { [$0.cv] } ?? []) + (trackingBuffer.map { [$0] } ?? []) + (small.map { [$0] } ?? []) + (maskKeepAlive.map { [$0] } ?? [])
        cmd.addCompletedHandler { [weak self] buffer in
            withExtendedLifetime(keepAlive) {}
            guard let self else { return }
            onOutput?(outBuffer)
            if let trackingBuffer { onTrackingFrame?(trackingBuffer) }
            if measureColor { updateAutoTemperature() }
            if measureLights { updateLights(bgScale: p.bgScale, bgOffset: p.bgOffset) }
            recordStats(buffer)
        }
        cmd.commit()
    }

    /// Render the camera into a 640×360 BGRA buffer from the tracking pool.
    private func encodeTrackingFrame(_ cmd: MTLCommandBuffer, luma: MTLTexture, chroma: MTLTexture, params p: inout KeyParams) -> CVPixelBuffer? {
        var tb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, trackingPool, &tb)
        guard let tb, let target = surfaces.texture(tb, plane: 0, format: .bgra8Unorm, width: Self.trackingSize.w, height: Self.trackingSize.h) else { return nil }
        let tp = MTLRenderPassDescriptor()
        tp.colorAttachments[0].texture = target
        tp.colorAttachments[0].loadAction = .dontCare
        tp.colorAttachments[0].storeAction = .store
        guard let tenc = cmd.makeRenderCommandEncoder(descriptor: tp) else { return nil }
        tenc.setRenderPipelineState(trackPipeline)
        tenc.setFragmentTexture(luma, index: 0)
        tenc.setFragmentTexture(chroma, index: 1)
        tenc.setFragmentBytes(&p, length: MemoryLayout<KeyParams>.stride, index: 0)
        tenc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        tenc.endEncoding()
        return tb
    }

    /// Head geometry for the relight, from the face tracker: an ellipse a little
    /// larger than the face box, so it covers hair and ears, and the direction
    /// the face points. Eased so detection jitter does not flicker the light.
    func setFace(_ state: FaceState) {
        lock.lock(); defer { lock.unlock() }
        guard state.detected, let box = state.box, let c = state.center, let pose = state.pose, pose.count == 16 else {
            faceTime = 0; return
        }
        let ellipse = SIMD4<Float>(c.x, c.y, box.w * 0.62, box.h * 0.72)
        let forward = SIMD4<Float>(-pose[8], -pose[9], -pose[10], 0)   // R·(0,0,-1)
        if faceTime == 0 {
            faceEllipse = ellipse; faceForward = forward
        } else {
            faceEllipse += (ellipse - faceEllipse) * 0.35
            faceForward += (forward - faceForward) * 0.35
        }
        faceTime = CACurrentMediaTime()
    }

    /// Read the light map back and ease the two lights toward the brightest
    /// region of each half: luma-cubed weighting finds the sources rather than
    /// the average glow. Position is converted from background to output uv.
    private func updateLights(bgScale: SIMD2<Float>, bgOffset: SIMD2<Float>) {
        let w = Self.lightSize.w, h = Self.lightSize.h
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        lightTexture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let lumaWeights = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        var target = [SIMD4<Float>](repeating: .zero, count: 4)
        for half in 0..<2 {
            var sw: Float = 0, sx: Float = 0, sy: Float = 0, sc = SIMD3<Float>(repeating: 0)
            for y in 0..<h {
                for x in (half == 0 ? 0..<w / 2 : w / 2..<w) {
                    let i = (y * w + x) * 4
                    let c = SIMD3<Float>(Float(bytes[i + 2]), Float(bytes[i + 1]), Float(bytes[i])) / 255   // BGRA
                    let lum = simd_dot(c, lumaWeights)
                    let wgt = lum * lum * lum
                    sw += wgt; sx += wgt * (Float(x) + 0.5) / Float(w); sy += wgt * (Float(y) + 0.5) / Float(h); sc += wgt * c
                }
            }
            guard sw > 1e-3 else { continue }
            let colour = sc / sw
            let t = min(max((simd_dot(colour, lumaWeights) - 0.08) / (0.45 - 0.08), 0), 1)
            let brightness = t * t * (3 - 2 * t)
            let pos = (SIMD2<Float>(sx, sy) / sw - bgOffset) / bgScale
            target[half * 2] = SIMD4<Float>(pos.x, pos.y, brightness, 0)
            target[half * 2 + 1] = SIMD4<Float>(colour / max(colour.max(), 1e-3), 0)
        }
        lock.lock()
        for i in 0..<4 { lights[i] += (target[i] - lights[i]) * 0.25 }
        lock.unlock()
    }

    /// Read the colour sums back and ease the automatic temperature toward the
    /// value that moves the subject's average chroma onto the background's.
    private func updateAutoTemperature() {
        let sums = colorStatsBuffer.contents().bindMemory(to: UInt32.self, capacity: 6)
        var target: Float = 0
        if sums[2] > 1024 * 50, sums[5] > 1024 * 50 {   // enough subject and enough background
            let subject = SIMD2<Float>(Float(sums[0]), Float(sums[1])) / Float(sums[2])
            let background = SIMD2<Float>(Float(sums[3]), Float(sums[4])) / Float(sums[5])
            let delta = simd_dot(background - subject, Self.warmAxis)
            target = min(max(delta / 0.12, -1), 1)   // half strength: a tinted scene lands mid-range, not at the stop
        }
        let next = autoTemperature + (target - autoTemperature) * 0.15
        guard abs(next - autoTemperature) > 0.002 || (target == 0 && autoTemperature != 0) else { return }
        autoTemperature = next
        if let onAutoTemperature { let value = next; DispatchQueue.main.async { onAutoTemperature(value) } }
    }

    /// Sample the key colour from the most recent camera frame.
    /// `uv` is in output space, origin top-left.
    func pickKey(atOutputUV uv: CGPoint, radius: Int = 2) {
        lock.lock()
        let camera = lastCameraBuffer
        let scale = lastCamScale, offset = lastCamOffset
        lock.unlock()
        guard let camera else { return }

        let u = Float(uv.x) * scale.x + offset.x
        let v = Float(uv.y) * scale.y + offset.y

        CVPixelBufferLockBaseAddress(camera, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(camera, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(camera, 1) else { return }
        let w = CVPixelBufferGetWidthOfPlane(camera, 1)
        let h = CVPixelBufferGetHeightOfPlane(camera, 1)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(camera, 1)
        let cx = min(max(Int(u * Float(w)), 0), w - 1)
        let cy = min(max(Int(v * Float(h)), 0), h - 1)

        var sumCb = 0, sumCr = 0, n = 0
        for y in max(cy - radius, 0)...min(cy + radius, h - 1) {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in max(cx - radius, 0)...min(cx + radius, w - 1) {
                sumCb += Int(row[x * 2]); sumCr += Int(row[x * 2 + 1]); n += 1
            }
        }
        guard n > 0 else { return }
        let video = Self.isVideoRange(camera)
        let key = Self.chroma(Double(sumCb) / Double(n), Double(sumCr) / Double(n), videoRange: video)
        let luma = Self.averageLuma(camera, aroundU: u, v: v, radius: radius * 2, videoRange: video)
        lock.lock(); params.keyCbCr = key; if let luma { params.keyLuma = luma }; lock.unlock()
    }

    /// Mean full-range luma of plane 0 around a camera uv.
    private static func averageLuma(_ camera: CVPixelBuffer, aroundU u: Float, v: Float, radius: Int, videoRange: Bool) -> Float? {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(camera, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(camera, 0), h = CVPixelBufferGetHeightOfPlane(camera, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(camera, 0)
        let cx = min(max(Int(u * Float(w)), 0), w - 1), cy = min(max(Int(v * Float(h)), 0), h - 1)
        var sum = 0, n = 0
        for y in max(cy - radius, 0)...min(cy + radius, h - 1) {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in max(cx - radius, 0)...min(cx + radius, w - 1) { sum += Int(row[x]); n += 1 }
        }
        guard n > 0 else { return nil }
        let y = Float(sum) / Float(n) / 255
        return videoRange ? (y - 16 / 255) * (255 / 219) : y
    }

    /// Guess the key colour: mean chroma of saturated pixels in the outer
    /// border of the latest frame, where the backdrop usually is.
    func autoKey() {
        lock.lock()
        let camera = lastCameraBuffer
        lock.unlock()
        guard let camera else { return }
        CVPixelBufferLockBaseAddress(camera, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(camera, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(camera, 1) else { return }
        let w = CVPixelBufferGetWidthOfPlane(camera, 1), h = CVPixelBufferGetHeightOfPlane(camera, 1)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(camera, 1)
        let mx = w / 8, my = h / 8, step = 4
        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(camera, 0)
        let lumaBpr = CVPixelBufferGetBytesPerRowOfPlane(camera, 0)
        var sumCb = 0.0, sumCr = 0.0, sumY = 0.0, n = 0
        for y in stride(from: 0, to: h, by: step) {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: w, by: step) {
                let border = x < mx || x >= w - mx || y < my || y >= h - my
                guard border else { continue }
                let cb = Double(row[x * 2]) / 255 - 0.5, cr = Double(row[x * 2 + 1]) / 255 - 0.5
                guard cb * cb + cr * cr > 0.08 * 0.08 else { continue }   // skip neutrals
                sumCb += cb; sumCr += cr; n += 1
                if let lumaBase { sumY += Double(lumaBase.advanced(by: y * 2 * lumaBpr).assumingMemoryBound(to: UInt8.self)[x * 2]) / 255 }
            }
        }
        guard n > 20 else { return }
        let video = Self.isVideoRange(camera)
        let key = Self.chroma((sumCb / Double(n) + 0.5) * 255, (sumCr / Double(n) + 0.5) * 255, videoRange: video)
        var luma = Float(sumY / Double(n))
        if video { luma = (luma - 16 / 255) * (255 / 219) }
        lock.lock(); params.keyCbCr = key; if lumaBase != nil { params.keyLuma = luma }; lock.unlock()
    }

    private func recordStats(_ buffer: MTLCommandBuffer) {
        statFrames += 1
        statGPUTime += max(buffer.gpuEndTime - buffer.gpuStartTime, 0)
        let now = CACurrentMediaTime()
        let elapsed = now - statStart
        guard elapsed >= 1 else { return }
        let fps = Double(statFrames) / elapsed
        let gpuMs = statGPUTime / Double(statFrames) * 1000
        let maskMs = statMaskTime / Double(statFrames)
        statFrames = 0; statGPUTime = 0; statMaskTime = 0; statStart = now
        statsLog.info("\(fps, format: .fixed(precision: 1)) fps, GPU \(gpuMs, format: .fixed(precision: 2)) ms/frame, mask \(maskMs, format: .fixed(precision: 2)) ms")
        if let onStats { DispatchQueue.main.async { onStats(fps, gpuMs, maskMs) } }
    }

    static func isVideoRange(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    /// Raw chroma bytes → full-range normalised Cb/Cr.
    private static func chroma(_ cb: Double, _ cr: Double, videoRange: Bool) -> SIMD2<Float> {
        var c = SIMD2<Float>(Float(cb / 255), Float(cr / 255))
        if videoRange { c = (c - 0.5) * (255.0 / 224.0) + 0.5 }
        return c
    }

    // MARK: Helpers

    /// Scale/offset mapping destination uv to source uv so the source covers
    /// the destination (aspect fill, centred).
    static func fill(sourceAspect: Float, destAspect: Float) -> (SIMD2<Float>, SIMD2<Float>) {
        if sourceAspect > destAspect {
            let s = destAspect / sourceAspect
            return (SIMD2(s, 1), SIMD2((1 - s) / 2, 0))
        } else {
            let s = sourceAspect / destAspect
            return (SIMD2(1, s), SIMD2(0, (1 - s) / 2))
        }
    }
}

/// Metal textures over pixel buffers' IOSurfaces, cached by surface. Pools
/// recycle the same few surfaces, so after the first frames every lookup is
/// a dictionary hit instead of a CVMetalTextureCache call, which costs about
/// a tenth of a millisecond each and runs several times per frame.
///
/// Each texture retains its surface, so a surface's ID cannot be reused while
/// its texture is cached. Entries unused for a while are dropped, so a source
/// change does not keep a stale pool alive. Used from the render thread only.
final class SurfaceTextures {
    private struct Key: Hashable { let id: IOSurfaceID; let plane: Int; let format: MTLPixelFormat }
    private var entries: [Key: (texture: MTLTexture, surface: IOSurfaceRef, lastUse: UInt64)] = [:]
    private var tick: UInt64 = 0
    private let device: MTLDevice

    init(device: MTLDevice) { self.device = device }

    func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
        tick &+= 1
        let key = Key(id: IOSurfaceGetID(surface), plane: plane, format: format)
        if let hit = entries[key], hit.surface === surface {
            entries[key]!.lastUse = tick
            return hit.texture
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d, iosurface: surface, plane: plane) else { return nil }
        entries[key] = (texture, surface, tick)
        if tick % 256 == 0 {   // drop what has not been used for roughly the last two seconds
            entries = entries.filter { tick &- $0.value.lastUse < 600 }
        }
        return texture
    }
}
