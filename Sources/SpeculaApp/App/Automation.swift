import AppKit
import DICOMCore

#if DEBUG
/// Debug-only remote control used for automated UI verification.
/// Commands arrive as distributed notifications named "app.specula.automation" with object = command string.
enum Automation {
    static func install() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("app.specula.automation"), object: nil, queue: .main) { n in
            guard let cmd = n.object as? String else { return }
            let reply = run(cmd)
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("app.specula.automation.reply"), object: reply, userInfo: nil, deliverImmediately: true)
        }
    }

    static var controller: ViewerWindowController? { (NSApp.keyWindow?.windowController as? ViewerWindowController) ?? ViewerWindowController.all.last }

    static func findMenuItem(_ path: [String], in menu: NSMenu?) -> NSMenuItem? {
        guard let menu, let first = path.first else { return nil }
        func title(_ i: NSMenuItem) -> String { i.title.isEmpty ? (i.submenu?.title ?? "") : i.title }
        guard let item = menu.items.first(where: { title($0).caseInsensitiveCompare(first) == .orderedSame }) ?? menu.items.first(where: { title($0).hasPrefix(first) }) else { return nil }
        if path.count == 1 { return item }
        item.submenu?.update()
        return findMenuItem(Array(path.dropFirst()), in: item.submenu)
    }

    static func run(_ cmd: String) -> String {
        let parts = cmd.split(separator: " ").map(String.init)
        guard let op = parts.first else { return "empty" }
        let args = Array(parts.dropFirst())
        let wc = controller
        let s = wc?.session
        switch op {
        case "menu":
            let path = args.joined(separator: " ").components(separatedBy: "/")
            guard let item = findMenuItem(path, in: NSApp.mainMenu), let action = item.action else { return "no menu item \(path)" }
            wc?.window?.makeFirstResponder(s?.active)
            var target: AnyObject? = item.target
            if target == nil, let w = wc, w.responds(to: action) { target = w }
            if target == nil, let d = NSApp.delegate as? NSObject, d.responds(to: action) { target = d }
            return NSApp.sendAction(action, to: target, from: item) ? "ok" : "not handled"
        case "series":
            guard let s, let i = Int(args.first ?? ""), let series = s.collection.allSeries[safe: i] else { return "bad series" }
            if args.count > 1, let p = Int(args[1]), let v = s.viewports[safe: p] { s.show(series, in: v) } else { s.show(series) }
            return "ok \(series.seriesDescription)"
        case "list":
            return s?.collection.allSeries.enumerated().map { "\($0.offset): \($0.element.modality) \($0.element.seriesDescription) (\($0.element.imageCount))" }.joined(separator: "\n") ?? ""
        case "layout":
            s?.setLayout(rows: Int(args[safe: 0] ?? "1") ?? 1, columns: Int(args[safe: 1] ?? "1") ?? 1)
            return "ok"
        case "activate":
            if let i = Int(args.first ?? ""), let v = s?.viewports[safe: i] { s?.activate(v) }
            return "ok"
        case "tool":
            if let t = Tool(rawValue: args.first ?? "") { s?.tool = t }
            return "ok"
        case "index":
            if let v = s?.active, let i = Int(args.first ?? "") { v.state.setIndex(i); s?.viewportImageChanged(v.state) }
            return "ok \(s?.active?.state.index ?? -1)"
        case "step":
            s?.active?.step(Int(args.first ?? "1") ?? 1)
            return "ok \(s?.active?.state.index ?? -1)"
        case "window":
            guard let v = s?.active else { return "no viewport" }
            v.state.display.windowCenter = Double(args[safe: 0] ?? "") ?? v.state.display.windowCenter
            v.state.display.windowWidth = Double(args[safe: 1] ?? "") ?? v.state.display.windowWidth
            v.needsRedraw()
            return "ok"
        case "measure":
            // measure <kind> x1 y1 x2 y2 ... (image pixel coordinates)
            guard let v = s?.active, let k = MeasurementKind(rawValue: args.first ?? "") else { return "bad kind" }
            let nums = args.dropFirst().compactMap(Double.init)
            var pts: [CGPoint] = []
            var i = 0
            while i + 1 < nums.count { pts.append(CGPoint(x: nums[i], y: nums[i + 1])); i += 2 }
            var m = Measurement(kind: k, points: pts)
            m.style.color = Preferences.shared.measurementColor
            if k == .text || k == .arrow { m.text = "Note" }
            v.measurements.append(m)
            s?.measurementsChanged()
            return MeasurementCalculator.describe(m, ref: v.state.current, frame: v.frame2D, calibration: nil).joined(separator: " | ")
        case "drag":
            // drag x1 y1 x2 y2 [button] [modifiers] in view coordinates of the active viewport
            guard let v = s?.active, args.count >= 4, let w = v.window else { return "bad drag" }
            let nums = args.prefix(4).compactMap(Double.init)
            let button = Int(args[safe: 4] ?? "0") ?? 0
            var flags: NSEvent.ModifierFlags = []
            if let m = args[safe: 5] { if m.contains("opt") { flags.insert(.option) }; if m.contains("shift") { flags.insert(.shift) }; if m.contains("cmd") { flags.insert(.command) } }
            func ev(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent? {
                let p = v.convert(CGPoint(x: x, y: y), to: nil)
                return NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            let (down, drag, up): (NSEvent.EventType, NSEvent.EventType, NSEvent.EventType) = button == 1 ? (.rightMouseDown, .rightMouseDragged, .rightMouseUp) : (button == 2 ? (.otherMouseDown, .otherMouseDragged, .otherMouseUp) : (.leftMouseDown, .leftMouseDragged, .leftMouseUp))
            if let e = ev(down, nums[0], nums[1]) { button == 1 ? v.rightMouseDown(with: e) : (button == 2 ? v.otherMouseDown(with: e) : v.mouseDown(with: e)) }
            for k in 1...10 {
                let t = Double(k) / 10
                if let e = ev(drag, nums[0] + (nums[2] - nums[0]) * t, nums[1] + (nums[3] - nums[1]) * t) { button == 1 ? v.rightMouseDragged(with: e) : (button == 2 ? v.otherMouseDragged(with: e) : v.mouseDragged(with: e)) }
            }
            if let e = ev(up, nums[2], nums[3]) { button == 1 ? v.rightMouseUp(with: e) : (button == 2 ? v.otherMouseUp(with: e) : v.mouseUp(with: e)) }
            return "ok"
        case "hover":
            guard let v = s?.active, args.count >= 2 else { return "bad" }
            v.hoverPoint = CGPoint(x: Double(args[0]) ?? 0, y: Double(args[1]) ?? 0)
            v.overlay.needsDisplay = true
            return "ok"
        case "snapshot":
            guard let v = s?.active, let path = args.first, let img = v.snapshot(scale: 1) else { return "no snapshot" }
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return "encode" }
            try? png.write(to: URL(fileURLWithPath: path))
            return "ok"
        case "state":
            guard let v = s?.active else { return "none" }
            let st = v.state
            return "series=\(st.series?.seriesDescription ?? "-") index=\(st.index)/\(st.imageCount) wl=\(st.display.windowCenter) ww=\(st.display.windowWidth) zoom=\(st.display.zoom) fit=\(st.display.fitMode) tool=\(s!.tool.rawValue) measurements=\(v.measurements.count) err=\(st.loadError ?? "")"
        case "open":
            s?.open(urls: [URL(fileURLWithPath: args.joined(separator: " "))])
            return "ok"
        case "menus":
            return (NSApp.mainMenu?.items ?? []).map { "[\($0.title)|\($0.submenu?.title ?? "")] " + ($0.submenu?.items.map(\.title).joined(separator: ", ") ?? "") }.joined(separator: "\n")
        case "front":
            NSApp.activate(ignoringOtherApps: true)
            wc?.window?.makeKeyAndOrderFront(nil)
            return "ok"
        case "pacs":
            // pacs search [name] | state | select <i> | series | download <i> <library|new|separate|active> | downloads | listener
            let pw = PACSWindowController.shared
            let m = pw.model
            switch args.first {
            case "search":
                pw.showWindow(nil)
                m.query = PACSQuery()
                m.query.patientName = args.dropFirst().joined(separator: " ")
                m.search()
                return "ok"
            case "state":
                return "searching=\(m.searching) results=\(m.results.count) status=\(m.status) series=\(m.series.count) " + m.results.map { "[\($0.patientName)|\($0.studyDate)|\($0.modalities)|\($0.studyUID.suffix(8))]" }.joined(separator: " ")
            case "select":
                guard let i = Int(args[safe: 1] ?? ""), let st = m.results[safe: i] else { return "bad index" }
                m.selection = [st.id]
                return "ok"
            case "series":
                m.showSeries = true
                m.loadSeries()
                return "ok"
            case "download":
                guard let i = Int(args[safe: 1] ?? ""), let st = m.results[safe: i] else { return "bad index" }
                m.selection = [st.id]
                switch args[safe: 2] ?? "new" {
                case "library": m.download(.libraryOnly)
                case "separate": m.download(.separateWindow)
                case "active": m.addToActiveWindow()
                default: m.download(.newWindow(UUID()))
                }
                return "ok"
            case "downloads":
                return PACSService.shared.downloads.map { "[\($0.title) \($0.state.rawValue) \($0.received)/\($0.expected) \($0.bytes)B \($0.error)]" }.joined(separator: "\n")
            case "listener":
                return PACSService.shared.listenerStatus
            default:
                return "pacs ?"
            }
        case "settings":
            (NSApp.delegate as? AppDelegate)?.showSettings(nil)
            if let i = Int(args.first ?? ""), let tabs = NSApp.windows.first(where: { $0.title == "Settings" })?.contentViewController as? NSTabViewController {
                tabs.selectedTabViewItemIndex = i
            }
            return "ok"
        case "eval-windows":
            return NSApp.windows.map { w in
                let tb = w.toolbar.map { t in " toolbar=[" + t.items.map(\.label).joined(separator: ",") + "] visibleItems=\(t.visibleItems?.count ?? -1)" } ?? ""
                return "\(w.windowNumber): \(w.title) visible=\(w.isVisible) size=\(Int(w.frame.width))x\(Int(w.frame.height))" + tb
            }.joined(separator: "\n")
        default:
            return "unknown \(op)"
        }
    }
}
#endif
