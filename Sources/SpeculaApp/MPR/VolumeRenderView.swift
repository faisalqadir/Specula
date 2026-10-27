import AppKit
import MetalKit
import simd
import DICOMCore

/// Transfer function preset for volume rendering (control points in modality units, e.g. HU).
struct VRPreset: Identifiable, Equatable {
    struct Point: Equatable { var value: Float; var color: SIMD3<Float>; var alpha: Float }
    var id: String { name }
    var name: String
    var points: [Point]
    var mode: Int32 = 0          // 0 composite, 1 MIP, 2 MinIP
    var invert = false
    var shading = true
    var ambient: Float = 0.25, diffuse: Float = 0.75, specular: Float = 0.3

    static func p(_ v: Float, _ r: Float, _ g: Float, _ b: Float, _ a: Float) -> Point { Point(value: v, color: SIMD3(r, g, b), alpha: a) }

    /// Preset names follow RadiAnt's list; the curves are original.
    static let all: [VRPreset] = [
        VRPreset(name: "Bones and skin 1", points: [p(-800, 0, 0, 0, 0), p(-500, 0.85, 0.55, 0.45, 0), p(-300, 0.9, 0.62, 0.5, 0.06), p(50, 0.95, 0.7, 0.6, 0.02), p(160, 0.95, 0.85, 0.75, 0), p(220, 1, 0.95, 0.85, 0.35), p(600, 1, 1, 0.95, 0.85), p(3000, 1, 1, 1, 1)]),
        VRPreset(name: "Bones and skin 2", points: [p(-700, 0, 0, 0, 0), p(-400, 0.75, 0.45, 0.35, 0.02), p(-150, 0.85, 0.55, 0.45, 0.03), p(150, 0.9, 0.6, 0.5, 0), p(200, 0.95, 0.9, 0.8, 0.25), p(500, 1, 1, 0.95, 0.75), p(3000, 1, 1, 1, 1)]),
        VRPreset(name: "Bones and skin 3", points: [p(-600, 0, 0, 0, 0), p(-350, 0.95, 0.75, 0.65, 0.01), p(100, 0.95, 0.75, 0.65, 0.01), p(180, 0.9, 0.8, 0.7, 0), p(250, 0.95, 0.9, 0.85, 0.5), p(1000, 1, 1, 1, 1)]),
        VRPreset(name: "Bones B/W", points: [p(120, 0, 0, 0, 0), p(200, 0.7, 0.7, 0.7, 0.2), p(450, 0.95, 0.95, 0.95, 0.8), p(3000, 1, 1, 1, 1)]),
        VRPreset(name: "Skin B/W", points: [p(-700, 0, 0, 0, 0), p(-450, 0.8, 0.8, 0.8, 0.2), p(-200, 0.9, 0.9, 0.9, 0.9), p(3000, 1, 1, 1, 1)]),
        VRPreset(name: "Angio", points: [p(80, 0, 0, 0, 0), p(150, 0.7, 0.1, 0.05, 0.05), p(250, 0.95, 0.35, 0.2, 0.5), p(450, 1, 0.85, 0.75, 0.85), p(3000, 1, 1, 1, 1)]),
        VRPreset(name: "Airways", points: [p(-1024, 0, 0, 0, 0), p(-990, 0, 0, 0, 0), p(-900, 0.4, 0.65, 0.95, 0.15), p(-700, 0.6, 0.8, 1, 0.3), p(-600, 0, 0, 0, 0), p(3000, 0, 0, 0, 0)]),
        VRPreset(name: "MIP B/W", points: [], mode: 1),
        VRPreset(name: "MIP B/W Inverse", points: [], mode: 1, invert: true),
        VRPreset(name: "MinIP", points: [], mode: 2),
    ]

    /// 4096-entry RGBA table over [lo, hi].
    func table(lo: Float, hi: Float, shift: Float, scale: Float) -> [SIMD4<Float>] {
        let n = 4096
        guard !points.isEmpty else { return [SIMD4<Float>](repeating: .zero, count: n) }
        return (0..<n).map { i in
            let v = lo + (hi - lo) * Float(i) / Float(n - 1)
            let x = (v - shift) / max(scale, 0.05)   // inverse of the window adjustment
            var a = points[0], b = points[points.count - 1]
            if x <= a.value { return SIMD4(a.color, a.alpha) }
            if x >= b.value { return SIMD4(b.color, b.alpha) }
            for k in 0..<(points.count - 1) where x >= points[k].value && x <= points[k + 1].value { a = points[k]; b = points[k + 1]; break }
            let t = (x - a.value) / max(1e-3, b.value - a.value)
            return SIMD4(a.color + (b.color - a.color) * t, a.alpha + (b.alpha - a.alpha) * t)
        }
    }
}

enum VRTool: String, CaseIterable { case rotate, roll, pan, zoom, window, scalpel }

/// GPU ray-cast volume rendering view.
final class VolumeRenderView: MTKView, MTKViewDelegate {
    let volume: Volume
    var preset: VRPreset = VRPreset.all[0] { didSet { rebuildTF(); setNeedsDisplay(bounds) } }
    var tfShift: Float = 0
    var tfScale: Float = 1
    var mipCenter: Float = 300
    var mipWidth: Float = 1500
    var tool: VRTool = .rotate
    var orientation = simd_quatf(angle: 0, axis: SIMD3(1, 0, 0))
    var zoom: Float = 1
    var pan = SIMD2<Float>(0, 0)
    var clipMin = SIMD3<Float>(0, 0, 0)
    var clipMax = SIMD3<Float>(1, 1, 1)
    var shading = true { didSet { setNeedsDisplay(bounds) } }
    var quality = Preferences.shared.vrQuality
    var cutInside = true
    var onChange: (() -> Void)?

    private var tfTexture: MTLTexture!
    private(set) var mask: MTLTexture?
    private var maskHistory: [[UInt8]] = []
    private var maskRedo: [[UInt8]] = []
    private var interactive = false
    private var idleTimer: Timer?
    private var lastPoint = CGPoint.zero
    private var lasso: [CGPoint] = []
    private let lassoLayer = CAShapeLayer()

    init(volume: Volume) {
        self.volume = volume
        super.init(frame: .zero, device: MetalContext.shared.device)
        colorPixelFormat = MetalContext.shared.pixelFormat
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        enableSetNeedsDisplay = true
        isPaused = true
        framebufferOnly = false
        delegate = self
        resetView(.anterior)
        if volume.modality != "CT" {
            // Non-CT volumes: derive a generic ramp from the data range
            let lo = Float(volume.minValue), hi = Float(volume.maxValue)
            let r = max(1, hi - lo)
            preset = VRPreset(name: "Generic", points: [VRPreset.p(lo + r * 0.15, 0, 0, 0, 0), VRPreset.p(lo + r * 0.4, 0.9, 0.75, 0.6, 0.3), VRPreset.p(hi, 1, 1, 1, 1)])
            mipCenter = (lo + hi) / 2; mipWidth = r
        }
        rebuildTF()
        wantsLayer = true
        lassoLayer.strokeColor = NSColor.systemYellow.cgColor
        lassoLayer.fillColor = NSColor.systemYellow.withAlphaComponent(0.15).cgColor
        lassoLayer.lineWidth = 1.5
        layer?.addSublayer(lassoLayer)
    }

    required init(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    enum ViewDirection { case anterior, posterior, left, right, superior, inferior }

    /// Camera presets (radiological convention: anterior view shows the patient's right on screen left).
    func resetView(_ d: ViewDirection) {
        // Rotation taking patient axes into view axes (x right, y up, z toward viewer)
        var m: simd_float3x3
        switch d {
        case .anterior: m = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, -1, 0)])
        case .posterior: m = simd_float3x3(rows: [SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)])
        case .left: m = simd_float3x3(rows: [SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)])
        case .right: m = simd_float3x3(rows: [SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(-1, 0, 0)])
        case .superior: m = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1)])
        case .inferior: m = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1)])
        }
        orientation = simd_quatf(m)
        setNeedsDisplay(bounds)
        onChange?()
    }

    func fitVolume() { zoom = 1; pan = .zero; setNeedsDisplay(bounds) }

    func rebuildTF() {
        tfTexture = MetalContext.shared.makeTransferFunctionTexture(preset.table(lo: -1024, hi: 3072, shift: tfShift, scale: tfScale))
        if !preset.points.isEmpty { shading = preset.shading }
    }

    // MARK: - Geometry

    /// Object space: voxel axes scaled to mm, centred at the origin.
    private var halfExtent: SIMD3<Float> { SIMD3(Float(volume.extentMM.x), Float(volume.extentMM.y), Float(volume.extentMM.z)) * 0.5 }

    private var orthoSlice: Vec3 {
        let n = volume.rowDir.cross(volume.colDir).normalized
        return volume.sliceDir.dot(n) < 0 ? n * -1 : n
    }

    private func viewMatrix() -> simd_float4x4 {
        let r = simd_float3x3(orientation) * simd_float3x3(columns: (SIMD3<Float>(volume.rowDir), SIMD3<Float>(volume.colDir), SIMD3<Float>(orthoSlice)))
        var m = matrix_identity_float4x4
        m[0] = SIMD4(r[0], 0); m[1] = SIMD4(r[1], 0); m[2] = SIMD4(r[2], 0)
        m[3] = SIMD4(pan.x, pan.y, 0, 1)
        return m
    }

    private func projection() -> simd_float4x4 {
        let radius = simd_length(halfExtent) * 1.05
        let aspect = Float(max(1, bounds.width) / max(1, bounds.height))
        var hw = radius / zoom, hh = radius / zoom
        if aspect > 1 { hw *= aspect } else { hh /= aspect }
        var p = matrix_identity_float4x4
        p[0][0] = 1 / hw
        p[1][1] = 1 / hh
        p[2][2] = -1 / (2 * radius)
        p[3][2] = 0.5
        return p
    }

    private var objectToTex: simd_float4x4 {
        let e = halfExtent * 2
        var m = matrix_identity_float4x4
        m[0][0] = 1 / e.x; m[1][1] = 1 / e.y; m[2][2] = 1 / e.z
        m[3] = SIMD4(0.5, 0.5, 0.5, 1)
        return m
    }

    // MARK: - Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let ctx = MetalContext.shared
        guard let drawable = currentDrawable, let rpd = currentRenderPassDescriptor, let cb = ctx.queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var u = VRUniforms()
        let viewProj = projection() * viewMatrix()
        u.invViewProj = viewProj.inverse
        u.objectToTex = objectToTex
        u.extent = SIMD4(halfExtent, 0)
        u.clipMin = SIMD4(clipMin, 0)
        u.clipMax = SIMD4(clipMax, 0)
        let minSpacing = Float(min(volume.spacing.x, volume.spacing.y, volume.spacing.z))
        let qualityFactor: Float = [1.0, 0.6, 0.35][max(0, min(2, quality))]
        u.stepMM = minSpacing * (interactive ? max(qualityFactor * 2.2, 0.9) : qualityFactor)
        u.gradStep = SIMD4(1 / Float(volume.width), 1 / Float(volume.height), 1 / Float(volume.depth), 0)
        u.valueScale = volume.valueScale
        u.tfMin = -1024; u.tfMax = 3072
        u.mode = preset.mode
        u.invert = preset.invert ? 1 : 0
        u.windowCenter = mipCenter; u.windowWidth = mipWidth
        u.shading = shading ? 1 : 0
        u.ambient = preset.ambient; u.diffuse = preset.diffuse; u.specular = preset.specular
        // headlight: light from the viewer in object space
        let inv = viewMatrix().inverse
        let l = inv * SIMD4<Float>(0.3, 0.4, 1, 0)
        u.lightDir = SIMD4(simd_normalize(SIMD3(l.x, l.y, l.z)), 0)
        u.useMask = mask != nil ? 1 : 0
        enc.setRenderPipelineState(ctx.vrPipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<VRUniforms>.stride, index: 0)
        enc.setFragmentTexture(volume.texture, index: 0)
        enc.setFragmentTexture(tfTexture, index: 1)
        enc.setFragmentTexture(mask ?? ctx.dummy3D, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    private func beginInteraction() {
        interactive = true
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.interactive = false
            self?.setNeedsDisplay(self?.bounds ?? .zero)
        }
    }

    // MARK: - Interaction

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        lastPoint = convert(e.locationInWindow, from: nil)
        if tool == .scalpel { lasso = [lastPoint]; updateLasso() }
    }

    override func rightMouseDown(with e: NSEvent) { lastPoint = convert(e.locationInWindow, from: nil) }
    override func otherMouseDown(with e: NSEvent) { lastPoint = convert(e.locationInWindow, from: nil) }

    override func mouseDragged(with e: NSEvent) {
        var t = tool
        if e.modifierFlags.contains(.option) { t = .window } else if e.modifierFlags.contains(.shift) { t = .pan } else if e.modifierFlags.contains(.command) { t = .zoom }
        handleDrag(e, tool: t)
    }

    override func rightMouseDragged(with e: NSEvent) { handleDrag(e, tool: .zoom) }
    override func otherMouseDragged(with e: NSEvent) { handleDrag(e, tool: .pan) }

    private func handleDrag(_ e: NSEvent, tool t: VRTool) {
        let p = convert(e.locationInWindow, from: nil)
        let dx = Float(p.x - lastPoint.x), dy = Float(p.y - lastPoint.y)
        lastPoint = p
        beginInteraction()
        switch t {
        case .rotate:
            let axis = SIMD3<Float>(dy, dx, 0)
            let ang = simd_length(axis) * 0.01
            if ang > 0 { orientation = simd_quatf(angle: ang, axis: simd_normalize(axis)) * orientation }
        case .roll:
            orientation = simd_quatf(angle: dx * 0.01, axis: SIMD3(0, 0, -1)) * orientation
        case .pan:
            let radius = simd_length(halfExtent) * 1.05 / zoom
            let s = 2 * radius / Float(max(1, min(bounds.width, bounds.height)))
            pan += SIMD2(dx * s, -dy * s)
        case .zoom:
            zoom = max(0.2, min(20, zoom * exp(-dy * 0.01)))
        case .window:
            if preset.mode == 0 {
                tfShift += dy * 2
                tfScale = max(0.2, tfScale * exp(dx * 0.005))
                rebuildTF()
            } else {
                mipCenter += dy * 4; mipWidth = max(1, mipWidth + dx * 6)
            }
        case .scalpel:
            if tool == .scalpel { lasso.append(p); updateLasso() }
        }
        setNeedsDisplay(bounds)
        onChange?()
    }

    override func mouseUp(with e: NSEvent) {
        if tool == .scalpel, lasso.count > 2 {
            applyCut(lasso)
        }
        lasso = []
        updateLasso()
    }

    override func scrollWheel(with e: NSEvent) {
        beginInteraction()
        let d = Float(e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8)
        zoom = max(0.2, min(20, zoom * exp(d * 0.01)))
        setNeedsDisplay(bounds)
    }

    override func magnify(with e: NSEvent) {
        beginInteraction()
        zoom = max(0.2, min(20, zoom * (1 + Float(e.magnification))))
        setNeedsDisplay(bounds)
    }

    override func rotate(with e: NSEvent) {
        beginInteraction()
        orientation = simd_quatf(angle: Float(e.rotation) * .pi / 180, axis: SIMD3(0, 0, 1)) * orientation
        setNeedsDisplay(bounds)
    }

    private func updateLasso() {
        let path = CGMutablePath()
        if let f = lasso.first {
            path.move(to: f)
            for p in lasso.dropFirst() { path.addLine(to: p) }
            path.closeSubpath()
        }
        lassoLayer.frame = bounds
        lassoLayer.path = path
    }

    // MARK: - Scalpel

    private func ensureMask() -> MTLTexture? {
        if let m = mask { return m }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .r8Unorm
        d.width = max(1, volume.width / 2); d.height = max(1, volume.height / 2); d.depth = max(1, volume.depth / 2)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        guard let t = MetalContext.shared.device.makeTexture(descriptor: d) else { return nil }
        let bytes = [UInt8](repeating: 255, count: d.width * d.height * d.depth)
        bytes.withUnsafeBytes { t.replace(region: MTLRegionMake3D(0, 0, 0, d.width, d.height, d.depth), mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!, bytesPerRow: d.width, bytesPerImage: d.width * d.height) }
        mask = t
        return t
    }

    private func maskBytes(_ t: MTLTexture) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: t.width * t.height * t.depth)
        b.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: t.width, bytesPerImage: t.width * t.height, from: MTLRegionMake3D(0, 0, 0, t.width, t.height, t.depth), mipmapLevel: 0, slice: 0) }
        return b
    }

    private func setMaskBytes(_ b: [UInt8]) {
        guard let t = mask else { return }
        b.withUnsafeBytes { t.replace(region: MTLRegionMake3D(0, 0, 0, t.width, t.height, t.depth), mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!, bytesPerRow: t.width, bytesPerImage: t.width * t.height) }
    }

    func applyCut(_ poly: [CGPoint], inside: Bool? = nil) {
        guard let m = ensureMask() else { return }
        maskHistory.append(maskBytes(m))
        if maskHistory.count > 20 { maskHistory.removeFirst() }
        maskRedo.removeAll()
        var u = CutUniforms()
        u.texToClip = projection() * viewMatrix() * objectToTex.inverse
        u.dims = SIMD3(UInt32(m.width), UInt32(m.height), UInt32(m.depth))
        u.pointCount = Int32(poly.count)
        u.inside = (inside ?? cutInside) ? 1 : 0
        // polygon in NDC (view is flipped: y down)
        var ndc = poly.map { SIMD2<Float>(Float($0.x / bounds.width * 2 - 1), Float(1 - $0.y / bounds.height * 2)) }
        let ctx = MetalContext.shared
        guard let cb = ctx.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(ctx.scalpelPipeline)
        enc.setTexture(m, index: 0)
        enc.setBytes(&u, length: MemoryLayout<CutUniforms>.stride, index: 0)
        enc.setBytes(&ndc, length: MemoryLayout<SIMD2<Float>>.stride * ndc.count, index: 1)
        let tg = MTLSize(width: 8, height: 8, depth: 4)
        enc.dispatchThreadgroups(MTLSize(width: (m.width + 7) / 8, height: (m.height + 7) / 8, depth: (m.depth + 3) / 4), threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        setNeedsDisplay(bounds)
        onChange?()
    }

    func undoCut() {
        guard let m = mask, let prev = maskHistory.popLast() else { return }
        maskRedo.append(maskBytes(m))
        setMaskBytes(prev)
        setNeedsDisplay(bounds)
    }

    func redoCut() {
        guard let m = mask, let next = maskRedo.popLast() else { return }
        maskHistory.append(maskBytes(m))
        setMaskBytes(next)
        setNeedsDisplay(bounds)
    }

    func restoreVolume() {
        mask = nil
        maskHistory.removeAll(); maskRedo.removeAll()
        clipMin = .zero; clipMax = SIMD3(1, 1, 1)
        setNeedsDisplay(bounds)
        onChange?()
    }

    var canUndo: Bool { !maskHistory.isEmpty }
    var canRedo: Bool { !maskRedo.isEmpty }

    // MARK: - Output

    func snapshot(size: CGSize? = nil) -> NSImage? {
        let s = size ?? CGSize(width: bounds.width * (window?.backingScaleFactor ?? 2), height: bounds.height * (window?.backingScaleFactor ?? 2))
        let w = Int(s.width), h = Int(s.height)
        let ctx = MetalContext.shared
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .shared
        guard let target = ctx.device.makeTexture(descriptor: td) else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        let wasInteractive = interactive
        interactive = false
        guard let cb = ctx.queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        var u = VRUniforms()
        let saved = bounds
        let aspectFix = Float(s.width / s.height) / Float(max(1, saved.width) / max(1, saved.height))
        var proj = projection()
        proj[0][0] /= aspectFix
        u.invViewProj = (proj * viewMatrix()).inverse
        u.objectToTex = objectToTex
        u.extent = SIMD4(halfExtent, 0)
        u.clipMin = SIMD4(clipMin, 0); u.clipMax = SIMD4(clipMax, 0)
        u.stepMM = Float(min(volume.spacing.x, volume.spacing.y, volume.spacing.z)) * 0.35
        u.gradStep = SIMD4(1 / Float(volume.width), 1 / Float(volume.height), 1 / Float(volume.depth), 0)
        u.valueScale = volume.valueScale
        u.tfMin = -1024; u.tfMax = 3072
        u.mode = preset.mode; u.invert = preset.invert ? 1 : 0
        u.windowCenter = mipCenter; u.windowWidth = mipWidth
        u.shading = shading ? 1 : 0
        u.ambient = preset.ambient; u.diffuse = preset.diffuse; u.specular = preset.specular
        let l = viewMatrix().inverse * SIMD4<Float>(0.3, 0.4, 1, 0)
        u.lightDir = SIMD4(simd_normalize(SIMD3(l.x, l.y, l.z)), 0)
        u.useMask = mask != nil ? 1 : 0
        enc.setRenderPipelineState(ctx.vrPipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<VRUniforms>.stride, index: 0)
        enc.setFragmentTexture(volume.texture, index: 0)
        enc.setFragmentTexture(tfTexture, index: 1)
        enc.setFragmentTexture(mask ?? ctx.dummy3D, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        interactive = wasInteractive
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    /// Frames for a rotation movie (360° about the vertical screen axis).
    func rotationFrames(count: Int, degrees: Float, size: CGSize) -> [NSImage] {
        let start = orientation
        var frames: [NSImage] = []
        for i in 0..<count {
            let a = degrees * .pi / 180 * Float(i) / Float(count)
            orientation = simd_quatf(angle: a, axis: SIMD3(0, 1, 0)) * start
            if let img = snapshot(size: size) { frames.append(img) }
        }
        orientation = start
        setNeedsDisplay(bounds)
        return frames
    }

    /// Iso-surface threshold from the active preset (first point with noticeable opacity).
    var isoThreshold: Float {
        if let p = preset.points.first(where: { $0.alpha > 0.15 }) { return p.value * tfScale + tfShift }
        return 300
    }

    /// Writes an STL mesh of the iso-surface (marching tetrahedra on a downsampled grid, honouring cuts).
    func exportSTL(to url: URL, progress: @escaping (Double) -> Void, completion: @escaping (Bool) -> Void) {
        let v = volume
        let iso = isoThreshold
        let maskData = mask.map { maskBytes($0) }
        let maskDims = mask.map { ($0.width, $0.height, $0.depth) }
        let clipLo = clipMin, clipHi = clipMax
        DispatchQueue.global(qos: .userInitiated).async {
            let step = max(1, Int(ceil(pow(Double(v.width * v.height * v.depth) / 6e6, 1.0 / 3.0))))
            let nx = v.width / step, ny = v.height / step, nz = v.depth / step
            func sample(_ i: Int, _ j: Int, _ k: Int) -> Float {
                let x = min(v.width - 1, i * step), y = min(v.height - 1, j * step), z = min(v.depth - 1, k * step)
                let tx = (Float(x) + 0.5) / Float(v.width), ty = (Float(y) + 0.5) / Float(v.height), tz = (Float(z) + 0.5) / Float(v.depth)
                if tx < clipLo.x || ty < clipLo.y || tz < clipLo.z || tx > clipHi.x || ty > clipHi.y || tz > clipHi.z { return -3000 }
                if let md = maskData, let (mw, mh, mdp) = maskDims {
                    let mi = min(mw - 1, Int(tx * Float(mw))), mj = min(mh - 1, Int(ty * Float(mh))), mk = min(mdp - 1, Int(tz * Float(mdp)))
                    if md[(mk * mh + mj) * mw + mi] < 128 { return -3000 }
                }
                return Float(v.voxels[(z * v.height + y) * v.width + x]) * Float(v.scale)
            }
            func pos(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
                let p = v.patient(i: Double(i * step), j: Double(j * step), k: Double(k * step))
                return SIMD3(Float(p.x), Float(p.y), Float(p.z))
            }
            let tets: [[Int]] = [[0, 5, 1, 6], [0, 1, 2, 6], [0, 2, 3, 6], [0, 3, 7, 6], [0, 7, 4, 6], [0, 4, 5, 6]]
            let corner: [(Int, Int, Int)] = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0), (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]
            var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
            for k in 0..<max(0, nz - 1) {
                if k % 8 == 0 { let pr = Double(k) / Double(max(1, nz)); DispatchQueue.main.async { progress(pr) } }
                for j in 0..<max(0, ny - 1) {
                    for i in 0..<max(0, nx - 1) {
                        var val = [Float](repeating: 0, count: 8)
                        var above = 0
                        for c in 0..<8 { val[c] = sample(i + corner[c].0, j + corner[c].1, k + corner[c].2); if val[c] >= iso { above += 1 } }
                        if above == 0 || above == 8 { continue }
                        let pts = (0..<8).map { pos(i + corner[$0].0, j + corner[$0].1, k + corner[$0].2) }
                        for t in tets {
                            let inside = t.filter { val[$0] >= iso }, outside = t.filter { val[$0] < iso }
                            func edge(_ a: Int, _ b: Int) -> SIMD3<Float> {
                                let f = (iso - val[a]) / (val[b] - val[a])
                                return pts[a] + (pts[b] - pts[a]) * f
                            }
                            if inside.count == 1 || inside.count == 3 {
                                let lone = inside.count == 1 ? inside[0] : outside[0]
                                let others = inside.count == 1 ? outside : inside
                                let tri = (edge(lone, others[0]), edge(lone, others[1]), edge(lone, others[2]))
                                tris.append(inside.count == 1 ? tri : (tri.0, tri.2, tri.1))
                            } else if inside.count == 2 {
                                let a = edge(inside[0], outside[0]), b = edge(inside[0], outside[1])
                                let c = edge(inside[1], outside[0]), d = edge(inside[1], outside[1])
                                tris.append((a, b, d)); tris.append((a, d, c))
                            }
                        }
                    }
                }
            }
            var data = Data(count: 80)
            var n = UInt32(tris.count).littleEndian
            withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
            for (a, b, c) in tris {
                var nrm = simd_cross(b - a, c - a)
                let l = simd_length(nrm)
                if l > 0 { nrm /= l }
                for v3 in [nrm, a, b, c] { for comp in [v3.x, v3.y, v3.z] { var f = comp.bitPattern.littleEndian; withUnsafeBytes(of: &f) { data.append(contentsOf: $0) } } }
                data.append(contentsOf: [0, 0])
            }
            let ok = (try? data.write(to: url)) != nil
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
