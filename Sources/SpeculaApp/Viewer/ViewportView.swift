import AppKit
import MetalKit
import simd
import DICOMCore

/// One image panel: Metal image layer + annotation overlay + interaction.
final class ViewportView: NSView, MTKViewDelegate {
    let state: ViewportState
    weak var session: ViewerSession?
    let metalView: MTKView
    let overlay: OverlayView
    /// When set the panel shows a reformatted plane instead of a 2D image.
    var mpr: MPRPlane? { didSet { initMPRDisplay(); needsRedraw() } }

    private func initMPRDisplay() {
        guard let mpr, !state.display.initialized else { return }
        if mpr.volume.modality == "CT" { state.display.windowCenter = 40; state.display.windowWidth = 400; state.display.windowName = "CT Abdomen" }
        else if let r = mpr.volume.images.first, let c = r.attributes.windowCenters.first, let w = r.attributes.windowWidths.first {
            state.display.windowCenter = c; state.display.windowWidth = w
        } else {
            state.display.windowCenter = (mpr.volume.minValue + mpr.volume.maxValue) / 2
            state.display.windowWidth = max(1, mpr.volume.maxValue - mpr.volume.minValue)
        }
        state.display.initialized = true
    }
    weak var mprController: MPRController?

    private(set) var frame2D: PixelFrame?
    private(set) var frameRef: ImageRef?
    private var requested: ImageRef?
    var isActive = false { didSet { if oldValue != isActive { overlay.needsDisplay = true } } }
    var isDropTarget = false { didSet { overlay.needsDisplay = true } }

    // Interaction state (see ViewportInteraction.swift)
    var dragState: DragState?
    var draft: Measurement?
    var draftStage = 0
    var selectedMeasurement: UUID? { didSet { overlay.needsDisplay = true } }
    var hoverPoint: CGPoint? // view coordinates
    var trackingArea: NSTrackingArea?
    var scrollAccumulator: CGFloat = 0
    var magnifyAnchor: CGPoint?
    var rotationAccumulator: CGFloat = 0
    var rightDragged = false
    var lastClickTime: TimeInterval = 0
    /// Export overrides for annotation visibility.
    var overrideAnnotations: Bool?
    var overrideAnonymous: Bool?

    init(state: ViewportState, session: ViewerSession?) {
        self.state = state
        self.session = session
        metalView = MTKView(frame: .zero, device: MetalContext.shared.device)
        overlay = OverlayView(frame: .zero)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        metalView.colorPixelFormat = MetalContext.shared.pixelFormat
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = true
        metalView.framebufferOnly = false
        metalView.autoResizeDrawable = true
        metalView.delegate = self
        metalView.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.viewport = self
        addSubview(metalView)
        addSubview(overlay)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor), metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor), metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor), overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor), overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes([.speculaSeries, .fileURL])
        allowedTouchTypes = [.indirect]
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.contains(p) ? self : nil
    }

    func needsRedraw() {
        metalView.needsDisplay = true
        overlay.needsDisplay = true
    }

    // MARK: - Geometry

    /// Size and aspect of the current content in pixels.
    var contentGeometry: (size: CGSize, aspect: CGFloat)? {
        if let mpr {
            let g = mpr.grid
            return (CGSize(width: g.width, height: g.height), 1)
        }
        guard let ref = state.current else { return nil }
        let w = frame2D?.width ?? ref.instance.columns, h = frame2D?.height ?? ref.instance.rows
        guard w > 0, h > 0 else { return nil }
        var aspect: CGFloat = 1
        if let sp = ref.instance.pixelSpacing(frame: ref.frame), sp.1 > 0 { aspect = CGFloat(sp.0 / sp.1) }
        else if let ar = ref.instance.header.doubles(.pixelAspectRatio) as [Double]?, ar.count == 2, ar[1] > 0 { aspect = CGFloat(ar[0] / ar[1]) }
        if aspect < 0.05 || aspect > 20 { aspect = 1 }
        return (CGSize(width: w, height: h), aspect)
    }

    var transform: ViewTransform? {
        guard let g = contentGeometry else { return nil }
        var t = ViewTransform(imageSize: g.size, aspect: g.aspect, zoom: CGFloat(state.display.zoom), pan: state.display.pan, ortho: state.display.orientation, viewSize: bounds.size)
        switch state.display.fitMode {
        case .fit: t.zoom = t.fitZoom(); t.pan = .zero
        case .fill: t.zoom = t.fitZoom(fill: true); t.pan = .zero
        case .actual: t.zoom = 1 / (window?.backingScaleFactor ?? 2)
        case .custom: break
        }
        return t
    }

    /// Commits the computed fit zoom into the state (before the user starts zooming / panning).
    func materializeZoom() {
        guard let t = transform else { return }
        state.display.zoom = Double(t.zoom)
        state.display.pan = t.pan
        state.display.fitMode = .custom
    }

    /// Patient-space plane currently shown (2D image or MPR plane).
    var currentPlane: ImagePlane? {
        if let mpr { return mpr.imagePlane }
        return state.current?.plane
    }

    // MARK: - Frame loading

    func ensureFrame() {
        guard mpr == nil, let ref = state.current else { return }
        if frameRef == ref, frame2D != nil { return }
        if let f = FrameCache.shared.cached(ref) {
            setFrame(f, ref: ref)
            return
        }
        if requested == ref { return }
        requested = ref
        FrameCache.shared.request(ref, priority: .veryHigh) { [weak self] result in
            guard let self else { return }
            if self.requested == ref { self.requested = nil }
            switch result {
            case .success(let f):
                if self.state.current == ref { self.setFrame(f, ref: ref); self.needsRedraw() }
            case .failure(let e):
                if self.state.current == ref {
                    self.state.loadError = e.localizedDescription
                    self.frame2D = nil
                    self.frameRef = ref
                    self.needsRedraw()
                }
            }
        }
        if let s = state.series { FrameCache.shared.prefetch(s.images, around: state.index) }
    }

    /// Decodes the current frame on the calling thread (export / printing).
    func ensureFrameSynchronously() {
        guard mpr == nil, let ref = state.current else { return }
        if frameRef == ref, frame2D != nil { return }
        if let f = try? FrameCache.shared.decode(ref) { setFrame(f, ref: ref) }
    }

    func resetFrame() {
        frame2D = nil
        frameRef = nil
        requested = nil
    }

    private func setFrame(_ f: PixelFrame, ref: ImageRef) {
        frame2D = f
        frameRef = ref
        state.loadError = nil
        if !state.display.initialized {
            let (c, w, name) = state.defaultWindow(for: ref, frame: f)
            state.display.windowCenter = c
            state.display.windowWidth = w
            state.display.windowName = name
            state.display.initialized = true
            state.display.interpolate = Preferences.shared.interpolate
            if Preferences.shared.cineAutoRun, (ref.instance.modality == "US" || ref.instance.modality == "XA"), state.imageCount > 1, ref.instance.isMultiFrame {
                session?.setCine(state, playing: true)
            }
            session?.viewportDisplayInitialized(state)
        }
        overlay.needsDisplay = true
    }

    // MARK: - Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { overlay.needsDisplay = true }

    func draw(in view: MTKView) {
        ensureFrame()
        let ctx = MetalContext.shared
        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let cb = ctx.queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        defer {
            enc.endEncoding()
            cb.present(drawable)
            cb.commit()
        }
        guard let t = transform else { return }
        if let mpr {
            drawMPR(enc, mpr: mpr, t: t)
            return
        }
        renderImage(enc, t: t)
    }

    private func drawFusion(_ enc: MTLRenderCommandEncoder, fusion: FusionLayer, plane: ImagePlane, t: ViewTransform, size: CGSize) {
        let ctx = MetalContext.shared
        var u = RenderUniforms()
        u.transform = t.ndcMatrix
        u.imageSize = SIMD2(Float(size.width), Float(size.height))
        let su = plane.rowDirection * plane.columnSpacing, sv = plane.columnDirection * plane.rowSpacing
        var p = matrix_identity_float4x4
        p[0] = SIMD4(Float(su.x), Float(su.y), Float(su.z), 0)
        p[1] = SIMD4(Float(sv.x), Float(sv.y), Float(sv.z), 0)
        p[2] = SIMD4(0, 0, 0, 0)
        p[3] = SIMD4(Float(plane.position.x), Float(plane.position.y), Float(plane.position.z), 1)
        u.planeToVolume = fusion.volume.patientToTex * p
        u.slabSamples = 1
        u.valueScale = fusion.volume.valueScale
        u.windowCenter = Float(fusion.windowCenter)
        u.windowWidth = Float(fusion.windowWidth)
        u.useColormap = 1
        u.opacity = Float(fusion.opacity)
        u.colormapThreshold = Float(fusion.threshold)
        enc.setRenderPipelineState(ctx.mprPipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        enc.setFragmentTexture(fusion.volume.texture, index: 0)
        enc.setFragmentTexture(ctx.colormaps[fusion.colormap], index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func drawMPR(_ enc: MTLRenderCommandEncoder, mpr: MPRPlane, t: ViewTransform) {
        let ctx = MetalContext.shared
        let g = mpr.grid
        var u = RenderUniforms()
        u.transform = t.ndcMatrix
        u.imageSize = SIMD2(Float(g.width), Float(g.height))
        u.planeToVolume = mpr.planeToTexture()
        let (n, step) = mpr.slab()
        u.slabSamples = n
        u.slabStep = step
        u.slabMode = Int32(n > 1 ? (mpr.mode == .mpr ? SlabMode.average.rawValue : mpr.mode.rawValue) : 0)
        u.valueScale = mpr.volume.valueScale
        u.windowCenter = Float(state.display.windowCenter)
        u.windowWidth = Float(state.display.windowWidth)
        u.invert = state.display.negative ? 1 : 0
        u.nearest = state.display.interpolate ? 0 : 1
        u.useColormap = state.display.colormap != .gray ? 1 : 0
        if !state.display.initialized {
            if mpr.volume.modality == "CT" { state.display.windowCenter = 40; state.display.windowWidth = 400 }
            else if let r = mpr.volume.images.first, let c = r.attributes.windowCenters.first, let w = r.attributes.windowWidths.first {
                state.display.windowCenter = c; state.display.windowWidth = w
            } else {
                state.display.windowCenter = (mpr.volume.minValue + mpr.volume.maxValue) / 2
                state.display.windowWidth = max(1, mpr.volume.maxValue - mpr.volume.minValue)
            }
            state.display.initialized = true
            u.windowCenter = Float(state.display.windowCenter); u.windowWidth = Float(state.display.windowWidth)
        }
        enc.setRenderPipelineState(ctx.mprPipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        enc.setFragmentTexture(mpr.volume.texture, index: 0)
        enc.setFragmentTexture(ctx.colormaps[state.display.colormap], index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - Snapshot

    /// Renders the panel (image + overlay) into a bitmap.
    func snapshot(scale: CGFloat? = nil, includeOverlay: Bool = true) -> NSImage? {
        let s = scale ?? (window?.backingScaleFactor ?? 2)
        let w = Int(bounds.width * s), h = Int(bounds.height * s)
        guard w > 0, h > 0 else { return nil }
        let ctx = MetalContext.shared
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let target = ctx.device.makeTexture(descriptor: td) else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        guard let cb = ctx.queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd), let t = transform else { return nil }
        if let mpr { drawMPR(enc, mpr: mpr, t: t) } else { renderImage(enc, t: t) }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let image = NSImage(size: bounds.size)
        image.addRepresentation(NSBitmapImageRep(cgImage: cg))
        if includeOverlay {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSImage(cgImage: cg, size: bounds.size).draw(in: NSRect(origin: .zero, size: bounds.size))
            let flipped = NSGraphicsContext.current!.cgContext
            flipped.translateBy(x: 0, y: bounds.height)
            flipped.scaleBy(x: 1, y: -1)
            overlay.drawContents(in: bounds, forExport: true)
            NSGraphicsContext.restoreGraphicsState()
            let out = NSImage(size: bounds.size)
            out.addRepresentation(rep)
            return out
        }
        return image
    }

    private func renderImage(_ enc: MTLRenderCommandEncoder, t: ViewTransform) {
        guard let ref = frameRef, let frame = frame2D else { return }
        let ctx = MetalContext.shared
        let tex = ctx.texture(for: ref, frame: frame)
        var u = RenderUniforms()
        u.transform = t.ndcMatrix
        u.imageSize = SIMD2(Float(frame.width), Float(frame.height))
        u.valueScale = tex.valueScale
        let a = ref.attributes
        u.slope = Float(a.rescaleSlope); u.intercept = Float(a.rescaleIntercept)
        u.windowCenter = Float(state.display.windowCenter); u.windowWidth = Float(state.display.windowWidth)
        u.voiFunction = ref.instance.voiFunction == "SIGMOID" ? 2 : (ref.instance.voiFunction == "LINEAR_EXACT" ? 1 : 0)
        u.invert = (ref.instance.isMonochrome1 != state.display.negative) ? 1 : 0
        u.isColor = tex.isColor ? 1 : 0
        if tex.isColor {
            u.invert = state.display.negative ? 1 : 0
            u.colorWindowing = (abs(state.display.windowCenter - 127.5) > 0.01 || abs(state.display.windowWidth - 256) > 0.01) ? 1 : 0
        }
        u.filter = Int32(state.display.filter)
        u.nearest = state.display.interpolate ? 0 : 1
        u.useColormap = state.display.colormap != .gray && !tex.isColor ? 1 : 0
        var maskTex: MTLTexture = ctx.dummy2D
        if state.subtraction.enabled, let s = state.series, let maskRef = s.images[safe: state.subtraction.maskIndex],
           maskRef != ref, let mf = FrameCache.shared.cached(maskRef) ?? (try? FrameCache.shared.decode(maskRef)), !mf.isColor {
            let mt = ctx.texture(for: maskRef, frame: mf)
            maskTex = mt.texture
            u.subtract = 1
            u.maskScale = mt.valueScale
            u.maskShift = SIMD2(Float(state.subtraction.shift.x), Float(state.subtraction.shift.y))
        }
        enc.setRenderPipelineState(ctx.imagePipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        enc.setFragmentTexture(tex.texture, index: 0)
        enc.setFragmentTexture(ctx.colormaps[state.display.colormap], index: 1)
        enc.setFragmentTexture(maskTex, index: 2)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        if let fusion = state.fusion, let plane = ref.plane {
            drawFusion(enc, fusion: fusion, plane: plane, t: t, size: CGSize(width: frame.width, height: frame.height))
        }
    }

    // MARK: - Layout / tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func layout() {
        super.layout()
        needsRedraw()
    }
}

extension NSPasteboard.PasteboardType {
    static let speculaSeries = NSPasteboard.PasteboardType("com.specula.series")
}
