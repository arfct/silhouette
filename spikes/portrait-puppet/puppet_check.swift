// Offline check of FacePuppet: drive a portrait with edited copies of its own
// landmarks (neutral, mouth open, eyes shut, head roll, head shift) and save
// each warped frame as a PNG. Build:
//   swiftc -O -parse-as-library spikes/portrait-puppet/puppet_check.swift App/FacePuppet.swift App/FaceTracker.swift Shared/VirtualCameraConstants.swift -o puppet_check
import AppKit
import Metal
import MetalKit
import Vision
import simd

@main struct PuppetCheck {
    static func main() throws {
        let args = CommandLine.arguments
        let url = URL(fileURLWithPath: args[1]), outDir = URL(fileURLWithPath: args[2]), shaders = try String(contentsOfFile: args[3], encoding: .utf8)
        let device = MTLCreateSystemDefaultDevice()!
        let library = try device.makeLibrary(source: shaders, options: nil)
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let tex = try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: false, .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)])
        let puppet = FacePuppet(device: device, library: library)
        puppet.enabled = true
        puppet.analyze(image, texture: tex)
        print("face found:", puppet.hasFace)

        // The image's landmarks as a camera face in output coordinates, same scale on both axes.
        let req = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image).perform([req])
        guard let lm = req.results?.first?.landmarks else { print("no landmarks"); return }
        let W = Float(image.width), H = Float(image.height)
        func toOut(_ p: CGPoint) -> SIMD2<Float> {
            let px = SIMD2(Float(p.x) * W, (1 - Float(p.y)) * H) / H * 1080   // uniform scale to output pixels
            return px / SIMD2(1920, 1080)
        }
        let map: [String: VNFaceLandmarkRegion2D?] = [
            "faceContour": lm.faceContour, "leftEyebrow": lm.leftEyebrow, "rightEyebrow": lm.rightEyebrow,
            "noseCrest": lm.noseCrest, "nose": lm.nose, "leftEye": lm.leftEye, "rightEye": lm.rightEye,
            "outerLips": lm.outerLips, "innerLips": lm.innerLips, "medianLine": lm.medianLine]
        var base: [String: [SIMD2<Float>]] = [:]
        for (k, r) in map { if let r { base[k] = r.pointsInImage(imageSize: CGSize(width: 1, height: 1)).map(toOut) } }
        func mean(_ a: [SIMD2<Float>]) -> SIMD2<Float> { a.reduce(.zero, +) / Float(a.count) }
        let eyeDist = simd_length(mean(base["rightEye"]!) - mean(base["leftEye"]!))

        func state(_ pts: [String: [SIMD2<Float>]]) -> FaceState {
            var s = FaceState(t: 0, detected: true)
            s.contours = pts.mapValues { $0.map { FacePoint(x: $0.x, y: $0.y) } }
            return s
        }
        func edit(_ f: (String, SIMD2<Float>) -> SIMD2<Float>) -> [String: [SIMD2<Float>]] {
            var o = base; for (k, v) in base { o[k] = v.map { f(k, $0) } }; return o
        }
        let mouthC = mean(base["outerLips"]!), eyeC = (mean(base["leftEye"]!) + mean(base["rightEye"]!)) / 2
        // Output y is 1080/1920 of x in these units; eyeDist is in output uv x terms.
        let open = edit { k, p in (k == "innerLips" || k == "outerLips" || k == "faceContour") && p.y > mouthC.y ? p + SIMD2(0, eyeDist * 0.25 * 1920 / 1080) : p }
        let shut = edit { k, p in
            guard k == "leftEye" || k == "rightEye" else { return p }
            let c = mean(base[k]!); return SIMD2(p.x, c.y + (p.y - c.y) * 0.1)
        }
        let a: Float = 12 * .pi / 180
        let roll = edit { _, p in
            var d = (p - eyeC) * SIMD2(1920, 1080)
            d = SIMD2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a))
            return eyeC + d / SIMD2(1920, 1080)
        }
        let shift = edit { _, p in p + SIMD2(eyeDist * 0.4, 0) }

        let queue = device.makeCommandQueue()!
        for (name, pts) in [("0-neutral", base), ("1-mouth-open", open), ("2-eyes-shut", shut), ("3-roll", roll), ("4-shift", shift)] {
            puppet.driveNow(state(base))                    // neutral pose first
            let t0 = Date()
            for _ in 0..<12 { puppet.driveNow(state(pts)) } // settle the easing
            print(name, String(format: "solve %.2f ms per update", Date().timeIntervalSince(t0) * 1000 / 12))
            let cmd = queue.makeCommandBuffer()!
            let warped = puppet.encode(cmd, source: tex)!
            // Copy to a readable texture.
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: warped.pixelFormat, width: warped.width, height: warped.height, mipmapped: false)
            d.storageMode = .shared
            let read = device.makeTexture(descriptor: d)!
            let blit = cmd.makeBlitCommandEncoder()!; blit.copy(from: warped, to: read); blit.endEncoding()
            cmd.commit(); cmd.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: read.width * read.height * 4)
            read.getBytes(&bytes, bytesPerRow: read.width * 4, from: MTLRegionMake2D(0, 0, read.width, read.height), mipmapLevel: 0)
            let bgra = warped.pixelFormat == .bgra8Unorm || warped.pixelFormat == .bgra8Unorm_srgb
            let info: UInt32 = bgra ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
            let ctx = CGContext(data: &bytes, width: read.width, height: read.height, bitsPerComponent: 8, bytesPerRow: read.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
            let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
            try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("\(name).png"))
            print("wrote", name)
        }
    }
}
