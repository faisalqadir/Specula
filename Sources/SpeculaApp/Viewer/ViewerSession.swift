import AppKit
import Combine
import DICOMCore

struct GridLayout: Equatable {
    var rows: Int
    var columns: Int
    var count: Int { rows * columns }
    static let single = GridLayout(rows: 1, columns: 1)
}

enum SyncMode: String { case auto, manual, disabled }

/// Coordinates the viewports of one viewer window.
final class ViewerSession: ObservableObject {
    let collection = StudyCollection()
    @Published var layout = GridLayout(rows: Preferences.shared.defaultLayoutRows, columns: Preferences.shared.defaultLayoutColumns)
    @Published private(set) var viewports: [ViewportView] = []
    @Published private(set) var activeIndex = 0
    @Published var tool: Tool = .browse { didSet { viewports.forEach { $0.updateCursor(); $0.draft = nil } } }
    @Published var showAnnotations = true { didSet { redrawAll() } }
    @Published var hidePatientData = false { didSet { redrawAll() } }
    @Published var showCrossReference = true { didSet { redrawAll() } }
    @Published var showMeasurements = true { didSet { redrawAll() } }
    @Published var syncMode: SyncMode = Preferences.shared.syncEnabled ? .auto : .disabled
    @Published var syncSlice = Preferences.shared.syncSlice
    @Published var syncZoom = Preferences.shared.syncZoom
    @Published var syncWindow = Preferences.shared.syncWindow
    @Published var loading: LoadProgress?
    @Published var maximized: ViewportView?
    @Published var cursor3D: Vec3? { didSet { redrawAll() } }
    @Published var fontScale: CGFloat = 1 { didSet { redrawAll() } }
    @Published var statusText = ""
    @Published var measurementRevision = 0

    var mprActive = false
    weak var windowController: ViewerWindowController?
    let gridView = ViewportGridView()
    private var measurementStore: [ImageRef: [Measurement]] = [:]
    private var calibrations: [ObjectIdentifier: Double] = [:]  // per series: mm per pixel
    private var cineTimer: Timer?
    private var cineLastTick: [ObjectIdentifier: (CFTimeInterval, Double)] = [:]
    private var loader: DICOMLoader?
    private var autoShown = false
    private var bag = Set<AnyCancellable>()

    init() {
        gridView.session = self
        applyLayout()
    }

    var active: ViewportView? { viewports[safe: activeIndex] }
    var activeState: ViewportState? { active?.state }
    var viewportCount: Int { layout.count }

    // MARK: - Layout

    func applyLayout() {
        let n = layout.count
        while viewports.count < n {
            let st = ViewportState()
            st.session = self
            let v = ViewportView(state: st, session: self)
            st.onChange = { [weak v] _ in v?.needsRedraw() }
            viewports.append(v)
        }
        if viewports.count > n {
            // keep extra panels' series by moving them? RadiAnt simply drops them
            viewports.removeLast(viewports.count - n)
        }
        if activeIndex >= n { activeIndex = 0 }
        maximized = nil
        gridView.rebuild()
        updateActiveFlags()
        // Fill empty panels with following series
        fillEmptyPanels()
    }

    /// Used by the MPR window, which owns its own reformat panels.
    func installViewports(_ v: [ViewportView]) {
        viewports = v
        layout = GridLayout(rows: 1, columns: v.count)
        activeIndex = 0
        updateActiveFlags()
    }

    func setLayout(rows: Int, columns: Int) {
        layout = GridLayout(rows: max(1, min(6, rows)), columns: max(1, min(6, columns)))
        applyLayout()
    }

    func fillEmptyPanels() {
        let all = collection.allSeries.filter { $0.kind == .image || $0.kind == .video }
        guard !all.isEmpty else { return }
        var used = Set(viewports.compactMap { $0.state.series.map(ObjectIdentifier.init) })
        var next = all.firstIndex { !used.contains(ObjectIdentifier($0)) } ?? 0
        for v in viewports where v.state.series == nil {
            guard next < all.count else { break }
            while next < all.count && used.contains(ObjectIdentifier(all[next])) { next += 1 }
            guard next < all.count else { break }
            show(all[next], in: v)
            used.insert(ObjectIdentifier(all[next]))
            next += 1
        }
    }

    func toggleMaximize(_ v: ViewportView) {
        maximized = maximized === v ? nil : v
        gridView.rebuild()
    }

    func activate(_ v: ViewportView) {
        guard let i = viewports.firstIndex(where: { $0 === v }) else { return }
        if i != activeIndex {
            activeIndex = i
            updateActiveFlags()
            redrawAll()
            NotificationCenter.default.post(name: .activeViewportChanged, object: self)
        }
    }

    private func updateActiveFlags() {
        for (i, v) in viewports.enumerated() { v.isActive = i == activeIndex }
    }

    func redrawAll() { viewports.forEach { $0.needsRedraw() } }

    // MARK: - Opening

    func open(urls: [URL], recordRecent: Bool = true) {
        guard !urls.isEmpty else { return }
        if recordRecent { for u in urls { NSDocumentController.shared.noteNewRecentDocumentURL(u) } }
        let loader = DICOMLoader()
        self.loader = loader
        autoShown = !viewports.allSatisfy { $0.state.series == nil }
        loading = LoadProgress(phase: "Scanning folder…", found: 0, loaded: 0, done: false)
        loader.load(urls: urls, passwordProvider: { [weak self] url in self?.askPassword(for: url) }, batch: { [weak self] insts in
            guard let self else { return }
            let touched = self.collection.add(insts)
            self.autoShowIfNeeded()
            for s in touched { self.refreshViewports(showing: s) }
            ThumbnailGenerator.shared.generate(for: touched)
        }, progress: { [weak self] p in
            self?.loading = p.done ? nil : p
            self?.statusText = p.done ? "" : "\(p.phase) \(p.loaded)/\(p.found)"
        }, completion: { [weak self] count in
            guard let self else { return }
            if count == 0 && self.collection.isEmpty {
                let a = NSAlert()
                a.messageText = "No DICOM images found"
                a.informativeText = "Would you like to open another folder with DICOM files?"
                a.addButton(withTitle: "Open…")
                a.addButton(withTitle: "Cancel")
                if let w = self.windowController?.window {
                    a.beginSheetModal(for: w) { r in if r == .alertFirstButtonReturn { self.windowController?.openDocument(nil) } }
                }
            }
            self.fillEmptyPanels()
            self.windowController?.updateTitle()
        })
    }

    func cancelLoading() { loader?.cancel() }

    private func askPassword(for url: URL) -> String? {
        let a = NSAlert()
        a.messageText = "Password needed"
        a.informativeText = "File \(url.lastPathComponent) is password-protected. Please enter the password in the box below."
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        a.accessoryView = f
        a.window.initialFirstResponder = f
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }

    private func autoShowIfNeeded() {
        guard !autoShown, Preferences.shared.autoShowFirstImage else { return }
        guard let first = collection.allSeries.first(where: { ($0.kind == .image || $0.kind == .video) && $0.imageCount > 0 }) else { return }
        autoShown = true
        show(first, in: viewports[0])
        activate(viewports[0])
    }

    private func refreshViewports(showing s: Series) {
        for v in viewports where v.state.series === s {
            if v.state.index >= s.images.count { v.state.setIndex(s.images.count - 1) }
            v.needsRedraw()
        }
    }

    // MARK: - Series placement

    func show(_ s: Series, in v: ViewportView? = nil, index: Int? = nil) {
        let target = v ?? active ?? viewports[0]
        if s.kind == .structuredReport || s.kind == .pdf {
            DocumentViewer.show(series: s, from: windowController?.window)
            return
        }
        if s.kind == .video, let inst = s.first {
            VideoPlayerWindow.show(instance: inst)
            return
        }
        target.mpr = nil
        target.state.setSeries(s, index: index ?? (s.images.count > 0 && s.modality != "US" && s.modality != "XA" ? 0 : 0))
        target.resetFrame()
        activate(target)
        syncFrom(target.state)
        redrawAll()
        windowController?.updateTitle()
    }

    func showSeries(id: String, in v: ViewportView) {
        guard let s = collection.allSeries.first(where: { $0.id.uuidString == id }) else { return }
        show(s, in: v)
    }

    func openInNewPanel(_ s: Series) {
        if let empty = viewports.first(where: { $0.state.series == nil }) { show(s, in: empty); return }
        let n = layout.count + 1
        let cols = Int(ceil(sqrt(Double(n))))
        let rows = Int(ceil(Double(n) / Double(cols)))
        setLayout(rows: rows, columns: cols)
        if let empty = viewports.first(where: { $0.state.series == nil }) { show(s, in: empty) }
    }

    func stepSeries(in v: ViewportView, by d: Int) {
        let all = collection.allSeries.filter { $0.kind == .image || $0.kind == .video }
        guard !all.isEmpty else { return }
        let cur = v.state.series.flatMap { s in all.firstIndex { $0 === s } } ?? -1
        let next = max(0, min(all.count - 1, cur + d))
        if next != cur { show(all[next], in: v) }
    }

    func firstSeries(_ v: ViewportView) { if let s = collection.allSeries.first { show(s, in: v) } }
    func lastSeries(_ v: ViewportView) { if let s = collection.allSeries.last { show(s, in: v) } }

    func closeActivePanel() {
        guard let v = active else { return }
        v.state.setSeries(nil)
        v.resetFrame()
        v.needsRedraw()
    }

    func closeAllPanels() {
        for v in viewports { v.state.setSeries(nil); v.resetFrame(); v.needsRedraw() }
    }

    // MARK: - Change notifications from viewports

    func viewportImageChanged(_ s: ViewportState) {
        syncFrom(s)
        if let v = viewports.first(where: { $0.state === s }) { v.needsRedraw() }
        if showCrossReference { redrawAll() }
        NotificationCenter.default.post(name: .viewportImageChanged, object: self)
    }

    func viewportDisplayChanged(_ s: ViewportState, window: Bool = false, zoomPan: Bool = false) {
        guard syncMode != .disabled else { return }
        for v in viewports where v.state !== s && v.state.series != nil {
            var changed = false
            if window && syncWindow, sameModality(v.state, s) {
                v.state.display.windowCenter = s.display.windowCenter
                v.state.display.windowWidth = s.display.windowWidth
                v.state.display.windowName = s.display.windowName
                changed = true
            }
            if zoomPan && syncZoom, syncCompatible(v.state, s) {
                v.state.display.zoom = s.display.zoom
                v.state.display.pan = s.display.pan
                v.state.display.fitMode = s.display.fitMode
                changed = true
            }
            if changed { v.needsRedraw() }
        }
    }

    func viewportDisplayInitialized(_ s: ViewportState) {
        if let v = viewports.first(where: { $0.state === s }) { v.needsRedraw() }
    }

    private func sameModality(_ a: ViewportState, _ b: ViewportState) -> Bool { a.series?.modality == b.series?.modality }

    private func syncCompatible(_ a: ViewportState, _ b: ViewportState) -> Bool {
        guard let fa = a.series?.frameOfReference, let fb = b.series?.frameOfReference else { return a.series?.study === b.series?.study }
        return fa == fb || syncMode == .manual
    }

    /// Synchronises slice position of other panels to the given one.
    func syncFrom(_ s: ViewportState) {
        guard syncMode != .disabled, syncSlice, let ref = s.current, let plane = ref.plane else { return }
        let p = plane.center
        for v in viewports where v.state !== s && v.mpr == nil {
            guard let other = v.state.series, other !== s.series, other.imageCount > 1, syncCompatible(v.state, s) else { continue }
            guard let n = other.images.first?.plane?.normal, abs(n.dot(plane.normal)) > 0.9 else { continue }
            let target = p.dot(n) + v.state.syncOffset - s.syncOffset
            var best = -1, bestD = Double.greatestFiniteMagnitude
            for (i, r) in other.images.enumerated() {
                guard let rp = r.plane else { continue }
                let d = abs(rp.position.dot(n) - target)
                if d < bestD { bestD = d; best = i }
            }
            let spacing = other.images.count > 1 ? abs((other.images[1].plane?.position.dot(n) ?? 0) - (other.images[0].plane?.position.dot(n) ?? 0)) : 1
            if best >= 0, bestD <= max(spacing, 1) * 1.5 + 2, best != v.state.index {
                v.state.index = best
                v.needsRedraw()
            }
        }
    }

    /// Captures current relative positions as manual sync offsets.
    func setManualSync() {
        syncMode = .manual
        guard let a = activeState, let pa = a.current?.plane else { return }
        let n = pa.normal
        for v in viewports where v.state !== a {
            if let p = v.state.current?.plane { v.state.syncOffset = p.position.dot(n) - pa.position.dot(n) }
        }
        a.syncOffset = 0
    }

    func referencePlanes(excluding v: ViewportView) -> [(ImagePlane, Bool)] {
        var out: [(ImagePlane, Bool)] = []
        for (i, o) in viewports.enumerated() where o !== v {
            guard let p = o.currentPlane else { continue }
            if let a = o.state.series?.frameOfReference, let b = v.state.series?.frameOfReference, a != b { continue }
            out.append((p, i == activeIndex))
        }
        return out
    }

    func hoverChanged(_ v: ViewportView) {}

    // MARK: - Measurements

    func measurements(for ref: ImageRef) -> [Measurement] { measurementStore[ref] ?? [] }

    func setMeasurements(_ list: [Measurement], for ref: ImageRef) {
        measurementStore[ref] = list.isEmpty ? nil : list
        measurementRevision += 1
    }

    func measurementsChanged() {
        measurementRevision += 1
        redrawAll()
    }

    var allMeasurements: [(ImageRef, Measurement)] {
        measurementStore.flatMap { ref, list in list.map { (ref, $0) } }
    }

    func deleteMeasurements(scope: MeasurementScope) {
        guard let v = active else { return }
        switch scope {
        case .selected:
            if let id = v.selectedMeasurement { v.measurements.removeAll { $0.id == id }; v.selectedMeasurement = nil }
        case .image:
            if let r = v.state.current { measurementStore[r] = nil }
        case .series:
            if let s = v.state.series { for r in s.images { measurementStore[r] = nil } }
        case .allVisible:
            for o in viewports { if let r = o.state.current { measurementStore[r] = nil } }
        }
        measurementsChanged()
    }

    private var clipboard: [Measurement] = []

    func copyMeasurements(all: Bool) {
        guard let v = active else { return }
        clipboard = all ? v.measurements : v.measurements.filter { $0.id == v.selectedMeasurement }
    }

    func pasteMeasurements() {
        guard let v = active, !clipboard.isEmpty else { return }
        v.measurements.append(contentsOf: clipboard.map { var m = $0; m.id = UUID(); return m })
        measurementsChanged()
    }

    func duplicateMeasurements(toAllImagesOfSeries: Bool) {
        guard let v = active, let r = v.state.current else { return }
        let src = v.measurements.filter { v.selectedMeasurement == nil || $0.id == v.selectedMeasurement }
        guard !src.isEmpty else { return }
        if toAllImagesOfSeries, let s = v.state.series {
            for other in s.images where other != r {
                measurementStore[other, default: []].append(contentsOf: src.map { var m = $0; m.id = UUID(); return m })
            }
        } else {
            for o in viewports where o !== v { if let orf = o.state.current { measurementStore[orf, default: []].append(contentsOf: src.map { var m = $0; m.id = UUID(); return m }) } }
        }
        measurementsChanged()
    }

    func calibration(for v: ViewportView) -> Double? { v.state.series.flatMap { calibrations[ObjectIdentifier($0)] } }

    func setCalibration(_ mmPerPixel: Double?, for v: ViewportView) {
        guard let s = v.state.series else { return }
        calibrations[ObjectIdentifier(s)] = mmPerPixel
        measurementsChanged()
    }

    // MARK: - Display operations

    func applyOrientation(_ op: OrthoTransform, to s: ViewportState) {
        s.display.orientation = s.display.orientation.then(op)
        if op == .flipH || op == .flipV {
            s.display.pan = CGPoint(x: op == .flipH ? -s.display.pan.x : s.display.pan.x, y: op == .flipV ? -s.display.pan.y : s.display.pan.y)
        } else {
            s.display.pan = op.apply(s.display.pan)
        }
        s.changed()
    }

    func applyToActive(_ f: (ViewportState) -> Void) {
        guard let v = active else { return }
        f(v.state)
        v.needsRedraw()
    }

    func applyPreset(_ p: WindowPreset) {
        applyToActive { s in
            s.display.windowCenter = p.center
            s.display.windowWidth = p.width
            s.display.windowName = p.name
        }
        if let s = activeState { viewportDisplayChanged(s, window: true) }
    }

    func applyDefaultWindow() {
        guard let v = active, let r = v.frameRef else { return }
        let (c, w, n) = v.state.defaultWindow(for: r, frame: v.frame2D)
        v.state.display.windowCenter = c; v.state.display.windowWidth = w; v.state.display.windowName = n
        v.needsRedraw()
        viewportDisplayChanged(v.state, window: true)
    }

    func applyFullDynamic() {
        guard let v = active, let r = v.frameRef, let f = v.frame2D else { return }
        let (c, w) = v.state.fullDynamic(frame: f, ref: r)
        v.state.display.windowCenter = c; v.state.display.windowWidth = w; v.state.display.windowName = "Full dynamic"
        v.needsRedraw()
        viewportDisplayChanged(v.state, window: true)
    }

    /// Window preset by number key (0 = full dynamic, 1 = default, 2-9 = presets).
    func applyPresetKey(_ k: Int) {
        if k == 0 { applyFullDynamic(); return }
        if k == 1 { applyDefaultWindow(); return }
        guard let m = activeState?.series?.modality else { return }
        if let p = WindowPreset.presets(for: m).first(where: { $0.key == k }) { applyPreset(p) }
    }

    // MARK: - Cine

    func setCine(_ s: ViewportState, playing: Bool) {
        s.cine.playing = playing
        cineLastTick[ObjectIdentifier(s)] = nil
        let anyPlaying = viewports.contains { $0.state.cine.playing }
        if anyPlaying && cineTimer == nil {
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.cineTick() }
            RunLoop.main.add(t, forMode: .common)
            cineTimer = t
        } else if !anyPlaying {
            cineTimer?.invalidate()
            cineTimer = nil
        }
        s.changed()
        NotificationCenter.default.post(name: .cineStateChanged, object: self)
    }

    func toggleCine(_ s: ViewportState? = nil) {
        guard let st = s ?? activeState, st.imageCount > 1 else { return }
        setCine(st, playing: !st.cine.playing)
    }

    private func cineTick() {
        let now = CACurrentMediaTime()
        for v in viewports where v.state.cine.playing {
            let s = v.state
            let key = ObjectIdentifier(s)
            let interval = 1 / max(0.5, s.cine.fps)
            guard let (last, start) = cineLastTick[key] else { cineLastTick[key] = (now, now); continue }
            if now - last >= interval {
                // Skip a frame only if the next one is decoded (avoid stutter on slow decodes)
                let next = (s.index + 1) % max(1, s.imageCount)
                if let r = s.series?.images[safe: next], FrameCache.shared.cached(r) == nil {
                    FrameCache.shared.request(r, priority: .veryHigh) { _ in }
                    continue
                }
                s.index = next
                let elapsed = now - start
                s.cine.measuredFPS = s.cine.measuredFPS == 0 ? 1 / interval : s.cine.measuredFPS * 0.9 + (1 / max(0.001, now - last)) * 0.1
                cineLastTick[key] = (now, elapsed > 2 ? now : start)
                v.needsRedraw()
                syncFrom(s)
                if let ser = s.series { FrameCache.shared.prefetch(ser.images, around: s.index, radius: 6) }
            }
        }
    }

    // MARK: - 3D cursor

    func setCursor3D(from v: ViewportView, at p: CGPoint) {
        guard let plane = v.currentPlane else { return }
        let pt = plane.patientPoint(x: Double(p.x), y: Double(p.y))
        cursor3D = pt
        // Move other viewports to the slice containing the point
        for o in viewports where o !== v {
            guard let s = o.state.series, let n = s.images.first?.plane?.normal else { continue }
            var best = -1, bestD = Double.greatestFiniteMagnitude
            for (i, r) in s.images.enumerated() {
                guard let rp = r.plane else { continue }
                let d = abs((pt - rp.position).dot(n))
                if d < bestD { bestD = d; best = i }
            }
            if best >= 0 && bestD < 10 { o.state.index = best; o.needsRedraw() }
        }
        NotificationCenter.default.post(name: .cursor3DChanged, object: self, userInfo: ["point": pt])
    }

    // MARK: - Context menu

    func contextMenu(for v: ViewportView) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, _ key: String = "") { m.addItem(withTitle: title, action: sel, keyEquivalent: key) }
        add("Copy Image", #selector(ViewerWindowController.copyImage(_:)))
        m.addItem(.separator())
        let presets = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        presets.submenu = windowController?.makePresetMenu()
        m.addItem(presets)
        add("Negative", #selector(ViewerWindowController.toggleNegative(_:)))
        add("Fit to Viewport", #selector(ViewerWindowController.fitImage(_:)))
        add("Actual Size", #selector(ViewerWindowController.actualSize(_:)))
        let tr = NSMenuItem(title: "Transformations", action: nil, keyEquivalent: "")
        let tm = NSMenu()
        tm.addItem(withTitle: "Rotate 90° Clockwise", action: #selector(ViewerWindowController.rotateCW(_:)), keyEquivalent: "")
        tm.addItem(withTitle: "Rotate 90° Counterclockwise", action: #selector(ViewerWindowController.rotateCCW(_:)), keyEquivalent: "")
        tm.addItem(withTitle: "Rotate 180°", action: #selector(ViewerWindowController.rotate180(_:)), keyEquivalent: "")
        tm.addItem(withTitle: "Flip Horizontal", action: #selector(ViewerWindowController.flipHorizontal(_:)), keyEquivalent: "")
        tm.addItem(withTitle: "Flip Vertical", action: #selector(ViewerWindowController.flipVertical(_:)), keyEquivalent: "")
        tm.addItem(.separator())
        tm.addItem(withTitle: "Clear Transformations", action: #selector(ViewerWindowController.clearTransformations(_:)), keyEquivalent: "")
        tr.submenu = tm
        m.addItem(tr)
        m.addItem(.separator())
        if v.selectedMeasurement != nil {
            add("Delete Selected Measurement", #selector(ViewerWindowController.deleteSelectedMeasurement(_:)))
            add("Copy Selected Measurement", #selector(ViewerWindowController.copySelectedMeasurement(_:)))
        }
        add("Delete All Measurements in Image", #selector(ViewerWindowController.deleteImageMeasurements(_:)))
        add("Paste Measurements", #selector(ViewerWindowController.pasteMeasurements(_:)))
        add("Calibrate Length…", #selector(ViewerWindowController.calibrate(_:)))
        m.addItem(.separator())
        add("Show DICOM Tags", #selector(ViewerWindowController.showTags(_:)))
        add("Show in Finder", #selector(ViewerWindowController.revealInFinder(_:)))
        add("Export Images…", #selector(ViewerWindowController.exportImages(_:)))
        if v.state.series?.volumeCandidate == true {
            m.addItem(.separator())
            add("3D MPR", #selector(ViewerWindowController.openMPR(_:)))
            add("3D Volume Rendering", #selector(ViewerWindowController.openVR(_:)))
        }
        m.addItem(.separator())
        add("Close Panel", #selector(ViewerWindowController.closePanel(_:)))
        return m
    }
}

enum MeasurementScope { case selected, image, series, allVisible }

extension Notification.Name {
    static let activeViewportChanged = Notification.Name("SpeculaActiveViewportChanged")
    static let viewportImageChanged = Notification.Name("SpeculaViewportImageChanged")
    static let cineStateChanged = Notification.Name("SpeculaCineStateChanged")
    static let cursor3DChanged = Notification.Name("SpeculaCursor3DChanged")
}
