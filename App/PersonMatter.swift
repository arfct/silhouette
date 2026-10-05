import CoreVideo
import Metal
import QuartzCore
import Vision

/// Person segmentation on the Neural Engine, as a Metal texture per frame.
///
/// Synchronous on purpose: the renderer asks for the mask of the frame it is
/// about to composite, so the matte always matches the image. Measured on an
/// M-series Mac: `.fast` is about 2.5 ms and returns a 256×192 mask; `.balanced`
/// is about 17 ms for 512×384; `.accurate` is about 50 ms. Only `.fast` fits a
/// frame comfortably, so the edge detail has to come from upsampling the mask
/// against the full-resolution image on the GPU, not from the model.
/// The mask is 1 where Vision sees a person, in the camera image's coordinates.
final class PersonMatter {
    private let request: VNGeneratePersonSegmentationRequest
    private let device: MTLDevice
    private var cache: CVMetalTextureCache?
    private var uploadTexture: MTLTexture?
    /// Milliseconds Vision took for the last frame.
    private(set) var lastMilliseconds: Double = 0

    init(device: MTLDevice) {
        self.device = device
        request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    }

    /// The person mask for `frame`, or nil when Vision had nothing to say.
    /// `keepAlive` must outlive the GPU work that samples the texture.
    func mask(for frame: CVPixelBuffer) -> (texture: MTLTexture, keepAlive: Any)? {
        let start = CACurrentMediaTime()
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first else { return nil }
        lastMilliseconds = (CACurrentMediaTime() - start) * 1000
        let mask = observation.pixelBuffer
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)

        // Zero copy when the buffer is IOSurface-backed, which Vision's usually are.
        if let cache, CVPixelBufferGetIOSurface(mask) != nil {
            var cv: CVMetalTexture?
            if CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, mask, nil, .r8Unorm, w, h, 0, &cv) == kCVReturnSuccess,
               let cv, let tex = CVMetalTextureGetTexture(cv) {
                return (tex, cv)
            }
        }
        // Otherwise a small upload: the mask is a few hundred pixels across.
        if uploadTexture == nil || uploadTexture!.width != w || uploadTexture!.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
            d.storageMode = .shared
            d.usage = [.shaderRead]
            uploadTexture = device.makeTexture(descriptor: d)
        }
        guard let tex = uploadTexture else { return nil }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base, bytesPerRow: CVPixelBufferGetBytesPerRow(mask))
        return (tex, mask)
    }
}
