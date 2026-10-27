import AppKit
import DICOMCore

enum DragKind {
    case browse, window, pan, zoom, measure, moveMeasurement(UUID, Int?), mpr, dsaShift, cursor3D
}

struct DragState {
    var kind: DragKind
    var start: CGPoint
    var last: CGPoint
    var startIndex: Int
    var startWindow: (Double, Double)
    var startZoom: Double
    var startPan: CGPoint
    var anchorImage: CGPoint
    var moved = false
    var startPoints: [CGPoint] = []
}

extension ViewportView {
    // MARK: - Helpers

    func viewPoint(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    func imagePoint(_ v: CGPoint) -> CGPoint? { transform?.toImage(v) }

    var measurements: [Measurement] {
        get { mpr == nil ? (state.current.map { session?.measurements(for: $0) ?? [] } ?? []) : (mprController?.measurements(for: self) ?? []) }
        set {
            if mpr == nil { if let r = state.current { session?.setMeasurements(newValue, for: r) } }
            else { mprController?.setMeasurements(newValue, for: self) }
            overlay.needsDisplay = true
        }
    }

    private func dragKind(for action: MouseAction, tool: Tool) -> DragKind {
        switch action {
        case .browse: return .browse
        case .zoom: return .zoom
        case .pan: return .pan
        case .window: return .window
        case .roi: return .measure
        case .none: return .pan
        case .activeTool:
            switch tool {
            case .browse: return .browse
            case .window: return .window
            case .pan: return .pan
            case .zoom: return .zoom
            case .cursor3D: return .cursor3D
            default: return .measure
            }
        }
    }

    // MARK: - Mouse

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control) { showContextMenu(e); return }
        beginDrag(e, button: 0)
    }

    override func rightMouseDown(with e: NSEvent) {
        rightDragged = false
        beginDrag(e, button: 1)
    }

    override func otherMouseDown(with e: NSEvent) { beginDrag(e, button: e.buttonNumber) }

    private func beginDrag(_ e: NSEvent, button: Int) {
        session?.activate(self)
        window?.makeFirstResponder(self)
        let p = viewPoint(e)
        let tool = session?.tool ?? .browse
        var action = Preferences.shared.action(forButton: button)
        if button == 0 {
            if e.modifierFlags.contains(.option) { action = .window }
            else if e.modifierFlags.contains(.shift) && !(tool.isMeasurement) { action = .pan }
            else if e.modifierFlags.contains(.command) && !(tool.isMeasurement) { action = .zoom }
        }
        let imgP = imagePoint(p) ?? .zero
        var kind = dragKind(for: action, tool: tool)
        let measureTool: Tool = action == .roi ? .length : tool

        // MPR crosshair handling takes precedence for navigation tools
        if mpr != nil, button == 0, case .browse = kind, let c = mprController, c.mouseDown(self, at: p) {
            kind = .mpr
        } else if case .measure = kind {
            // continue multi-click drafts
            if let d = draft { continueDraft(d, at: imgP, event: e); return }
        }
        // Grab existing measurement (left button, not while drawing)
        if button == 0, draft == nil, let hit = hitMeasurement(at: p) {
            selectedMeasurement = hit.0
            if e.clickCount == 2, let m = measurements.first(where: { $0.id == hit.0 }), m.kind == .text || m.kind == .arrow {
                editText(of: m.id)
                return
            }
            kind = .moveMeasurement(hit.0, hit.1)
        } else if button == 0 {
            selectedMeasurement = nil
        }
        if button == 0, e.clickCount == 2, case .browse = kind, mpr == nil {
            session?.toggleMaximize(self)
            return
        }
        if state.display.fitMode != .custom, case .zoom = kind { materializeZoom() }
        if state.display.fitMode != .custom, case .pan = kind { materializeZoom() }
        var ds = DragState(kind: kind, start: p, last: p, startIndex: state.index, startWindow: (state.display.windowCenter, state.display.windowWidth),
                           startZoom: state.display.zoom, startPan: state.display.pan, anchorImage: imgP)
        if case .moveMeasurement(let id, _) = kind, let m = measurements.first(where: { $0.id == id }) { ds.startPoints = m.points }
        dragState = ds
        if case .measure = kind, let mk = MeasurementKind(tool: measureTool) { startDraft(mk, at: imgP, event: e) }
        if case .cursor3D = kind { session?.setCursor3D(from: self, at: imgP) }
        updateCursor()
    }

    override func mouseDragged(with e: NSEvent) { continueDrag(e) }
    override func rightMouseDragged(with e: NSEvent) { rightDragged = true; continueDrag(e) }
    override func otherMouseDragged(with e: NSEvent) { continueDrag(e) }

    private func continueDrag(_ e: NSEvent) {
        guard var ds = dragState else { return }
        let p = viewPoint(e)
        let delta = CGPoint(x: p.x - ds.last.x, y: p.y - ds.last.y)
        let total = CGPoint(x: p.x - ds.start.x, y: p.y - ds.start.y)
        if total.length > 2 { ds.moved = true }
        hoverPoint = p
        switch ds.kind {
        case .browse:
            let n = max(1, state.imageCount)
            let ppi = max(2, min(12, bounds.height / CGFloat(n) * 2))
            let target = ds.startIndex + Int((total.y / ppi).rounded())
            if session?.mprActive != true { state.setIndex(target, wrap: false) }
            session?.viewportImageChanged(state)
        case .window:
            applyWindowDrag(total, ds: ds)
        case .pan:
            state.display.pan = CGPoint(x: state.display.pan.x + delta.x, y: state.display.pan.y + delta.y)
            state.display.fitMode = .custom
            session?.viewportDisplayChanged(state, zoomPan: true)
        case .zoom:
            let factor = exp(Double(-total.y) * 0.008)
            zoom(to: max(0.02, min(80, ds.startZoom * factor)), anchorView: ds.start, anchorImage: ds.anchorImage)
        case .measure:
            if let ip = imagePoint(p) { updateDraft(at: ip, dragging: true) }
        case .moveMeasurement(let id, let handle):
            guard let t = transform, var list = measurements as [Measurement]?, let i = list.firstIndex(where: { $0.id == id }) else { break }
            let a = t.toImage(ds.start), b = t.toImage(p)
            let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
            var m = list[i]
            if let h = handle, h < m.points.count {
                m.points = ds.startPoints
                m.points[h] = ds.startPoints[h] + d
            } else {
                m.points = ds.startPoints.map { $0 + d }
            }
            list[i] = m
            measurements = list
        case .mpr:
            mprController?.mouseDragged(self, to: p, delta: delta)
        case .dsaShift:
            if let t = transform {
                let a = t.toImage(ds.last), b = t.toImage(p)
                state.subtraction.shift = state.subtraction.shift + CGPoint(x: b.x - a.x, y: b.y - a.y)
                needsRedraw()
            }
        case .cursor3D:
            if let ip = imagePoint(p) { session?.setCursor3D(from: self, at: ip) }
        }
        ds.last = p
        dragState = ds
        needsRedraw()
    }

    override func mouseUp(with e: NSEvent) { endDrag(e) }
    override func otherMouseUp(with e: NSEvent) { endDrag(e) }
    override func rightMouseUp(with e: NSEvent) {
        let moved = dragState?.moved ?? false
        endDrag(e)
        if !moved && !rightDragged { showContextMenu(e) }
    }

    private func endDrag(_ e: NSEvent) {
        guard let ds = dragState else { return }
        dragState = nil
        if case .measure = ds.kind, let ip = imagePoint(viewPoint(e)) { finishDraftStage(at: ip, moved: ds.moved) }
        if case .mpr = ds.kind { mprController?.mouseUp(self) }
        if case .moveMeasurement = ds.kind { session?.measurementsChanged() }
        updateCursor()
        needsRedraw()
    }

    func applyWindowDrag(_ total: CGPoint, ds: DragState) {
        let dirs = Preferences.shared.windowDirections
        var dx = total.x, dy = total.y
        if dirs & 1 != 0 { swap(&dx, &dy) }
        if dirs & 2 != 0 { dy = -dy }
        if dirs & 4 != 0 { dx = -dx }
        var range = 256.0
        if let f = frame2D, let r = frameRef {
            let a = r.attributes
            range = max(1, (f.maxValue - f.minValue) * abs(a.rescaleSlope))
        } else if let m = mpr { range = max(1, m.volume.maxValue - m.volume.minValue) }
        let k = max(range / 900, 0.02)
        state.display.windowWidth = max(k, ds.startWindow.1 + Double(dx) * k * 1.4)
        state.display.windowCenter = ds.startWindow.0 + Double(dy) * k
        state.display.windowName = nil
        session?.viewportDisplayChanged(state, window: true)
        needsRedraw()
    }

    func zoom(to z: Double, anchorView: CGPoint, anchorImage: CGPoint) {
        if state.display.fitMode != .custom { materializeZoom() }
        state.display.zoom = z
        state.display.fitMode = .custom
        if Preferences.shared.zoomAroundCursor, var t = transform {
            t.pan = .zero
            let v = t.toView(anchorImage)
            state.display.pan = CGPoint(x: anchorView.x - v.x, y: anchorView.y - v.y)
        }
        session?.viewportDisplayChanged(state, zoomPan: true)
        needsRedraw()
    }

    // MARK: - Hover / cursor

    override func mouseMoved(with e: NSEvent) {
        hoverPoint = viewPoint(e)
        if let d = draft, let ip = imagePoint(hoverPoint!) {
            if d.kind == .closedPolygon || d.kind == .openPolygon || (d.kind == .angle && draftStage == 1) || (d.kind == .deviation && draftStage == 1) {
                updateDraft(at: ip, dragging: false)
            }
        }
        if mpr != nil { mprController?.mouseMoved(self, at: hoverPoint!) }
        overlay.needsDisplay = true
        session?.hoverChanged(self)
    }

    override func mouseExited(with e: NSEvent) {
        hoverPoint = nil
        overlay.needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    func updateCursor() {
        let tool = session?.tool ?? .browse
        if let ds = dragState {
            switch ds.kind {
            case .pan: NSCursor.closedHand.set()
            case .browse: NSCursor.resizeUpDown.set()
            case .zoom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
            return
        }
        switch tool {
        case .browse: NSCursor.arrow.set()
        case .pan: NSCursor.openHand.set()
        case .zoom, .window: NSCursor.crosshair.set()
        default: NSCursor.crosshair.set()
        }
    }

    // MARK: - Scroll & gestures

    override func scrollWheel(with e: NSEvent) {
        session?.activate(self)
        if e.modifierFlags.contains(.option) || Preferences.shared.wheelZooms {
            let p = viewPoint(e)
            guard let ip = imagePoint(p) else { return }
            if state.display.fitMode != .custom { materializeZoom() }
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
            zoom(to: max(0.02, min(80, state.display.zoom * exp(Double(dy) * 0.01))), anchorView: p, anchorImage: ip)
            return
        }
        var dy = e.scrollingDeltaY
        let dx = e.scrollingDeltaX
        if Preferences.shared.invertScroll { dy = -dy }
        if e.phase == .began { scrollAccumulator = 0 }
        // Horizontal scroll changes series
        if abs(dx) > abs(dy) * 1.5, Preferences.shared.horizontalWheelChangesSeries, mpr == nil {
            scrollAccumulator += e.hasPreciseScrollingDeltas ? dx : dx * 20
            if abs(scrollAccumulator) > 60 {
                session?.stepSeries(in: self, by: scrollAccumulator > 0 ? -1 : 1)
                scrollAccumulator = 0
            }
            return
        }
        var steps = 0
        if e.hasPreciseScrollingDeltas {
            scrollAccumulator += dy
            let threshold: CGFloat = e.momentumPhase != [] ? 14 : 9
            while abs(scrollAccumulator) >= threshold {
                steps += scrollAccumulator > 0 ? -1 : 1
                scrollAccumulator -= scrollAccumulator > 0 ? threshold : -threshold
            }
        } else if dy != 0 {
            steps = dy > 0 ? -1 : 1
        }
        guard steps != 0 else { return }
        if let mpr, let c = mprController {
            c.scroll(self, plane: mpr, steps: steps)
            return
        }
        let wrap = Preferences.shared.endlessScrolling && dragState == nil && !e.hasPreciseScrollingDeltas
        state.setIndex(state.index + steps, wrap: wrap)
        session?.viewportImageChanged(state)
        needsRedraw()
    }

    override func magnify(with e: NSEvent) {
        let p = viewPoint(e)
        if e.phase == .began || magnifyAnchor == nil { magnifyAnchor = imagePoint(p) }
        guard let anchor = magnifyAnchor else { return }
        if state.display.fitMode != .custom { materializeZoom() }
        zoom(to: max(0.02, min(80, state.display.zoom * (1 + Double(e.magnification)))), anchorView: p, anchorImage: anchor)
        if e.phase == .ended || e.phase == .cancelled { magnifyAnchor = nil }
    }

    override func smartMagnify(with e: NSEvent) {
        let p = viewPoint(e)
        if state.display.fitMode == .fit, let ip = imagePoint(p), let t = transform {
            zoom(to: Double(t.zoom) * 2.5, anchorView: p, anchorImage: ip)
        } else {
            state.display.fitMode = .fit
            session?.viewportDisplayChanged(state, zoomPan: true)
            needsRedraw()
        }
    }

    override func rotate(with e: NSEvent) {
        if e.phase == .began { rotationAccumulator = 0 }
        rotationAccumulator += CGFloat(e.rotation)
        if rotationAccumulator > 40 {
            session?.applyOrientation(.rotateCCW, to: state); rotationAccumulator = -50
        } else if rotationAccumulator < -40 {
            session?.applyOrientation(.rotateCW, to: state); rotationAccumulator = 50
        }
    }

    // MARK: - Keyboard

    override func keyDown(with e: NSEvent) {
        guard let chars = e.charactersIgnoringModifiers?.unicodeScalars.first else { super.keyDown(with: e); return }
        let n = state.imageCount
        switch Int(chars.value) {
        case NSUpArrowFunctionKey:
            if let mpr, let c = mprController { c.scroll(self, plane: mpr, steps: -1) } else { step(-1) }
        case NSDownArrowFunctionKey:
            if let mpr, let c = mprController { c.scroll(self, plane: mpr, steps: 1) } else { step(1) }
        case NSLeftArrowFunctionKey: session?.stepSeries(in: self, by: -1)
        case NSRightArrowFunctionKey: session?.stepSeries(in: self, by: 1)
        case NSPageUpFunctionKey: step(-max(1, n / 10))
        case NSPageDownFunctionKey: step(max(1, n / 10))
        case NSHomeFunctionKey: state.setIndex(0); session?.viewportImageChanged(state); needsRedraw()
        case NSEndFunctionKey: state.setIndex(n - 1); session?.viewportImageChanged(state); needsRedraw()
        case 0x7F, NSDeleteFunctionKey:
            if let id = selectedMeasurement { measurements.removeAll { $0.id == id }; selectedMeasurement = nil; session?.measurementsChanged() }
        case 0x1B:
            if draft != nil { draft = nil; draftStage = 0; overlay.needsDisplay = true }
            else if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        case 0x0D, 0x03:
            if let d = draft, d.kind == .closedPolygon || d.kind == .openPolygon { commitDraft(dropLast: true) }
        case 0x20: session?.toggleCine(state)
        default:
            let mods = e.modifierFlags.intersection([.command, .control, .option])
            guard mods.isEmpty, let ch = e.charactersIgnoringModifiers?.lowercased(), ch.count == 1 else { super.keyDown(with: e); return }
            if let d = Int(ch) { session?.applyPresetKey(d); return }
            let map: [String: Tool] = ["b": .browse, "w": .window, "p": .pan, "z": .zoom, "l": .length, "a": .angle, "c": .cobbAngle,
                                       "e": .ellipse, "r": .rectangle, "g": .closedPolygon, "o": .openPolygon, "d": .pencil,
                                       "t": .text, "x": .arrow, "v": .probe, "k": .cursor3D]
            if let t = map[ch] { session?.tool = t; return }
            if ch == "n" { state.display.negative.toggle(); needsRedraw(); return }
            if ch == "f" { state.display.fitMode = .fit; session?.viewportDisplayChanged(state, zoomPan: true); needsRedraw(); return }
            super.keyDown(with: e)
        }
    }

    func step(_ d: Int) {
        state.setIndex(state.index + d, wrap: Preferences.shared.endlessScrolling)
        session?.viewportImageChanged(state)
        needsRedraw()
    }

    // MARK: - Measurement drafting

    private func startDraft(_ kind: MeasurementKind, at p: CGPoint, event: NSEvent) {
        var m = Measurement(kind: kind, points: [p])
        m.style.color = Preferences.shared.measurementColor
        switch kind {
        case .length, .arrow, .ellipse, .rectangle, .angle, .cobbAngle, .deviation:
            m.points = [p, p]
        case .closedPolygon, .openPolygon:
            m.points = [p, p]
        case .pencil:
            m.points = [p]
        case .text:
            draft = nil
            promptText(title: "Add text annotation", initial: "") { [weak self] text in
                guard let self, let text, !text.isEmpty else { return }
                m.text = text
                self.measurements.append(m)
                self.selectedMeasurement = m.id
                self.session?.measurementsChanged()
            }
            dragState = nil
            return
        case .probe:
            measurements.append(m)
            selectedMeasurement = m.id
            session?.measurementsChanged()
            dragState = nil
            return
        }
        draft = m
        draftStage = 0
    }

    private func continueDraft(_ d: Measurement, at p: CGPoint, event: NSEvent) {
        var m = d
        switch m.kind {
        case .closedPolygon, .openPolygon:
            if event.clickCount >= 2 {
                draft = m
                commitDraft(dropLast: true)
                return
            }
            m.points[m.points.count - 1] = p
            m.points.append(p)
            draft = m
        case .angle:
            if draftStage == 1 { m.points[2] = p; draft = m; commitDraft(dropLast: false); return }
        case .cobbAngle:
            if draftStage == 1 { m.points.append(p); m.points.append(p); draft = m; draftStage = 2 }
        case .deviation:
            if draftStage == 1 { m.points[2] = p; draft = m; commitDraft(dropLast: false); return }
        default: break
        }
        dragState = DragState(kind: .measure, start: CGPoint.zero, last: CGPoint.zero, startIndex: state.index, startWindow: (0, 0), startZoom: 0, startPan: .zero, anchorImage: p)
        overlay.needsDisplay = true
    }

    func updateDraft(at p: CGPoint, dragging: Bool) {
        guard var m = draft else { return }
        switch m.kind {
        case .length, .arrow, .ellipse, .rectangle:
            m.points[1] = p
        case .angle:
            if draftStage == 0 { m.points[1] = p } else if m.points.count >= 3 { m.points[2] = p }
        case .cobbAngle:
            if draftStage == 0 { m.points[1] = p } else if draftStage == 2 && m.points.count >= 4 { m.points[3] = p }
        case .deviation:
            if draftStage == 0 { m.points[1] = p } else if m.points.count >= 3 { m.points[2] = p }
        case .closedPolygon, .openPolygon:
            m.points[m.points.count - 1] = p
        case .pencil:
            if let last = m.points.last, last.distance(to: p) > 0.6 { m.points.append(p) }
        default: break
        }
        draft = m
        overlay.needsDisplay = true
    }

    private func finishDraftStage(at p: CGPoint, moved: Bool) {
        guard var m = draft else { return }
        let tooSmall: Bool = {
            guard let t = transform, m.points.count >= 2 else { return true }
            return t.toView(m.points[0]).distance(to: t.toView(m.points[1])) < 4
        }()
        switch m.kind {
        case .length, .ellipse, .rectangle:
            if tooSmall { draft = nil; return }
            commitDraft(dropLast: false)
        case .arrow:
            if tooSmall { draft = nil; return }
            commitDraft(dropLast: false)
            let id = m.id
            promptText(title: "Arrow label (optional)", initial: "") { [weak self] text in
                guard let self, let text, !text.isEmpty, var list = self.measurements as [Measurement]?, let i = list.firstIndex(where: { $0.id == id }) else { return }
                list[i].text = text
                self.measurements = list
            }
        case .angle:
            if draftStage == 0 {
                if tooSmall { draft = nil; return }
                m.points.append(p)
                draft = m
                draftStage = 1
            }
        case .cobbAngle:
            if draftStage == 0 {
                if tooSmall { draft = nil; return }
                draftStage = 1
            } else if draftStage == 2 {
                commitDraft(dropLast: false)
            }
        case .deviation:
            if draftStage == 0 {
                if tooSmall { draft = nil; return }
                m.points.append(p)
                draft = m
                draftStage = 1
            }
        case .pencil:
            if m.points.count < 3 { draft = nil; return }
            commitDraft(dropLast: false)
        case .closedPolygon, .openPolygon:
            break // finished by double-click / return
        default:
            break
        }
        overlay.needsDisplay = true
    }

    func commitDraft(dropLast: Bool) {
        guard var m = draft else { return }
        if dropLast, m.points.count > 2 { m.points.removeLast() }
        // remove duplicate trailing points from double-clicks
        while m.points.count > 2, let a = m.points.last, a.distance(to: m.points[m.points.count - 2]) < 0.01 { m.points.removeLast() }
        if m.kind == .closedPolygon && m.points.count < 3 { draft = nil; return }
        if m.kind == .openPolygon && m.points.count < 2 { draft = nil; return }
        measurements.append(m)
        selectedMeasurement = m.id
        draft = nil
        draftStage = 0
        session?.measurementsChanged()
    }

    /// Returns (measurement id, handle index or nil) under a view point.
    func hitMeasurement(at v: CGPoint) -> (UUID, Int?)? {
        guard let t = transform, Preferences.shared.overlayFontSize > 0, session?.showMeasurements ?? true else { return nil }
        for m in measurements.reversed() {
            let pts = m.points.map { t.toView($0) }
            for (i, p) in pts.enumerated() where p.distance(to: v) < 7 { return (m.id, i) }
            if let r = overlay.labelRects[m.id], r.insetBy(dx: -3, dy: -3).contains(v) { return (m.id, nil) }
            let outline = (m.kind.isArea ? MeasurementCalculator.outline(m) : m.points).map { t.toView($0) }
            let closed = m.kind.isArea
            for i in 0..<max(0, outline.count - (closed ? 0 : 1)) {
                let a = outline[i], b = outline[(i + 1) % outline.count]
                if v.distance(toSegment: a, b) < 5 { return (m.id, nil) }
            }
        }
        return nil
    }

    func editText(of id: UUID) {
        guard let m = measurements.first(where: { $0.id == id }) else { return }
        promptText(title: "Edit text", initial: m.text) { [weak self] text in
            guard let self, let text, var list = self.measurements as [Measurement]?, let i = list.firstIndex(where: { $0.id == id }) else { return }
            list[i].text = text
            self.measurements = list
        }
    }

    func promptText(title: String, initial: String, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if let w = window {
            alert.beginSheetModal(for: w) { r in completion(r == .alertFirstButtonReturn ? field.stringValue : nil) }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    // MARK: - Context menu

    func showContextMenu(_ e: NSEvent) {
        session?.activate(self)
        guard let menu = session?.contextMenu(for: self) else { return }
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDropTarget = true
        return sender.draggingPasteboard.types?.contains(.speculaSeries) == true ? .move : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isDropTarget = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        let pb = sender.draggingPasteboard
        if let id = pb.string(forType: .speculaSeries) {
            session?.showSeries(id: id, in: self)
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            session?.open(urls: urls)
            return true
        }
        return false
    }
}
