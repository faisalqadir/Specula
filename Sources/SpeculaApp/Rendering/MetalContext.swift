import Foundation
import Metal
import MetalKit
import simd
import DICOMCore

struct RenderUniforms {
    var transform = matrix_identity_float4x4
    var planeToVolume = matrix_identity_float4x4
    var slabStep = SIMD4<Float>(0, 0, 0, 0)
    var imageSize = SIMD2<Float>(1, 1)
    var valueScale: Float = 1
    var valueOffset: Float = 0
    var slope: Float = 1
    var intercept: Float = 0
    var windowCenter: Float = 0.5
    var windowWidth: Float = 1
    var voiFunction: Int32 = 0
    var invert: Int32 = 0
    var isColor: Int32 = 0
    var colorWindowing: Int32 = 0
    var useColormap: Int32 = 0
    var filter: Int32 = 0
    var slabSamples: Int32 = 1
    var slabMode: Int32 = 0
    var opacity: Float = 1
    var nearest: Int32 = 0
    var colormapThreshold: Float = 0
    var subtract: Int32 = 0
    var maskShift = SIMD2<Float>(0, 0)
    var maskScale: Float = 1
    var maskOffset: Float = 0
}

struct VRUniforms {
    var invViewProj = matrix_identity_float4x4
    var objectToTex = matrix_identity_float4x4
    var cameraPos = SIMD4<Float>(0, 0, 0, 1)
    var lightDir = SIMD4<Float>(0, 0, 1, 0)
    var extent = SIMD4<Float>(1, 1, 1, 0)
    var clipMin = SIMD4<Float>(0, 0, 0, 0)
    var clipMax = SIMD4<Float>(1, 1, 1, 0)
    var gradStep = SIMD4<Float>(0.002, 0.002, 0.002, 0)
    var stepMM: Float = 0.5
    var tfMin: Float = -1000
    var tfMax: Float = 3000
    var mode: Int32 = 0
    var valueScale: Float = 1
    var valueOffset: Float = 0
    var slope: Float = 1
    var intercept: Float = 0
    var windowCenter: Float = 300
    var windowWidth: Float = 1500
    var shading: Int32 = 1
    var ambient: Float = 0.3
    var diffuse: Float = 0.7
    var specular: Float = 0.25
    var shininess: Float = 24
    var useMask: Int32 = 0
    var invert: Int32 = 0
    var orthographic: Int32 = 0
    var opacityScale: Float = 1
    var pad0: Float = 0
}

struct CutUniforms {
    var texToClip = matrix_identity_float4x4
    var dims = SIMD3<UInt32>(1, 1, 1)
    var pointCount: Int32 = 0
    var inside: Int32 = 1
}

/// Texture holding one decoded frame plus the mapping from normalised texels to stored values.
final class FrameTexture {
    let texture: MTLTexture
    let valueScale: Float
    let valueOffset: Float
    let isColor: Bool
    let width: Int
    let height: Int

    init(texture: MTLTexture, valueScale: Float, valueOffset: Float, isColor: Bool) {
        self.texture = texture
        self.valueScale = valueScale
        self.valueOffset = valueOffset
        self.isColor = isColor
        width = texture.width
        height = texture.height
    }
}

final class MetalContext {
    static let shared = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let imagePipeline: MTLRenderPipelineState
    let mprPipeline: MTLRenderPipelineState
    let vrPipeline: MTLRenderPipelineState
    let scalpelPipeline: MTLComputePipelineState
    let pixelFormat: MTLPixelFormat = .bgra8Unorm
    private(set) var colormaps: [Colormap: MTLTexture] = [:]
    let dummy2D: MTLTexture
    let dummy3D: MTLTexture
    let floatFiltering: Bool

    private var textureCache: [ImageRef: (FrameTexture, UInt64)] = [:]
    private var textureBytes = 0
    private var tick: UInt64 = 0
    private let lock = NSLock()

    private init() {
        guard let d = MTLCreateSystemDefaultDevice() else { fatalError("Metal is not available on this Mac") }
        device = d
        queue = d.makeCommandQueue()!
        floatFiltering = d.supports32BitFloatFiltering
        let lib: MTLLibrary
        do {
            lib = try d.makeLibrary(source: shaderSource, options: nil)
        } catch {
            fatalError("Shader compilation failed: \(error)")
        }
        library = lib
        func pipeline(_ v: String, _ f: String) -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: v)
            desc.fragmentFunction = lib.makeFunction(name: f)
            let att = desc.colorAttachments[0]!
            att.pixelFormat = .bgra8Unorm
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .sourceAlpha
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try! d.makeRenderPipelineState(descriptor: desc)
        }
        imagePipeline = pipeline("quadVertex", "imageFragment")
        mprPipeline = pipeline("quadVertex", "mprFragment")
        let vrDesc = MTLRenderPipelineDescriptor()
        vrDesc.vertexFunction = library.makeFunction(name: "vrVertex")
        vrDesc.fragmentFunction = library.makeFunction(name: "vrFragment")
        vrDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        vrDesc.colorAttachments[0].isBlendingEnabled = true
        vrDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        vrDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        vrDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        vrDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        vrPipeline = try! d.makeRenderPipelineState(descriptor: vrDesc)
        scalpelPipeline = try! d.makeComputePipelineState(function: library.makeFunction(name: "scalpelKernel")!)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: 1, height: 1, mipmapped: false)
        dummy2D = d.makeTexture(descriptor: td)!
        let t3 = MTLTextureDescriptor()
        t3.textureType = .type3D; t3.pixelFormat = .r8Unorm; t3.width = 1; t3.height = 1; t3.depth = 1
        dummy3D = d.makeTexture(descriptor: t3)!
        var one: UInt8 = 255
        dummy3D.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0, withBytes: &one, bytesPerRow: 1, bytesPerImage: 1)
        for c in Colormap.allCases { colormaps[c] = makeColormapTexture(c.table) }
    }

    func makeColormapTexture(_ table: [SIMD4<UInt8>]) -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = .type1D
        d.pixelFormat = .rgba8Unorm
        d.width = table.count
        let t = device.makeTexture(descriptor: d)!
        table.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake1D(0, table.count), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: table.count * 4)
        }
        return t
    }

    func makeTransferFunctionTexture(_ table: [SIMD4<Float>]) -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = .type1D
        d.pixelFormat = .rgba32Float
        d.width = table.count
        let t = device.makeTexture(descriptor: d)!
        table.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake1D(0, table.count), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: table.count * 16)
        }
        return t
    }

    /// Creates (or returns cached) GPU texture for a frame.
    func texture(for ref: ImageRef, frame: PixelFrame) -> FrameTexture {
        lock.lock()
        if let (t, _) = textureCache[ref] {
            tick += 1
            textureCache[ref] = (t, tick)
            lock.unlock()
            return t
        }
        lock.unlock()
        let t = makeTexture(frame)
        lock.lock()
        tick += 1
        textureCache[ref] = (t, tick)
        textureBytes += frame.pixels.count
        if textureBytes > 768 << 20 {
            let sorted = textureCache.sorted { $0.value.1 < $1.value.1 }
            for (k, v) in sorted {
                if textureBytes < 512 << 20 { break }
                textureCache.removeValue(forKey: k)
                textureBytes -= v.0.width * v.0.height * (v.0.isColor ? 4 : 2)
            }
        }
        lock.unlock()
        return t
    }

    func makeTexture(_ f: PixelFrame) -> FrameTexture {
        var format: MTLPixelFormat
        var scale: Float = 1, offset: Float = 0
        var bytes = f.pixels
        var bpp = f.bytesPerPixel
        switch f.format {
        case .gray8: format = .r8Unorm; scale = 255
        case .gray16: format = .r16Unorm; scale = 65535
        case .gray16Signed: format = .r16Snorm; scale = 32767
        case .float32:
            if floatFiltering { format = .r32Float } else {
                // Convert to half floats
                format = .r16Float
                var h = Data(count: f.width * f.height * 2)
                f.pixels.withUnsafeBytes { src in
                    h.withUnsafeMutableBytes { dst in
                        let s = src.bindMemory(to: Float.self), d = dst.bindMemory(to: Float16.self)
                        for i in 0..<(f.width * f.height) { d[i] = Float16(s[i]) }
                    }
                }
                bytes = h; bpp = 2
            }
        case .rgba8: format = .rgba8Unorm
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: f.width, height: f.height, mipmapped: false)
        td.usage = [.shaderRead]
        td.storageMode = .shared
        let tex = device.makeTexture(descriptor: td)!
        bytes.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, f.width, f.height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: f.width * bpp)
        }
        _ = offset
        return FrameTexture(texture: tex, valueScale: scale, valueOffset: 0, isColor: f.format == .rgba8)
    }

    func purgeTextures() {
        lock.lock(); textureCache.removeAll(); textureBytes = 0; lock.unlock()
    }
}

/// Pseudo-colour lookup tables.
enum Colormap: String, CaseIterable, Identifiable {
    case gray, hotIron, rainbow, jet, pet, hotMetal, cool, bone, spectral, viridis
    var id: String { rawValue }

    var title: String {
        switch self {
        case .gray: return "Grayscale"
        case .hotIron: return "Hot Iron"
        case .rainbow: return "Rainbow"
        case .jet: return "Jet"
        case .pet: return "PET"
        case .hotMetal: return "Hot Metal Blue"
        case .cool: return "Cool"
        case .bone: return "Bone"
        case .spectral: return "Spectral"
        case .viridis: return "Viridis"
        }
    }

    var table: [SIMD4<UInt8>] {
        (0..<256).map { i in
            let t = Double(i) / 255
            let (r, g, b) = rgb(t)
            return SIMD4<UInt8>(UInt8(max(0, min(255, r * 255))), UInt8(max(0, min(255, g * 255))), UInt8(max(0, min(255, b * 255))), 255)
        }
    }

    func rgb(_ t: Double) -> (Double, Double, Double) {
        func clamp(_ v: Double) -> Double { max(0, min(1, v)) }
        switch self {
        case .gray: return (t, t, t)
        case .hotIron:
            return (clamp(t * 2), clamp(t * 2 - 0.5), clamp(t * 4 - 3))
        case .hotMetal:
            return (clamp(t * 1.6 - 0.2), clamp(t * 2 - 0.7), clamp(t < 0.3 ? t * 2 : t * 3 - 2))
        case .rainbow:
            let h = (1 - t) * 0.75
            return hsv(h, 1, t < 0.02 ? 0 : 1)
        case .jet:
            return (clamp(1.5 - abs(4 * t - 3)), clamp(1.5 - abs(4 * t - 2)), clamp(1.5 - abs(4 * t - 1)))
        case .pet:
            if t < 0.25 { return (0, t * 2, t * 4) }
            if t < 0.5 { return ((t - 0.25) * 4, 0.5 + (t - 0.25) * 2, 1 - (t - 0.25) * 4) }
            if t < 0.75 { return (1, 1 - (t - 0.5) * 2, 0) }
            return (1, 0.5 + (t - 0.75) * 2, (t - 0.75) * 4)
        case .cool: return (t, 1 - t, 1)
        case .bone:
            return (clamp(t * 0.875 + (t > 0.75 ? (t - 0.75) * 0.5 : 0)), clamp(t * 0.875 + (t > 0.375 && t < 0.75 ? (t - 0.375) * 0.33 : (t >= 0.75 ? 0.125 : 0))), clamp(t * 0.875 + (t < 0.375 ? t * 0.33 : 0.125)))
        case .spectral:
            return hsv(0.7 - 0.7 * t, 0.85, 0.2 + 0.8 * t)
        case .viridis:
            let r = 0.267 + t * (0.004 + t * (1.67 - t * 0.95))
            let g = 0.005 + t * (1.4 - t * 0.5)
            let b = 0.33 + t * (1.2 - t * 1.4)
            return (clamp(r), clamp(g), clamp(b))
        }
    }

    func hsv(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
