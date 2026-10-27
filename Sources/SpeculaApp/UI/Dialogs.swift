import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DICOMCore

// MARK: - Custom window

enum CustomWindowSheet {
    static func present(on window: NSWindow, center: Double, width: Double, apply: @escaping (Double, Double) -> Void) {
        let a = NSAlert()
        a.messageText = "Custom Window"
        a.informativeText = "Enter a window level and width, or a minimum and maximum value."
        let mode = NSSegmentedControl(labels: ["WL / WW", "Min / Max"], trackingMode: .selectOne, target: nil, action: nil)
        mode.selectedSegment = 0
        let f1 = NSTextField(), f2 = NSTextField()
        f1.doubleValue = center; f2.doubleValue = width
        let l1 = NSTextField(labelWithString: "Window level"), l2 = NSTextField(labelWithString: "Window width")
        let grid = NSGridView(views: [[mode, NSView()], [l1, f1], [l2, f2]])
        grid.column(at: 1).width = 120
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 260, height: 90)
        let handler = ModeHandler(mode: mode, f1: f1, f2: f2, l1: l1, l2: l2)
        mode.target = handler
        mode.action = #selector(ModeHandler.changed)
        a.accessoryView = grid
        a.addButton(withTitle: "Apply")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in
            _ = handler
            guard r == .alertFirstButtonReturn else { return }
            if mode.selectedSegment == 0 { apply(f1.doubleValue, max(0.001, f2.doubleValue)) }
            else { let lo = f1.doubleValue, hi = f2.doubleValue; apply((lo + hi) / 2, max(0.001, hi - lo)) }
        }
    }

    final class ModeHandler: NSObject {
        let mode: NSSegmentedControl, f1: NSTextField, f2: NSTextField, l1: NSTextField, l2: NSTextField
        init(mode: NSSegmentedControl, f1: NSTextField, f2: NSTextField, l1: NSTextField, l2: NSTextField) {
            self.mode = mode; self.f1 = f1; self.f2 = f2; self.l1 = l1; self.l2 = l2
        }
        @objc func changed() {
            let a = f1.doubleValue, b = f2.doubleValue
            if mode.selectedSegment == 1 {
                l1.stringValue = "Minimum value"; l2.stringValue = "Maximum value"
                f1.doubleValue = a - b / 2; f2.doubleValue = a + b / 2
            } else {
                l1.stringValue = "Window level"; l2.stringValue = "Window width"
                f1.doubleValue = (a + b) / 2; f2.doubleValue = b - a
            }
        }
    }
}

// MARK: - Calibration

enum CalibrationSheet {
    static func present(for v: ViewportView, session: ViewerSession) {
        guard let window = v.window else { return }
        guard let m = v.measurements.first(where: { $0.id == v.selectedMeasurement && $0.kind == .length }) ?? v.measurements.last(where: { $0.kind == .length }),
              m.points.count >= 2 else {
            let a = NSAlert()
            a.messageText = "Length calibration"
            a.informativeText = "Draw a length measurement over an object of known size first, then choose Calibrate Length again."
            a.beginSheetModal(for: window)
            return
        }
        let px = Double(m.points[0].distance(to: m.points[1]))
        let a = NSAlert()
        a.messageText = "Length calibration"
        a.informativeText = "Enter the real distance of the selected line."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        field.doubleValue = 10
        let unit = NSPopUpButton(frame: NSRect(x: 108, y: 0, width: 140, height: 24))
        unit.addItems(withTitles: ["millimeters", "inches", "F (French)"])
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        box.addSubview(field); box.addSubview(unit)
        a.accessoryView = box
        a.addButton(withTitle: "Set")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Reset Calibration")
        a.beginSheetModal(for: window) { r in
            if r == .alertFirstButtonReturn, px > 0 {
                var mm = field.doubleValue
                if unit.indexOfSelectedItem == 1 { mm *= 25.4 }
                if unit.indexOfSelectedItem == 2 { mm /= 3 }
                session.setCalibration(mm / px, for: v)
            } else if r == .alertThirdButtonReturn {
                session.setCalibration(nil, for: v)
            }
        }
    }
}

// MARK: - Calculations

enum MeasurementCalculations {
    private static func lengths(_ session: ViewerSession) -> [Double] {
        guard let v = session.active, let r = v.state.current else { return [] }
        let sp = session.calibration(for: v).map { ($0, $0) } ?? r.instance.pixelSpacing(frame: r.frame)
        return v.measurements.filter { $0.kind == .length && $0.points.count >= 2 }.map { MeasurementCalculator.distance($0.points[0], $0.points[1], spacing: sp) }
    }

    private static func show(_ title: String, _ text: String, _ session: ViewerSession) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Copy")
        if let w = session.windowController?.window {
            a.beginSheetModal(for: w) { r in
                if r == .alertSecondButtonReturn { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            }
        }
    }

    static func lengthRatio(session: ViewerSession) {
        let l = lengths(session)
        guard l.count >= 2 else { show("Length ratio", "Draw two length measurements on the current image first.", session); return }
        let a = l[l.count - 2], b = l[l.count - 1]
        show("Length ratio", String(format: "A = %.2f mm\nB = %.2f mm\n\nA:B = %.3f\nB:A = %.3f", a, b, a / b, b / a), session)
    }

    static func ellipsoidVolume(session: ViewerSession) {
        // Lengths may come from several panels (e.g. axial + coronal); use the last three anywhere visible.
        var all: [Double] = []
        for v in session.viewports {
            guard let r = v.state.current else { continue }
            let sp = session.calibration(for: v).map { ($0, $0) } ?? r.instance.pixelSpacing(frame: r.frame)
            all += v.measurements.filter { $0.kind == .length && $0.points.count >= 2 }.map { MeasurementCalculator.distance($0.points[0], $0.points[1], spacing: sp) }
        }
        guard all.count >= 3 else { show("Ellipsoid / bullet volume", "Draw three length measurements (length, width and height) first.", session); return }
        let l = all[all.count - 3] / 10, w = all[all.count - 2] / 10, h = all[all.count - 1] / 10
        let ell = l * w * h * .pi / 6, bullet = l * w * h * 5 * .pi / 24
        show("Ellipsoid / bullet volume", String(format: "L = %.2f cm\nW = %.2f cm\nH = %.2f cm\n\nEllipsoid  L × W × H × π/6 = %.2f cm³\nBullet  L × W × H × 5π/24 = %.2f cm³", l, w, h, ell, bullet), session)
    }

    static func rows(session: ViewerSession) -> [[String]] {
        var out: [[String]] = [["Series", "Image", "Type", "Values"]]
        for (ref, m) in session.allMeasurements {
            let f = FrameCache.shared.cached(ref)
            let lines = MeasurementCalculator.describe(m, ref: ref, frame: f, calibration: nil)
            let series = ref.instance.string(.seriesDescription) ?? ""
            let img = ref.instance.instanceNumber.map(String.init) ?? ""
            out.append([series, img, m.kind.rawValue, lines.joined(separator: "; ")])
        }
        return out
    }

    static func copyAllAsText(session: ViewerSession) {
        let text = rows(session: session).map { $0.joined(separator: "\t") }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func exportCSV(session: ViewerSession) {
        let p = NSSavePanel()
        p.allowedContentTypes = [.commaSeparatedText]
        p.nameFieldStringValue = "Measurements.csv"
        guard let w = session.windowController?.window else { return }
        p.beginSheetModal(for: w) { r in
            guard r == .OK, let url = p.url else { return }
            let csv = rows(session: session).map { $0.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") }.joined(separator: "\n")
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Printing

enum PrintController {
    static func printImages(session: ViewerSession, all: Bool) {
        let views: [ViewportView] = all ? session.viewports.filter { $0.state.current != nil || $0.mpr != nil } : [session.active].compactMap { $0 }
        let images = views.compactMap { $0.snapshot(scale: 2) }
        guard !images.isEmpty else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        let pageSize = info.paperSize
        let printable = NSSize(width: pageSize.width - info.leftMargin - info.rightMargin, height: pageSize.height - info.topMargin - info.bottomMargin)
        let view = PrintPagesView(images: images, pageSize: printable)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        if let w = session.windowController?.window { op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
    }
}

final class PrintPagesView: NSView {
    let images: [NSImage]
    let pageSize: NSSize

    init(images: [NSImage], pageSize: NSSize) {
        self.images = images
        self.pageSize = pageSize
        super.init(frame: NSRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height * CGFloat(images.count)))
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: images.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * pageSize.height, width: pageSize.width, height: pageSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, img) in images.enumerated() {
            let page = rectForPage(i + 1)
            guard page.intersects(dirtyRect) else { continue }
            let s = img.size
            let scale = min(page.width / s.width, page.height / s.height)
            let r = NSRect(x: page.midX - s.width * scale / 2, y: page.midY - s.height * scale / 2, width: s.width * scale, height: s.height * scale)
            img.draw(in: r, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

// MARK: - DSA pixel shift

enum DSAShiftMode {
    static func begin(on v: ViewportView) {
        guard let w = v.window else { return }
        let a = NSAlert()
        a.messageText = "Manual pixel shift"
        a.informativeText = "Use the arrow keys with ⌥ to shift the mask by one pixel, or ⌥⇧ for ten pixels. Choose Done when finished."
        a.addButton(withTitle: "Done")
        v.state.subtraction.enabled = true
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.modifierFlags.contains(.option) else { return e }
            let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
            switch Int(e.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0) {
            case NSLeftArrowFunctionKey: v.state.subtraction.shift.x -= step
            case NSRightArrowFunctionKey: v.state.subtraction.shift.x += step
            case NSUpArrowFunctionKey: v.state.subtraction.shift.y -= step
            case NSDownArrowFunctionKey: v.state.subtraction.shift.y += step
            default: return e
            }
            v.needsRedraw()
            return nil
        }
        a.beginSheetModal(for: w) { _ in if let m = monitor { NSEvent.removeMonitor(m) } }
    }

    /// Finds the integer shift minimising the mean absolute difference between mask and live image.
    static func autoShift(_ v: ViewportView) {
        guard let s = v.state.series, let live = v.state.current, let maskRef = s.images[safe: v.state.subtraction.maskIndex],
              let lf = try? FrameCache.shared.decode(live), let mf = try? FrameCache.shared.decode(maskRef), !lf.isColor, !mf.isColor else { return }
        let a = lf.floatValues(), b = mf.floatValues()
        let w = lf.width, h = lf.height
        var best = (0, 0), bestErr = Double.greatestFiniteMagnitude
        let step = max(1, min(w, h) / 256)
        for dy in -8...8 {
            for dx in -8...8 {
                var err = 0.0, n = 0
                var y = 16
                while y < h - 16 {
                    var x = 16
                    while x < w - 16 {
                        let mx = x - dx, my = y - dy
                        if mx >= 0, my >= 0, mx < w, my < h {
                            err += Double(abs(a[y * w + x] - b[my * w + mx])); n += 1
                        }
                        x += step * 2
                    }
                    y += step * 2
                }
                if n > 0, err / Double(n) < bestErr { bestErr = err / Double(n); best = (dx, dy) }
            }
        }
        v.state.subtraction.enabled = true
        v.state.subtraction.shift = CGPoint(x: best.0, y: best.1)
        v.needsRedraw()
    }
}
