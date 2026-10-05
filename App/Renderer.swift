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
    private let trackLumaPipeline: MTLRenderPipelineState
    private let trackChromaPipeline: MTLRenderPipelineState
    private let trackingPool: CVPixelBufferPool
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
    enum MatteSource: Int, Codable { case chroma = 0, person }
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
    private var guideTextures: (prep: MTLTexture, means: MTLTexture, ab: MTLTexture, meansAB: MTLTexture)?
    private var guideBox4: MPSImageBox?
    private var guideBox2: MPSImageBox?
    /// Box radius in work-resolution pixels (about 8 px at 1080p) and the filter's regularisation.
    private static let guideRadius = 3
    private static let guideEpsilon: Float = 0.001

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
    private var textureCache: CVMetalTextureCache?
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

        guidedPrepPipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "guidedPrep")!)
        guidedCoefficientsPipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "guidedCoefficients")!)

        let tl = MTLRenderPipelineDescriptor()
        tl.vertexFunction = desc.vertexFunction
        tl.fragmentFunction = library.makeFunction(name: "trackLuma")
        tl.colorAttachments[0].pixelFormat = .r8Unorm
        trackLumaPipeline = try! device.makeRenderPipelineState(descriptor: tl)
        let tc = MTLRenderPipelineDescriptor()
        tc.vertexFunction = desc.vertexFunction
        tc.fragmentFunction = library.makeFunction(name: "trackChroma")
        tc.colorAttachments[0].pixelFormat = .rg8Unorm
        trackChromaPipeline = try! device.makeRenderPipelineState(descriptor: tc)
        let trackAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: Self.trackingSize.w,
            kCVPixelBufferHeightKey: Self.trackingSize.h,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var tpool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, trackAttrs as CFDictionary, &tpool)
        trackingPool = tpool!

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

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
    /// Four passes at half camera resolution: gather, box filter, coefficients,
    /// box filter. Returns the averaged (a, b) texture the matte pass applies.
    private func encodeGuidedUpsample(_ cmd: MTLCommandBuffer, luma: MTLTexture, mask: MTLTexture, camW: Int, camH: Int) -> MTLTexture {
        let w = max(camW / 2, 1), h = max(camH / 2, 1)
        if guideTextures == nil || guideTextures!.prep.width != w || guideTextures!.prep.height != h {
            func make(_ format: MTLPixelFormat) -> MTLTexture {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
                d.storageMode = .private
                d.usage = [.shaderRead, .shaderWrite]
                return device.makeTexture(descriptor: d)!
            }
            guideTextures = (make(.rgba16Float), make(.rgba16Float), make(.rg16Float), make(.rg16Float))
            let side = 2 * Self.guideRadius + 1
            guideBox4 = MPSImageBox(device: device, kernelWidth: side, kernelHeight: side)
            guideBox4?.edgeMode = .clamp
            guideBox2 = MPSImageBox(device: device, kernelWidth: side, kernelHeight: side)
            guideBox2?.edgeMode = .clamp
        }
        guard let t = guideTextures, let box4 = guideBox4, let box2 = guideBox2 else { return dummyBackground }
        let grid = MTLSize(width: w, height: h, depth: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        var epsilon = Self.guideEpsilon

        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(guidedPrepPipeline)
            enc.setTexture(luma, index: 0); enc.setTexture(mask, index: 1); enc.setTexture(t.prep, index: 2)
            enc.dispatchThreads(grid, threadsPerThreadgroup: group)
            enc.endEncoding()
        }
        box4.encode(commandBuffer: cmd, sourceTexture: t.prep, destinationTexture: t.means)
        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(guidedCoefficientsPipeline)
            enc.setTexture(t.means, index: 0); enc.setTexture(t.ab, index: 1)
            enc.setBytes(&epsilon, length: MemoryLayout<Float>.size, index: 0)
            enc.dispatchThreads(grid, threadsPerThreadgroup: group)
            enc.endEncoding()
        }
        box2.encode(commandBuffer: cmd, sourceTexture: t.ab, destinationTexture: t.meansAB)
        return t.meansAB
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
        guard CVPixelBufferGetPlaneCount(camera) == 2, let cache = textureCache else { return }
        let camW = CVPixelBufferGetWidthOfPlane(camera, 0)
        let camH = CVPixelBufferGetHeightOfPlane(camera, 0)
        let chromaW = CVPixelBufferGetWidthOfPlane(camera, 1)
        let chromaH = CVPixelBufferGetHeightOfPlane(camera, 1)

        guard let luma = Self.texture(cache, camera, plane: 0, format: .r8Unorm, width: camW, height: camH),
              let chroma = Self.texture(cache, camera, plane: 1, format: .rg8Unorm, width: chromaW, height: chromaH) else { return }

        var outBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &outBuffer)
        guard let outBuffer,
              let out = Self.texture(cache, outBuffer, plane: 0, format: .bgra8Unorm, width: outputWidth, height: outputHeight) else { return }

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
        // matte never lags the image. A few milliseconds on the Neural Engine.
        var maskTexture: MTLTexture = dummyBackground
        var maskKeepAlive: Any? = nil
        lock.lock(); let usePerson = matte == .person; lock.unlock()
        if usePerson, p.bypass < 0.5, let mask = personMatter.mask(for: camera) {
            maskTexture = mask.texture
            maskKeepAlive = mask.keepAlive
            p.personMode = 1
            statMaskTime += personMatter.lastMilliseconds
        } else {
            p.personMode = 0
        }

        ensureProcessTextures()
        guard let cmd = commandQueue.makeCommandBuffer() else { return }

        // Guided-filter upsample of the person mask against this frame's luma.
        var guideTexture: MTLTexture = dummyBackground
        if p.personMode > 0.5 {
            guideTexture = encodeGuidedUpsample(cmd, luma: luma.texture, mask: maskTexture, camW: camW, camH: camH)
        }

        // Previous frame's luma for motion detection in the temporal blend.
        var prevLuma: (texture: MTLTexture, cv: CVMetalTexture)? = nil
        if let previousCamera, p.temporal > 0,
           CVPixelBufferGetWidthOfPlane(previousCamera, 0) == camW, CVPixelBufferGetHeightOfPlane(previousCamera, 0) == camH {
            prevLuma = Self.texture(cache, previousCamera, plane: 0, format: .r8Unorm, width: camW, height: camH)
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

        // Small frame for face tracking, every frame or every other one.
        frameIndex &+= 1
        var trackingBuffer: CVPixelBuffer?
        var trackingTex: [CVMetalTexture] = []
        if trackingEnabled && frameIndex % max(trackingDivisor, 1) == 0 {
            var tb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, trackingPool, &tb)
            if let tb,
               let ty = Self.texture(cache, tb, plane: 0, format: .r8Unorm, width: Self.trackingSize.w, height: Self.trackingSize.h),
               let tcc = Self.texture(cache, tb, plane: 1, format: .rg8Unorm, width: Self.trackingSize.w / 2, height: Self.trackingSize.h / 2) {
                for (target, pipelineState) in [(ty.texture, trackLumaPipeline), (tcc.texture, trackChromaPipeline)] {
                    let tp = MTLRenderPassDescriptor()
                    tp.colorAttachments[0].texture = target
                    tp.colorAttachments[0].loadAction = .dontCare
                    tp.colorAttachments[0].storeAction = .store
                    guard let tenc = cmd.makeRenderCommandEncoder(descriptor: tp) else { continue }
                    tenc.setRenderPipelineState(pipelineState)
                    tenc.setFragmentTexture(luma.texture, index: 0)
                    tenc.setFragmentTexture(chroma.texture, index: 1)
                    tenc.setFragmentBytes(&p, length: MemoryLayout<KeyParams>.stride, index: 0)
                    tenc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    tenc.endEncoding()
                }
                trackingBuffer = tb
                trackingTex = [ty.cv, tcc.cv]
            }
        }

        let keepAlive: [Any] = [luma.cv, chroma.cv, out.cv] + (prevLuma.map { [$0.cv] } ?? []) + trackingTex + (maskKeepAlive.map { [$0] } ?? [])
        cmd.addCompletedHandler { [weak self] buffer in
            withExtendedLifetime(keepAlive) {}
            guard let self else { return }
            onOutput?(outBuffer)
            if let trackingBuffer { onTrackingFrame?(trackingBuffer) }
            recordStats(buffer)
        }
        cmd.commit()
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

    private static func texture(_ cache: CVMetalTextureCache, _ buffer: CVPixelBuffer, plane: Int,
                                format: MTLPixelFormat, width: Int, height: Int) -> (texture: MTLTexture, cv: CVMetalTexture)? {
        var cv: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil,
                                                               format, width, height, plane, &cv)
        guard status == kCVReturnSuccess, let cv, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        return (tex, cv)
    }

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
