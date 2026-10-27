import AppKit
import DICOMCore

/// Transparent layer drawing annotations above the Metal image.
final class OverlayView: NSView {
    weak var viewport: ViewportView?
    private(set) var labelRects: [UUID: CGRect] = [:]

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static let textColor = NSColor(srgbRed: 1.0, green: 0.93, blue: 0.68, alpha: 1)
    static let highlightColor = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.38, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        drawContents(in: bounds, forExport: false)
    }

    private func attributes(size: CGFloat, color: NSColor, bold: Bool = false) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.95)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .medium)
        return [.font: font, .foregroundColor: color, .shadow: shadow]
    }

    func drawContents(in rect: CGRect, forExport: Bool) {
        guard let vp = viewport, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let session = vp.session
        labelRects.removeAll()
        let showAnnotations = vp.overrideAnnotations ?? session?.showAnnotations ?? true
        let anonymous = vp.overrideAnonymous ?? session?.hidePatientData ?? false
        let fontSize = CGFloat(Preferences.shared.overlayFontSize) * (session?.fontScale ?? 1)

        if let err = vp.state.loadError, vp.mpr == nil {
            let s = NSAttributedString(string: "This image could not be displayed\n\(err)", attributes: attributes(size: 13, color: .systemRed))
            let sz = s.size()
            s.draw(at: CGPoint(x: (rect.width - sz.width) / 2, y: (rect.height - sz.height) / 2))
        } else if vp.mpr == nil, vp.state.current != nil, vp.frame2D == nil || vp.frameRef != vp.state.current {
            if vp.frame2D == nil {
                let s = NSAttributedString(string: "Loading…", attributes: attributes(size: 13, color: .secondaryLabelColor))
                s.draw(at: CGPoint(x: rect.midX - s.size().width / 2, y: rect.midY))
            }
        }

        if let t = vp.transform {
            if session?.showCrossReference ?? true { drawReferenceLines(ctx, vp: vp, t: t) }
            vp.mprController?.drawOverlay(vp, t: t, ctx: ctx)
            if session?.showMeasurements ?? true { drawMeasurements(ctx, vp: vp, t: t, fontSize: fontSize) }
            drawCursor3D(ctx, vp: vp, t: t)
            if showAnnotations {
                if Preferences.shared.showOrientationLabels { drawOrientation(vp: vp, t: t, fontSize: fontSize + 2) }
                if Preferences.shared.showScaleBar { drawScaleBar(ctx, vp: vp, t: t, fontSize: fontSize) }
            }
        }
        if showAnnotations, vp.state.current != nil || vp.mpr != nil { drawCorners(vp: vp, rect: rect, fontSize: fontSize, anonymous: anonymous) }

        if !forExport {
            if vp.isActive && (session?.viewportCount ?? 1) > 1 {
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(2)
                ctx.stroke(rect.insetBy(dx: 1, dy: 1))
            }
            if vp.isDropTarget {
                ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
                ctx.fill(rect)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(3)
                ctx.stroke(rect.insetBy(dx: 1.5, dy: 1.5))
            }
        }
    }

    // MARK: - Corner text

    private func cornerLines(_ corner: OverlayCorner, vp: ViewportView, anonymous: Bool) -> [(String, Bool)] {
        let modality = vp.mpr?.volume.modality ?? vp.state.current?.instance.modality ?? ""
        let rows = Preferences.shared.overlay.rows(for: corner, modality: modality, cine: vp.state.cine.playing)
        var out: [(String, Bool)] = []
        var lastRow = -1
        for r in rows {
            if anonymous && r.hideWhenAnonymous { continue }
            while lastRow + 1 < r.row { out.append(("", false)); lastRow += 1 }
            lastRow = r.row
            let text: String
            if let item = r.item { text = itemText(item, vp: vp) } else {
                var parts: [String] = []
                var missing = false
                for e in r.elements {
                    if let t = e.text { parts.append(t) }
                    if let raw = e.tag {
                        let v = tagText(Tag(raw: raw), vp: vp)
                        if v.isEmpty { missing = true }
                        parts.append(v)
                    }
                }
                text = (r.hideIfMissing && missing) ? "" : parts.joined()
            }
            out.append((text, r.highlight))
        }
        while let last = out.last, last.0.isEmpty { out.removeLast() }
        return out
    }

    private func tagText(_ tag: Tag, vp: ViewportView) -> String {
        guard let inst = vp.mpr?.volume.images.first?.instance ?? vp.state.current?.instance else { return "" }
        guard let e = inst.header[tag] else { return "" }
        switch e.vr {
        case .PN: return PersonName.display(inst.header.string(tag))
        case .DA: return DICOMDate.formatDate(inst.header.string(tag))
        case .TM: return DICOMDate.formatTime(inst.header.string(tag))
        default: return inst.header.rawString(tag)?.replacingOccurrences(of: "\\", with: " ") ?? inst.header.displayValue(e)
        }
    }

    private func itemText(_ item: OverlayItem, vp: ViewportView) -> String {
        let s = vp.state
        let ref = s.current
        let inst = vp.mpr?.volume.images.first?.instance ?? ref?.instance
        let h = inst?.header
        switch item {
        case .imageNumber:
            if let m = vp.mpr { let i = m.sliceInfo; return "Im: \(i.index + 1)/\(i.count)" }
            guard s.imageCount > 0 else { return "" }
            var t = "Im: \(s.index + 1)/\(s.imageCount)"
            if let r = ref, r.instance.isMultiFrame, s.series?.instances.count ?? 0 > 1 { t += "  Fr: \(r.frame + 1)/\(r.instance.frameCount)" }
            return t
        case .seriesNumber:
            if let m = vp.mpr { return "\(m.orientation.title)" + (m.thickness > 0 ? " \(m.mode.title) \(String(format: "%.1f", m.thickness))mm" : "") }
            if let n = s.series?.number { return "Se: \(n)" }
            return ""
        case .lossy:
            guard let i = inst, i.lossy else { return "" }
            if let m = h?.string(.lossyImageCompressionMethod) { return "Lossy compression (\(m))" }
            return "Lossy compression"
        case .patientName: return PersonName.display(h?.string(.patientName))
        case .birthAndSex:
            let b = DICOMDate.formatDate(h?.string(.patientBirthDate))
            let sex = h?.string(.patientSex) ?? ""
            var age = h?.string(.patientAge) ?? ""
            if age.hasSuffix("Y") { age = String(Int(age.dropLast()) ?? 0) + "y" }
            return [b, age, sex].filter { !$0.isEmpty }.joined(separator: " ")
        case .rotation: return s.display.orientation.description
        case .mrTimes:
            guard let tr = h?.double(.repetitionTime), let te = h?.double(.echoTime) else { return "" }
            return String(format: "TR: %.1f TE: %.1f", tr, te)
        case .fieldStrength:
            guard let fs = h?.double(.magneticFieldStrength) else { return "" }
            return "FS: \(DataSet.formatDS(fs))"
        case .acquisitionDateTime:
            let d = h?.string(.acquisitionDate) ?? h?.string(.contentDate) ?? h?.string(.seriesDate) ?? h?.string(.studyDate)
            let tm = h?.string(.acquisitionTime) ?? h?.string(.contentTime) ?? h?.string(.seriesTime) ?? h?.string(.studyTime)
            return [DICOMDate.formatDate(d), DICOMDate.formatTime(tm)].filter { !$0.isEmpty }.joined(separator: " ")
        case .thicknessLocation:
            if let m = vp.mpr {
                let loc = m.center.dot(m.normal)
                return String(format: "T: %.1fmm L: %.1fmm", max(m.thickness, m.stepMM), loc)
            }
            guard let p = ref?.plane else {
                if let t = h?.double(.sliceThickness) { return String(format: "T: %.1fmm", t) }
                return ""
            }
            var parts: [String] = []
            if let t = p.thickness { parts.append(String(format: "T: %.1fmm", t)) }
            let loc = h?.double(.sliceLocation) ?? p.position.dot(p.normal)
            parts.append(String(format: "L: %.1fmm", loc))
            return parts.joined(separator: " ")
        case .positionerAngles:
            guard let a = h?.double(.positionerPrimaryAngle), let b = h?.double(.positionerSecondaryAngle) else { return "" }
            return "\(a >= 0 ? "LAO" : "RAO"): \(Int(abs(a).rounded())) \(b >= 0 ? "CRA" : "CAU"): \(Int(abs(b).rounded()))"
        case .cursorValue:
            guard let hp = vp.hoverPoint, let t = vp.transform else { return "" }
            let ip = t.toImage(hp)
            let x = Int(ip.x.rounded()), y = Int(ip.y.rounded())
            if let m = vp.mpr {
                let g = m.imagePlane
                let pp = g.patientPoint(x: ip.x, y: ip.y)
                guard x >= 0, y >= 0, x < g.columns, y < g.rows, let v = m.volume.value(atPatient: pp) else { return "" }
                return "X: \(x) Y: \(y) Val: \(DataSet.formatDS(v))\(m.volume.units.isEmpty ? "" : " " + m.volume.units)"
            }
            guard let f = vp.frame2D, let r = vp.frameRef, x >= 0, y >= 0, x < f.width, y < f.height else { return "" }
            if f.isColor, let (rr, gg, bb) = f.rgb(x: x, y: y) { return "X: \(x) Y: \(y) Val: \(rr) \(gg) \(bb)" }
            guard let v = f.storedValue(x: x, y: y) else { return "" }
            let a = r.attributes
            let mv = v * a.rescaleSlope + a.rescaleIntercept
            var text = "X: \(x) Y: \(y) Val: \(DataSet.formatDS((mv * 100).rounded() / 100))"
            let u = MeasurementCalculator.unitLabel(r)
            if !u.isEmpty { text += " " + u }
            if let suv = SUV.factor(r) { text += String(format: " SUV: %.2f", mv * suv) }
            return text
        case .window:
            let c = s.display.windowCenter, w = s.display.windowWidth
            var t = String(format: "WL: %.0f WW: %.0f", c, w)
            if abs(w) < 10 { t = String(format: "WL: %.3g WW: %.3g", c, w) }
            var tags: [String] = []
            if let n = s.display.windowName, !n.isEmpty { tags.append(n) }
            if s.display.negative { tags.append("N") }
            if !tags.isEmpty { t += " [\(tags.joined(separator: ", "))]" }
            return t
        case .fps:
            guard s.cine.playing else { return "" }
            return String(format: "%.0f fps", s.cine.measuredFPS > 0 ? s.cine.measuredFPS : s.cine.fps)
        case .tube:
            var parts: [String] = []
            if let ma = h?.double(.xRayTubeCurrent) { parts.append("\(DataSet.formatDS(ma))mA") }
            if let kv = h?.double(.kvp) { parts.append("\(DataSet.formatDS(kv))kV") }
            return parts.joined(separator: " ")
        case .cursor3D:
            guard let c = vp.session?.cursor3D else { return "" }
            return String(format: "X: %.2fmm Y: %.2fmm Z: %.2fmm", c.x, c.y, c.z)
        case .filter:
            return DisplayState.filterNames[safe: s.display.filter] ?? ""
        case .dsaMask:
            guard s.subtraction.enabled else { return "" }
            var t = "Mask: \(s.subtraction.maskIndex + 1)"
            if s.subtraction.shift != .zero { t += String(format: " Shift: %.1f, %.1f", s.subtraction.shift.x, s.subtraction.shift.y) }
            return t
        }
    }

    private func drawCorners(vp: ViewportView, rect: CGRect, fontSize: CGFloat, anonymous: Bool) {
        let margin: CGFloat = 6
        let lineH = fontSize * 1.32
        for corner in OverlayCorner.allCases {
            let lines = cornerLines(corner, vp: vp, anonymous: anonymous)
            for (i, (text, hi)) in lines.enumerated() where !text.isEmpty {
                let s = NSAttributedString(string: text, attributes: attributes(size: fontSize, color: hi ? OverlayView.highlightColor : OverlayView.textColor))
                let sz = s.size()
                var p = CGPoint.zero
                switch corner {
                case .topLeft: p = CGPoint(x: margin, y: margin + CGFloat(i) * lineH)
                case .topRight: p = CGPoint(x: rect.width - margin - sz.width, y: margin + CGFloat(i) * lineH)
                case .bottomLeft: p = CGPoint(x: margin, y: rect.height - margin - CGFloat(i + 1) * lineH)
                case .bottomRight: p = CGPoint(x: rect.width - margin - sz.width, y: rect.height - margin - CGFloat(i + 1) * lineH)
                }
                s.draw(at: p)
            }
        }
    }

    // MARK: - Orientation & scale

    private func drawOrientation(vp: ViewportView, t: ViewTransform, fontSize: CGFloat) {
        // Screen right / down directions expressed in image axes
        let inv = vp.state.display.orientation.inverse
        let right = inv.apply(CGPoint(x: 1, y: 0)), down = inv.apply(CGPoint(x: 0, y: 1))
        var labels: (String, String, String, String)? // right, left, down, up
        if let plane = vp.currentPlane {
            let r = plane.rowDirection * Double(right.x) + plane.columnDirection * Double(right.y)
            let d = plane.rowDirection * Double(down.x) + plane.columnDirection * Double(down.y)
            labels = (ImagePlane.orientationLabel(r), ImagePlane.orientationLabel(r * -1), ImagePlane.orientationLabel(d), ImagePlane.orientationLabel(d * -1))
        } else if let po = vp.state.current?.instance.header.strings(.patientOrientation), po.count == 2, !po[0].isEmpty {
            let rowL = OrientationText.normalize(po[0]), colL = OrientationText.normalize(po[1])
            func label(_ v: CGPoint) -> String {
                if v.x > 0.5 { return rowL }
                if v.x < -0.5 { return OrientationText.opposite(rowL) }
                if v.y > 0.5 { return colL }
                return OrientationText.opposite(colL)
            }
            labels = (label(right), label(CGPoint(x: -right.x, y: -right.y)), label(down), label(CGPoint(x: -down.x, y: -down.y)))
        }
        guard let l = labels else { return }
        let attrs = attributes(size: fontSize, color: OverlayView.textColor, bold: true)
        let w = bounds.width, h = bounds.height
        func draw(_ s: String, _ p: CGPoint, alignX: CGFloat, alignY: CGFloat) {
            let a = NSAttributedString(string: s, attributes: attrs)
            let sz = a.size()
            a.draw(at: CGPoint(x: p.x - sz.width * alignX, y: p.y - sz.height * alignY))
        }
        draw(l.0, CGPoint(x: w - 8, y: h / 2), alignX: 1, alignY: 0.5)
        draw(l.1, CGPoint(x: 8, y: h / 2), alignX: 0, alignY: 0.5)
        draw(l.2, CGPoint(x: w / 2, y: h - 8), alignX: 0.5, alignY: 1)
        draw(l.3, CGPoint(x: w / 2, y: 8), alignX: 0.5, alignY: 0)
    }

    private func drawScaleBar(_ ctx: CGContext, vp: ViewportView, t: ViewTransform, fontSize: CGFloat) {
        var mmPerPoint: Double?
        if let m = vp.mpr { mmPerPoint = m.pixelSize / Double(t.zoom) }
        else if let r = vp.state.current, let sp = r.instance.pixelSpacing(frame: r.frame) { mmPerPoint = sp.1 / Double(t.zoom) }
        guard let mpp = mmPerPoint, mpp > 0 else { return }
        let target = Double(bounds.height) * 0.3 * mpp
        let nice: [Double] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000]
        guard let len = nice.last(where: { $0 <= target }) else { return }
        let pts = CGFloat(len / mpp)
        let x = bounds.width - (Preferences.shared.showOrientationLabels ? 30 : 10), y0 = bounds.height / 2 - pts / 2
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 2, color: NSColor.black.cgColor)
        ctx.setStrokeColor(OverlayView.textColor.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: x, y: y0)); ctx.addLine(to: CGPoint(x: x, y: y0 + pts))
        let ticks = len >= 100 ? Int(len / 10) : Int(len)
        let tickStep = pts / CGFloat(max(1, ticks))
        if tickStep >= 3 {
            for i in 0...ticks {
                let big = len >= 100 ? i % 5 == 0 : i % 5 == 0 || i == ticks
                ctx.move(to: CGPoint(x: x, y: y0 + CGFloat(i) * tickStep))
                ctx.addLine(to: CGPoint(x: x - (big ? 7 : 4), y: y0 + CGFloat(i) * tickStep))
            }
        } else {
            ctx.move(to: CGPoint(x: x, y: y0)); ctx.addLine(to: CGPoint(x: x - 7, y: y0))
            ctx.move(to: CGPoint(x: x, y: y0 + pts)); ctx.addLine(to: CGPoint(x: x - 7, y: y0 + pts))
        }
        ctx.strokePath()
        ctx.restoreGState()
        let label = len >= 10 ? "\(Int(len / 10)) cm" : "\(Int(len)) mm"
        let s = NSAttributedString(string: label, attributes: attributes(size: fontSize - 1, color: OverlayView.textColor))
        s.draw(at: CGPoint(x: x - 10 - s.size().width, y: y0 + pts + 2))
    }

    // MARK: - Reference lines & 3D cursor

    private func drawReferenceLines(_ ctx: CGContext, vp: ViewportView, t: ViewTransform) {
        guard let plane = vp.currentPlane, let session = vp.session, vp.mpr == nil else { return }
        for (other, isActive) in session.referencePlanes(excluding: vp) {
            guard let (a, b) = plane.intersection(with: other) else { continue }
            let pa = t.toView(a), pb = t.toView(b)
            ctx.saveGState()
            ctx.setStrokeColor((isActive ? NSColor.systemYellow : NSColor.systemYellow.withAlphaComponent(0.45)).cgColor)
            ctx.setLineWidth(isActive ? 1.5 : 1)
            if !isActive { ctx.setLineDash(phase: 0, lengths: [6, 4]) }
            ctx.move(to: pa); ctx.addLine(to: pb)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func drawCursor3D(_ ctx: CGContext, vp: ViewportView, t: ViewTransform) {
        guard let c = vp.session?.cursor3D, let plane = vp.currentPlane, vp.mpr == nil else { return }
        let px = plane.pixel(of: c)
        let tol = max(plane.thickness ?? 0, 1.5) / 2 + 0.5
        guard abs(px.distance) <= tol else { return }
        let v = t.toView(CGPoint(x: px.x, y: px.y))
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemGreen.cgColor)
        ctx.setLineWidth(1.5)
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            ctx.move(to: CGPoint(x: v.x + 4 * dx, y: v.y + 4 * dy))
            ctx.addLine(to: CGPoint(x: v.x + 14 * dx, y: v.y + 14 * dy))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Measurements

    private func drawMeasurements(_ ctx: CGContext, vp: ViewportView, t: ViewTransform, fontSize: CGFloat) {
        var list = vp.measurements
        if let d = vp.draft { list.append(d) }
        let calibration = vp.session?.calibration(for: vp)
        for m in list {
            let selected = m.id == vp.selectedMeasurement
            let color = m.style.color.nsColor
            let pts = m.points.map { t.toView($0) }
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 1.5, color: NSColor.black.withAlphaComponent(0.9).cgColor)
            ctx.setStrokeColor(color.cgColor)
            ctx.setFillColor(color.cgColor)
            ctx.setLineWidth(m.style.lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            var labelAnchor = pts.last ?? .zero
            switch m.kind {
            case .length:
                guard pts.count >= 2 else { break }
                ctx.move(to: pts[0]); ctx.addLine(to: pts[1]); ctx.strokePath()
                drawTicks(ctx, pts[0], pts[1])
                if Preferences.shared.lengthMidMark {
                    let mid = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
                    drawTick(ctx, at: mid, along: pts[1] - pts[0], size: 6)
                }
                labelAnchor = pts[1].y > pts[0].y ? pts[1] : pts[0]
            case .arrow:
                guard pts.count >= 2 else { break }
                ctx.move(to: pts[1]); ctx.addLine(to: pts[0]); ctx.strokePath()
                let dir = pts[1] - pts[0]
                let l = max(dir.length, 0.001)
                let ux = dir.x / l, uy = dir.y / l
                let s: CGFloat = 12
                ctx.move(to: pts[0])
                ctx.addLine(to: CGPoint(x: pts[0].x + s * ux - s * 0.45 * uy, y: pts[0].y + s * uy + s * 0.45 * ux))
                ctx.addLine(to: CGPoint(x: pts[0].x + s * ux + s * 0.45 * uy, y: pts[0].y + s * uy - s * 0.45 * ux))
                ctx.closePath(); ctx.fillPath()
                labelAnchor = pts[1]
            case .angle:
                guard pts.count >= 2 else { break }
                ctx.move(to: pts[0]); ctx.addLine(to: pts[1])
                if pts.count >= 3 { ctx.addLine(to: pts[2]) }
                ctx.strokePath()
                if pts.count >= 3 {
                    let a1 = atan2(pts[0].y - pts[1].y, pts[0].x - pts[1].x), a2 = atan2(pts[2].y - pts[1].y, pts[2].x - pts[1].x)
                    var d = a2 - a1
                    while d > .pi { d -= 2 * .pi }
                    while d < -.pi { d += 2 * .pi }
                    let r = min(24, min(pts[0].distance(to: pts[1]), pts[2].distance(to: pts[1])) * 0.4)
                    ctx.addArc(center: pts[1], radius: r, startAngle: a1, endAngle: a1 + d, clockwise: d < 0)
                    ctx.strokePath()
                }
                labelAnchor = pts[1]
            case .cobbAngle:
                if pts.count >= 2 { ctx.move(to: pts[0]); ctx.addLine(to: pts[1]) }
                if pts.count >= 4 { ctx.move(to: pts[2]); ctx.addLine(to: pts[3]) }
                ctx.strokePath()
                if pts.count >= 4 {
                    let m1 = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
                    let m2 = CGPoint(x: (pts[2].x + pts[3].x) / 2, y: (pts[2].y + pts[3].y) / 2)
                    ctx.setLineDash(phase: 0, lengths: [4, 4])
                    ctx.move(to: m1); ctx.addLine(to: m2); ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                    labelAnchor = CGPoint(x: (m1.x + m2.x) / 2, y: (m1.y + m2.y) / 2)
                }
            case .deviation:
                if pts.count >= 2 { ctx.move(to: pts[0]); ctx.addLine(to: pts[1]); ctx.strokePath() }
                if pts.count >= 3 {
                    let a = pts[0], b = pts[1], p = pts[2]
                    let ab = b - a, l2 = max(ab.x * ab.x + ab.y * ab.y, 1e-6)
                    let tt = ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / l2
                    let foot = a + ab * tt
                    ctx.setLineDash(phase: 0, lengths: [4, 3])
                    ctx.move(to: p); ctx.addLine(to: foot); ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                    ctx.fillEllipse(in: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5))
                    labelAnchor = p
                }
            case .ellipse, .rectangle, .closedPolygon, .pencil:
                let outline = MeasurementCalculator.outline(m).map { t.toView($0) }
                guard outline.count >= 2 else { break }
                ctx.move(to: outline[0])
                for p in outline.dropFirst() { ctx.addLine(to: p) }
                let closed = m.kind != .closedPolygon || vp.draft?.id != m.id
                if closed { ctx.closePath() }
                ctx.strokePath()
                if m.kind == .ellipse, Preferences.shared.ellipseCenterMark, pts.count >= 2 {
                    let c = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
                    ctx.move(to: CGPoint(x: c.x - 4, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 4, y: c.y))
                    ctx.move(to: CGPoint(x: c.x, y: c.y - 4)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 4))
                    ctx.strokePath()
                }
                labelAnchor = CGPoint(x: outline.map(\.x).max() ?? 0, y: outline.map(\.y).min() ?? 0)
            case .openPolygon:
                guard pts.count >= 2 else { break }
                ctx.move(to: pts[0])
                for p in pts.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            case .text:
                labelAnchor = pts.first ?? .zero
            case .probe:
                guard let p = pts.first else { break }
                ctx.move(to: CGPoint(x: p.x - 6, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + 6, y: p.y))
                ctx.move(to: CGPoint(x: p.x, y: p.y - 6)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + 6))
                ctx.strokePath()
            }
            ctx.restoreGState()

            if selected {
                ctx.saveGState()
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.setLineWidth(1)
                for p in pts {
                    let r = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                    ctx.fill(r); ctx.stroke(r)
                }
                ctx.restoreGState()
            }

            // Label
            let ref = vp.mpr == nil ? vp.state.current : nil
            let lines: [String]
            if let mpr = vp.mpr {
                lines = vp.mprController?.describe(m, plane: mpr) ?? []
            } else {
                lines = MeasurementCalculator.describe(m, ref: ref, frame: vp.frame2D, calibration: calibration)
            }
            guard !lines.isEmpty else { continue }
            let attrs = attributes(size: m.kind == .text ? m.style.fontSize + 1 : fontSize, color: color, bold: m.kind == .text)
            let text = NSAttributedString(string: lines.joined(separator: "\n"), attributes: attrs)
            let sz = text.size()
            var origin = CGPoint(x: labelAnchor.x + (m.kind == .text ? 0 : m.labelOffset.x), y: labelAnchor.y + (m.kind == .text ? -sz.height / 2 : m.labelOffset.y))
            origin.x = min(max(4, origin.x), bounds.width - sz.width - 4)
            origin.y = min(max(4, origin.y), bounds.height - sz.height - 4)
            let r = CGRect(origin: origin, size: sz)
            if m.kind == .text || selected {
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
                ctx.fill(r.insetBy(dx: -3, dy: -2))
            }
            text.draw(at: origin)
            labelRects[m.id] = r
        }
    }

    private func drawTicks(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint) {
        drawTick(ctx, at: a, along: b - a, size: 5)
        drawTick(ctx, at: b, along: b - a, size: 5)
    }

    private func drawTick(_ ctx: CGContext, at p: CGPoint, along d: CGPoint, size: CGFloat) {
        let l = max(d.length, 0.001)
        let nx = -d.y / l * size, ny = d.x / l * size
        ctx.move(to: CGPoint(x: p.x - nx, y: p.y - ny)); ctx.addLine(to: CGPoint(x: p.x + nx, y: p.y + ny))
        ctx.strokePath()
    }
}
