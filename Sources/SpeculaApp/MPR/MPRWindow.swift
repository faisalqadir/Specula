import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import DICOMCore

enum MPRMode { case mpr, vr }

protocol MPRController: AnyObject {
    func mouseDown(_ v: ViewportView, at p: CGPoint) -> Bool
    func mouseDragged(_ v: ViewportView, to p: CGPoint, delta: CGPoint)
    func mouseUp(_ v: ViewportView)
    func mouseMoved(_ v: ViewportView, at p: CGPoint)
    func scroll(_ v: ViewportView, plane: MPRPlane, steps: Int)
    func drawOverlay(_ v: ViewportView, t: ViewTransform, ctx: CGContext)
    func measurements(for v: ViewportView) -> [Measurement]
    func setMeasurements(_ list: [Measurement], for v: ViewportView)
    func describe(_ m: Measurement, plane: MPRPlane) -> [String]
}

/// Keeps three orthogonal reformats sharing one crosshair point.
final class MPRSession: ObservableObject, MPRController {
    let volume: Volume
    let session = ViewerSession()
    var views: [ViewportView] = []
    @Published var mode: SlabMode = .mpr { didSet { planes.forEach { $0.mode = mode }; redraw() } }
    @Published var thickness: Double = 0 { didSet { planes.forEach { $0.thickness = thickness }; redraw() } }
    @Published var showAxes = true { didSet { redraw() } }
    weak var parentSession: ViewerSession?
    private var drag: (kind: Int, plane: Int, start: CGPoint, startCenter: Vec3)?   // kind 0 move line, 1 rotate, 2 centre, 3 browse
    private var store: [String: [Measurement]] = [:]

    var planes: [MPRPlane] { views.compactMap(\.mpr) }

    init(volume: Volume, parent: ViewerSession?) {
        self.volume = volume
        parentSession = parent
        session.mprActive = true
        var vs: [ViewportView] = []
        for o in MPROrientation.allCases {
            let st = ViewportState()
            st.session = session
            let v = ViewportView(state: st, session: session)
            st.onChange = { [weak v] _ in v?.needsRedraw() }
            v.mpr = MPRPlane(volume: volume, orientation: o)
            v.mprController = self
            vs.append(v)
        }
        views = vs
        session.installViewports(vs)
    }

    func redraw() { views.forEach { $0.needsRedraw() } }

    var center: Vec3 {
        get { planes.first?.center ?? volume.center }
        set {
            for p in planes { p.center = newValue; p.clampCenter() }
            redraw()
            if let parent = parentSession, volume.series.frameOfReference != nil { parent.cursor3D = planes.first?.center }
        }
    }

    func resetAxes() {
        for v in views {
            guard let p = v.mpr else { continue }
            (p.u, p.v) = p.orientation.axes
            p.center = volume.center
        }
        views.forEach { $0.state.display.fitMode = .fit; $0.state.display.pan = .zero }
        redraw()
    }

    // MARK: Geometry helpers

    /// Line of another plane through this view, in view coordinates.
    private func line(of other: MPRPlane, in v: ViewportView, t: ViewTransform) -> (CGPoint, CGPoint)? {
        guard let p = v.mpr else { return nil }
        let n = other.normal
        let dir = p.normal.cross(n)
        guard dir.length > 1e-3 else { return nil }
        let c = other.center
        let g = p.imagePlane
        let a = g.pixel(of: c - dir.normalized * 2000), b = g.pixel(of: c + dir.normalized * 2000)
        return (t.toView(CGPoint(x: a.x, y: a.y)), t.toView(CGPoint(x: b.x, y: b.y)))
    }

    private func centreView(_ v: ViewportView, _ t: ViewTransform) -> CGPoint? {
        guard let p = v.mpr else { return nil }
        let c = p.imagePlane.pixel(of: p.center)
        return t.toView(CGPoint(x: c.x, y: c.y))
    }

    private func patientPoint(_ v: ViewportView, _ viewPoint: CGPoint) -> Vec3? {
        guard let t = v.transform, let p = v.mpr else { return nil }
        let ip = t.toImage(viewPoint)
        return p.imagePlane.patientPoint(x: Double(ip.x), y: Double(ip.y))
    }

    // MARK: MPRController

    func mouseDown(_ v: ViewportView, at p: CGPoint) -> Bool {
        guard let t = v.transform, let mine = v.mpr, let c = centreView(v, t) else { return false }
        if showAxes {
            if c.distance(to: p) < 10 { drag = (2, -1, p, mine.center); return true }
            for (i, other) in views.enumerated() where other !== v {
                guard let op = other.mpr, let (a, b) = line(of: op, in: v, t: t) else { continue }
                if p.distance(toSegment: a, b) < 7 {
                    let r = c.distance(to: p)
                    let reach = min(v.bounds.width, v.bounds.height) * 0.32
                    drag = (r > reach ? 1 : 0, i, p, mine.center)
                    return true
                }
            }
        }
        drag = (3, -1, p, mine.center)
        return true
    }

    func mouseDragged(_ v: ViewportView, to p: CGPoint, delta: CGPoint) {
        guard let d = drag, let mine = v.mpr, let t = v.transform else { return }
        switch d.kind {
        case 0:
            guard let other = views[d.plane].mpr, let pt = patientPoint(v, p) else { return }
            let n = other.normal
            var c = center
            c = c + n * (pt - c).dot(n)
            center = c
        case 1:
            guard let c = centreView(v, t) else { return }
            let a0 = atan2(d.start.y - c.y, d.start.x - c.x), a1 = atan2(p.y - c.y, p.x - c.x)
            let ang = Double(a1 - a0)
            drag = (1, d.plane, p, d.startCenter)
            // rotate both other planes about this view's normal (screen y is down, so negate)
            let axis = mine.normal * (t.ortho.isFlipped ? 1 : -1)
            for other in views where other !== v { other.mpr?.rotate(axis: axis, angle: ang) }
            redraw()
        case 2:
            guard let pt = patientPoint(v, p) else { return }
            let n = mine.normal
            center = pt - n * (pt - center).dot(n)
        default:
            mine.move(by: Double(delta.y) * mine.stepMM * 0.5)
            center = mine.center
        }
    }

    func mouseUp(_ v: ViewportView) { drag = nil }
    func mouseMoved(_ v: ViewportView, at p: CGPoint) {}

    func scroll(_ v: ViewportView, plane: MPRPlane, steps: Int) {
        plane.move(by: Double(steps) * plane.stepMM)
        center = plane.center
    }

    func drawOverlay(_ v: ViewportView, t: ViewTransform, ctx: CGContext) {
        guard showAxes, let c = centreView(v, t) else { return }
        for other in views where other !== v {
            guard let op = other.mpr, let (a, b) = line(of: op, in: v, t: t) else { continue }
            let (r, g, bl) = op.orientation.color
            let col = CGColor(srgbRed: r, green: g, blue: bl, alpha: 0.9)
            ctx.saveGState()
            ctx.setStrokeColor(col)
            ctx.setLineWidth(1.2)
            // gap around the centre so the anatomy at the crosshair stays visible
            let dir = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let len = max(dir.length, 1)
            let u = CGPoint(x: dir.x / len, y: dir.y / len)
            let gap: CGFloat = 14
            ctx.move(to: a); ctx.addLine(to: CGPoint(x: c.x - u.x * gap, y: c.y - u.y * gap))
            ctx.move(to: CGPoint(x: c.x + u.x * gap, y: c.y + u.y * gap)); ctx.addLine(to: b)
            ctx.strokePath()
            // slab thickness guides
            if op.thickness > 0 {
                let half = CGFloat(op.thickness / 2 / op.pixelSize) * t.zoom
                let nrm = CGPoint(x: -u.y, y: u.x)
                ctx.setLineDash(phase: 0, lengths: [3, 4])
                for s in [-1.0, 1.0] {
                    let o = CGPoint(x: nrm.x * half * CGFloat(s), y: nrm.y * half * CGFloat(s))
                    ctx.move(to: a + o); ctx.addLine(to: b + o)
                }
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }
            // rotation handles
            let reach = min(v.bounds.width, v.bounds.height) * 0.38
            ctx.setFillColor(col)
            for s in [-1.0, 1.0] {
                let h = CGPoint(x: c.x + u.x * reach * CGFloat(s), y: c.y + u.y * reach * CGFloat(s))
                ctx.fillEllipse(in: CGRect(x: h.x - 3.5, y: h.y - 3.5, width: 7, height: 7))
            }
            ctx.restoreGState()
        }
        // own orientation colour bar on the left edge
        if let p = v.mpr {
            let (r, g, b) = p.orientation.color
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 3, height: v.bounds.height))
        }
    }

    private func key(_ v: ViewportView) -> String {
        guard let p = v.mpr else { return "" }
        let s = p.sliceInfo
        return "\(p.orientation.rawValue):\(s.index):\(Int(p.u.x * 1000)),\(Int(p.u.y * 1000)),\(Int(p.u.z * 1000))"
    }

    func measurements(for v: ViewportView) -> [Measurement] { store[key(v)] ?? [] }
    func setMeasurements(_ list: [Measurement], for v: ViewportView) { store[key(v)] = list; session.measurementRevision += 1 }

    func describe(_ m: Measurement, plane: MPRPlane) -> [String] {
        let sp = (plane.pixelSize, plane.pixelSize)
        let pts = m.points
        let g = plane.imagePlane
        switch m.kind {
        case .length, .arrow:
            guard pts.count >= 2 else { return [] }
            if m.kind == .arrow { return m.text.isEmpty ? [] : [m.text] }
            return [MeasurementCalculator.formatLength(MeasurementCalculator.distance(pts[0], pts[1], spacing: sp), calibrated: false, hasSpacing: true)]
        case .angle:
            guard pts.count >= 3 else { return [] }
            return [String(format: "%.1f°", MeasurementCalculator.angle(pts[0], pts[1], pts[2], spacing: sp))]
        case .cobbAngle:
            guard pts.count >= 4 else { return [] }
            return [String(format: "%.1f°", MeasurementCalculator.lineAngle(pts[0], pts[1], pts[2], pts[3], spacing: sp))]
        case .probe:
            guard let p = pts.first, let v = volume.value(atPatient: g.patientPoint(x: Double(p.x), y: Double(p.y))) else { return [] }
            return ["\(DataSet.formatDS(v)) \(volume.units)"]
        case .text: return m.text.isEmpty ? [] : [m.text]
        case .openPolygon:
            guard pts.count >= 2 else { return [] }
            var total = 0.0
            for i in 1..<pts.count { total += MeasurementCalculator.distance(pts[i - 1], pts[i], spacing: sp) }
            return [MeasurementCalculator.formatLength(total, calibrated: false, hasSpacing: true)]
        case .deviation:
            return MeasurementCalculator.describe(m, ref: nil, frame: nil, calibration: plane.pixelSize)
        case .ellipse, .rectangle, .closedPolygon, .pencil:
            let poly = MeasurementCalculator.outline(m)
            guard poly.count >= 3 else { return [] }
            let area = MeasurementCalculator.polygonArea(poly) * sp.0 * sp.1
            var vals: [Double] = []
            let xs = poly.map(\.x), ys = poly.map(\.y)
            for y in Int(ys.min()!)...Int(ys.max()!) {
                for x in Int(xs.min()!)...Int(xs.max()!) where MeasurementCalculator.pointInPolygon(CGPoint(x: x, y: y), poly) {
                    if let v = volume.value(atPatient: g.patientPoint(x: Double(x), y: Double(y))) { vals.append(v) }
                }
            }
            var lines = [area >= 100 ? String(format: "Area: %.2f cm²", area / 100) : String(format: "Area: %.2f mm²", area)]
            if !vals.isEmpty {
                let mean = vals.reduce(0, +) / Double(vals.count)
                let sd = sqrt(vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(vals.count))
                lines.append(String(format: "Mean: %.2f %@ SD: %.2f", mean, volume.units, sd))
                lines.append("Min: \(DataSet.formatDS(vals.min()!)) Max: \(DataSet.formatDS(vals.max()!))")
            }
            return lines
        }
    }
}

/// Container laying out MPR panels (and optionally the 3D view).
final class MPRGridView: NSView {
    var panels: [NSView] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; panels.forEach { addSubview($0) }; needsLayout = true } }
    var columns = 2
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let n = panels.count
        guard n > 0 else { return }
        let cols = min(columns, n), rows = (n + cols - 1) / cols
        let w = (bounds.width - CGFloat(cols - 1)) / CGFloat(cols), h = (bounds.height - CGFloat(rows - 1)) / CGFloat(rows)
        for (i, v) in panels.enumerated() {
            v.frame = CGRect(x: CGFloat(i % cols) * (w + 1), y: CGFloat(i / cols) * (h + 1), width: w, height: h).integral
            (v as? ViewportView)?.needsRedraw()
        }
    }
}

final class MPRWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private static var open: [MPRWindowController] = []
    let mpr: MPRSession
    let mode: MPRMode
    let grid = MPRGridView()
    var vrView: VolumeRenderView?
    let vrModel: VRPanelModel
    private var bag = Set<AnyCancellable>()

    static func open(series: Series, session: ViewerSession, mode: MPRMode) {
        guard series.volumeCandidate else {
            let a = NSAlert(); a.messageText = "3D reconstruction is not available"
            a.informativeText = "This series needs at least 3 parallel slices of the same size."
            a.runModal(); return
        }
        let progress = ProgressWindow(title: "Creating MPR series…")
        progress.show()
        Volume.build(series: series, progress: { progress.value = $0 }) { result in
            progress.close()
            switch result {
            case .success(let vol):
                let wc = MPRWindowController(volume: vol, parent: session, mode: mode)
                open.append(wc)
                wc.showWindow(nil)
                if vol.irregular || vol.tilted {
                    let a = NSAlert()
                    a.messageText = vol.tilted ? "The slices in this volume are tilted." : "The slice interval is not regular."
                    a.informativeText = "The distortion in presentation and measurements may be present."
                    a.beginSheetModal(for: wc.window!)
                }
            case .failure(let e):
                let a = NSAlert(); a.messageText = "The volume could not be loaded."; a.informativeText = e.localizedDescription; a.runModal()
            }
        }
    }

    init(volume: Volume, parent: ViewerSession, mode: MPRMode) {
        mpr = MPRSession(volume: volume, parent: parent)
        self.mode = mode
        vrModel = VRPanelModel()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = mode == .mpr ? "3D MPR" : "3D Volume Rendering"
        w.subtitle = [PersonName.display(volume.series.study?.patientNameRaw), volume.series.seriesDescription].filter { !$0.isEmpty }.joined(separator: " · ")
        w.toolbarStyle = .unified
        w.tabbingMode = .preferred
        super.init(window: w)
        w.delegate = self
        let vr = VolumeRenderView(volume: volume)
        vrView = vr
        vrModel.view = vr
        vr.onChange = { [weak self] in self?.vrModel.objectWillChange.send() }

        let split = NSSplitViewController()
        let content = NSViewController()
        content.view = grid
        let mainItem = NSSplitViewItem(viewController: content)
        let panel = NSHostingController(rootView: MPRSidePanel(mpr: mpr, vr: vrModel, mode: mode))
        let side = NSSplitViewItem(inspectorWithViewController: panel)
        side.minimumThickness = 250
        side.maximumThickness = 320
        split.addSplitViewItem(mainItem)
        split.addSplitViewItem(side)
        w.contentViewController = split
        w.setContentSize(NSSize(width: 1400, height: 900))
        let tb = NSToolbar(identifier: "SpeculaMPRToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        w.toolbar = tb
        setLayout(mode == .mpr ? .threePlusThree : .vrOnly)
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { MPRWindowController.open.removeAll { $0 === self } }

    enum Layout { case threeColumns, threePlusThree, vrOnly, single(Int) }

    func setLayout(_ l: Layout) {
        guard let vr = vrView else { return }
        switch l {
        case .threeColumns: grid.columns = 3; grid.panels = mpr.views
        case .threePlusThree: grid.columns = 2; grid.panels = mpr.views + [vr]
        case .vrOnly: grid.columns = 1; grid.panels = [vr]
        case .single(let i): grid.columns = 1; grid.panels = [mpr.views[i]]
        }
        vr.setNeedsDisplay(vr.bounds)
    }

    // MARK: Toolbar

    private enum TB {
        static let tools = NSToolbarItem.Identifier("mprTools")
        static let measure = NSToolbarItem.Identifier("mprMeasure")
        static let layout = NSToolbarItem.Identifier("mprLayout")
        static let slab = NSToolbarItem.Identifier("mprSlab")
        static let reset = NSToolbarItem.Identifier("mprReset")
        static let snapshot = NSToolbarItem.Identifier("mprSnapshot")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [TB.tools, TB.measure, .space, TB.slab, .flexibleSpace, TB.layout, TB.reset, TB.snapshot, .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func img(_ n: String) -> NSImage { NSImage(systemSymbolName: n, accessibilityDescription: nil) ?? NSImage() }
        switch id {
        case TB.tools:
            let tools: [Tool] = [.browse, .window, .pan, .zoom]
            let g = NSToolbarItemGroup(itemIdentifier: id, images: tools.map { img($0.symbol) }, selectionMode: .selectOne, labels: tools.map(\.title), target: self, action: #selector(toolChanged(_:)))
            g.selectedIndex = 0
            g.label = "Tools"
            return g
        case TB.measure:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.label = "Measure"
            i.image = img("ruler")
            let m = NSMenu()
            for t in [Tool.length, .angle, .ellipse, .closedPolygon, .probe, .arrow, .text] {
                let it = NSMenuItem(title: t.title, action: #selector(measureTool(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = t.rawValue
                it.image = img(t.symbol)
                m.addItem(it)
            }
            i.menu = m
            return i
        case TB.slab:
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Slab"
            let host = NSHostingView(rootView: SlabControl(mpr: mpr))
            host.frame = NSRect(x: 0, y: 0, width: 330, height: 28)
            i.view = host
            return i
        case TB.layout:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.label = "Layout"
            i.image = img("square.grid.2x2")
            let m = NSMenu()
            for (title, tag) in [("Axial, Coronal, Sagittal + 3D", 0), ("Three Columns", 1), ("3D Only", 2), ("Axial Only", 3), ("Coronal Only", 4), ("Sagittal Only", 5)] {
                let it = NSMenuItem(title: title, action: #selector(layoutChosen(_:)), keyEquivalent: "")
                it.target = self
                it.tag = tag
                m.addItem(it)
            }
            i.menu = m
            return i
        case TB.reset:
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Reset"
            i.toolTip = "Reset axes and view"
            i.image = img("arrow.counterclockwise")
            i.target = self
            i.action = #selector(resetAll(_:))
            return i
        case TB.snapshot:
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Save Image"
            i.image = img("camera")
            i.target = self
            i.action = #selector(saveImage(_:))
            return i
        default: return nil
        }
    }

    @objc func toolChanged(_ g: NSToolbarItemGroup) { mpr.session.tool = [Tool.browse, .window, .pan, .zoom][g.selectedIndex] }
    @objc func measureTool(_ i: NSMenuItem) { if let r = i.representedObject as? String, let t = Tool(rawValue: r) { mpr.session.tool = t } }
    @objc func resetAll(_ s: Any?) { mpr.resetAxes(); vrView?.resetView(.anterior); vrView?.fitVolume() }

    @objc func layoutChosen(_ i: NSMenuItem) {
        switch i.tag {
        case 0: setLayout(.threePlusThree)
        case 1: setLayout(.threeColumns)
        case 2: setLayout(.vrOnly)
        default: setLayout(.single(i.tag - 3))
        }
    }

    @objc func saveImage(_ s: Any?) {
        let images: [NSImage] = grid.panels.compactMap { ($0 as? ViewportView)?.snapshot() ?? ($0 as? VolumeRenderView)?.snapshot() }
        guard let first = images.first else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = "MPR.png"
        p.beginSheetModal(for: window!) { r in
            guard r == .OK, let url = p.url else { return }
            for (k, img) in images.enumerated() {
                let u = k == 0 ? url : url.deletingPathExtension().appendingPathExtension("\(k + 1).png")
                if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: u) }
            }
            _ = first
        }
    }
}

struct SlabControl: View {
    @ObservedObject var mpr: MPRSession
    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $mpr.mode) { ForEach(SlabMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            Slider(value: $mpr.thickness, in: 0...60).frame(width: 80).help("Slab thickness")
            Text(mpr.thickness < 0.5 ? "thin" : String(format: "%.0f mm", mpr.thickness)).font(.caption).monospacedDigit().frame(width: 44, alignment: .leading)
        }
    }
}

final class VRPanelModel: ObservableObject {
    weak var view: VolumeRenderView?
    @Published var busy: String?
}

struct MPRSidePanel: View {
    @ObservedObject var mpr: MPRSession
    @ObservedObject var vr: VRPanelModel
    let mode: MPRMode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if mode == .mpr {
                    GroupBox("Reformats") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Show axes", isOn: $mpr.showAxes)
                            Text("Drag a coloured line to move that plane, drag its dots to rotate (oblique MPR), drag the centre to move both. Scroll to page through slices.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Reset Axes") { mpr.resetAxes() }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let v = vr.view {
                    VRControls(view: v, model: vr)
                }
                GroupBox("Volume") {
                    VStack(alignment: .leading, spacing: 4) {
                        let vol = mpr.volume
                        Text("\(vol.width) × \(vol.height) × \(vol.depth) voxels")
                        Text(String(format: "%.2f × %.2f × %.2f mm", vol.spacing.x, vol.spacing.y, vol.spacing.z))
                        Text("Range \(DataSet.formatDS(vol.minValue)) … \(DataSet.formatDS(vol.maxValue)) \(vol.units)")
                    }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
    }
}

struct VRControls: View {
    let view: VolumeRenderView
    @ObservedObject var model: VRPanelModel
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("3D Presets") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(VRPreset.all) { p in
                        Button { view.preset = p; view.tfShift = 0; view.tfScale = 1; tick += 1 } label: {
                            HStack { Text(p.name); Spacer(); if view.preset.name == p.name { Image(systemName: "checkmark") } }
                        }.buttonStyle(.plain)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Mouse Tool") {
                Picker("", selection: Binding(get: { view.tool }, set: { view.tool = $0; tick += 1 })) {
                    Label("3D Rotate", systemImage: "rotate.3d").tag(VRTool.rotate)
                    Label("Roll", systemImage: "arrow.clockwise.circle").tag(VRTool.roll)
                    Label("Pan", systemImage: "hand.raised").tag(VRTool.pan)
                    Label("Zoom", systemImage: "plus.magnifyingglass").tag(VRTool.zoom)
                    Label("Adjust Window", systemImage: "circle.lefthalf.filled").tag(VRTool.window)
                    Label("Scalpel", systemImage: "scissors").tag(VRTool.scalpel)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                if view.tool == .scalpel {
                    Picker("", selection: Binding(get: { view.cutInside }, set: { view.cutInside = $0; tick += 1 })) {
                        Text("Cut inside").tag(true); Text("Cut outside").tag(false)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                HStack {
                    Button { view.undoCut(); tick += 1 } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!view.canUndo).help("Undo cut")
                    Button { view.redoCut(); tick += 1 } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!view.canRedo).help("Redo cut")
                    Button("Restore Volume") { view.restoreVolume(); tick += 1 }
                }
            }
            GroupBox("View") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach([("A", VolumeRenderView.ViewDirection.anterior), ("P", .posterior), ("L", .left), ("R", .right), ("S", .superior), ("I", .inferior)], id: \.0) { item in
                            Button(item.0) { view.resetView(item.1) }.help(["A": "Anterior", "P": "Posterior", "L": "Left", "R": "Right", "S": "Superior", "I": "Inferior"][item.0]!)
                        }
                    }
                    Toggle("Shading", isOn: Binding(get: { view.shading }, set: { view.shading = $0; tick += 1 }))
                    Picker("Rendering", selection: Binding(get: { view.quality }, set: { view.quality = $0; view.setNeedsDisplay(view.bounds); tick += 1 })) {
                        Text("Favor performance").tag(0); Text("Balanced").tag(1); Text("Favor resolution").tag(2)
                    }
                    Button("Fit Volume") { view.fitVolume() }
                }
            }
            GroupBox("Crop") {
                VStack(spacing: 2) {
                    cropSlider("Left–Right", 0)
                    cropSlider("Front–Back", 1)
                    cropSlider("Bottom–Top", 2)
                }
            }
            GroupBox("Output") {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Save Snapshot…") { saveSnapshot() }
                    Button("Quick Movie (360°)…") { movie() }
                    Button("Save 3D Model as STL…") { stl() }
                    if let b = model.busy { HStack { ProgressView().controlSize(.small); Text(b).font(.caption) } }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id(tick)
    }

    func cropSlider(_ title: String, _ axis: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                Slider(value: Binding(get: { Double(view.clipMin[axis]) }, set: { view.clipMin[axis] = Float(min($0, Double(view.clipMax[axis]) - 0.02)); view.setNeedsDisplay(view.bounds) }), in: 0...1)
                Slider(value: Binding(get: { Double(view.clipMax[axis]) }, set: { view.clipMax[axis] = Float(max($0, Double(view.clipMin[axis]) + 0.02)); view.setNeedsDisplay(view.bounds) }), in: 0...1)
            }
        }
    }

    func saveSnapshot() {
        guard let img = view.snapshot(), let w = view.window else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = "3D snapshot.png"
        p.beginSheetModal(for: w) { r in
            guard r == .OK, let url = p.url, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        }
    }

    func movie() {
        guard let w = view.window else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.mpeg4Movie]
        p.nameFieldStringValue = "3D rotation.mp4"
        p.beginSheetModal(for: w) { r in
            guard r == .OK, let url = p.url else { return }
            model.busy = "Rendering video…"
            DispatchQueue.main.async {
                let frames = view.rotationFrames(count: 120, degrees: 360, size: CGSize(width: 1280, height: 720))
                MovieWriter.write(images: frames, fps: 30, quality: 0.9, to: url) { ok in
                    DispatchQueue.main.async { model.busy = nil; if ok { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                }
            }
        }
    }

    func stl() {
        guard let w = view.window else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: "stl") ?? .data]
        p.nameFieldStringValue = "3D model.stl"
        p.beginSheetModal(for: w) { r in
            guard r == .OK, let url = p.url else { return }
            model.busy = "Building surface…"
            view.exportSTL(to: url, progress: { model.busy = String(format: "Building surface… %.0f%%", $0 * 100) }) { ok in
                model.busy = nil
                if ok { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}

/// Small floating progress panel.
final class ProgressWindow {
    private let panel: NSPanel
    private let bar = NSProgressIndicator()
    var value: Double = 0 { didSet { bar.doubleValue = value * 100 } }

    init(title: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 76), styleMask: [.titled, .hudWindow, .utilityWindow], backing: .buffered, defer: false)
        panel.title = title
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 100
        bar.frame = NSRect(x: 20, y: 28, width: 280, height: 20)
        panel.contentView?.addSubview(bar)
        panel.isFloatingPanel = true
    }

    func show() { panel.center(); panel.orderFront(nil) }
    func close() { panel.orderOut(nil) }
}
