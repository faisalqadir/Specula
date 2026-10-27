import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import DICOMCore

/// Content area: viewport grid + slim status bar.
final class ViewerContentViewController: NSViewController {
    let session: ViewerSession
    private var bag = Set<AnyCancellable>()

    init(session: ViewerSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        let grid = session.gridView
        grid.translatesAutoresizingMaskIntoConstraints = false
        let status = NSHostingView(rootView: StatusBarView(session: session))
        status.translatesAutoresizingMaskIntoConstraints = false
        let empty = NSHostingView(rootView: EmptyStateView(session: session))
        empty.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)
        root.addSubview(empty)
        root.addSubview(status)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor), grid.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            grid.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor), grid.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor), status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor), status.heightAnchor.constraint(equalToConstant: 24),
            empty.centerXAnchor.constraint(equalTo: grid.centerXAnchor), empty.centerYAnchor.constraint(equalTo: grid.centerYAnchor),
        ])
        session.collection.objectWillChange.receive(on: RunLoop.main).sink { [weak empty, weak session] in
            DispatchQueue.main.async { empty?.isHidden = !(session?.collection.isEmpty ?? true) }
        }.store(in: &bag)
        view = root
    }
}

final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    let session: ViewerSession
    private var splitVC: NSSplitViewController!
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var bag = Set<AnyCancellable>()
    private weak var toolGroup: NSToolbarItemGroup?
    private weak var measureItem: NSMenuToolbarItem?
    private weak var cineItem: NSToolbarItem?
    var lastMeasureTool: Tool = .length

    static var all: [ViewerWindowController] = []

    init(session: ViewerSession = ViewerSession()) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Specula"
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("SpeculaViewer")
        window.tabbingMode = .preferred
        window.minSize = NSSize(width: 720, height: 480)
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)
        session.windowController = self
        window.delegate = self

        splitVC = NSSplitViewController()
        let sidebarVC = NSHostingController(rootView: SidebarView(session: session))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 380
        sidebarItem.canCollapse = true
        let content = NSSplitViewItem(viewController: ViewerContentViewController(session: session))
        content.minimumThickness = 400
        let inspectorVC = NSHostingController(rootView: InspectorView(session: session))
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorVC)
        inspectorItem.minimumThickness = 250
        inspectorItem.maximumThickness = 360
        inspectorItem.isCollapsed = true
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(content)
        splitVC.addSplitViewItem(inspectorItem)
        splitVC.splitView.autosaveName = "SpeculaSplit"
        window.contentViewController = splitVC
        window.setContentSize(NSSize(width: 1440, height: 900))

        let toolbar = NSToolbar(identifier: "SpeculaViewerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.center()

        session.$tool.sink { [weak self] t in self?.syncToolUI(t) }.store(in: &bag)
        NotificationCenter.default.publisher(for: .cineStateChanged, object: session).sink { [weak self] _ in self?.updateCineItem() }.store(in: &bag)
        NotificationCenter.default.publisher(for: .activeViewportChanged, object: session).sink { [weak self] _ in self?.updateTitle(); self?.updateCineItem() }.store(in: &bag)
        ViewerWindowController.all.append(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        session.cancelLoading()
        ViewerWindowController.all.removeAll { $0 === self }
        if ViewerWindowController.all.isEmpty { FrameCache.shared.purge(); MetalContext.shared.purgeTextures() }
    }

    func updateTitle() {
        guard let w = window else { return }
        let study = session.activeState?.series?.study ?? session.collection.studies.first
        if let st = study {
            w.title = session.hidePatientData ? "Specula" : (st.patientName.isEmpty ? "Unnamed patient" : st.patientName)
            var sub: [String] = []
            if !st.studyDescription.isEmpty { sub.append(st.studyDescription) }
            let d = DICOMDate.formatDate(st.studyDate)
            if !d.isEmpty { sub.append(d) }
            if !st.modalities.isEmpty { sub.append(st.modalities) }
            w.subtitle = sub.joined(separator: " · ")
        } else {
            w.title = "Specula"
            w.subtitle = ""
        }
    }

    // MARK: - Toolbar

    private enum TB {
        static let open = NSToolbarItem.Identifier("open")
        static let tools = NSToolbarItem.Identifier("tools")
        static let measure = NSToolbarItem.Identifier("measure")
        static let layout = NSToolbarItem.Identifier("layout")
        static let window = NSToolbarItem.Identifier("windowPresets")
        static let transform = NSToolbarItem.Identifier("transform")
        static let cine = NSToolbarItem.Identifier("cine")
        static let sync = NSToolbarItem.Identifier("sync")
        static let annotations = NSToolbarItem.Identifier("annotations")
        static let advanced = NSToolbarItem.Identifier("advanced")
        static let export = NSToolbarItem.Identifier("export")
        static let inspector = NSToolbarItem.Identifier("inspectorToggle")
        static let library = NSToolbarItem.Identifier("library")
        static let pacs = NSToolbarItem.Identifier("pacs")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, TB.open, TB.tools, TB.measure, .space, TB.window, TB.transform, TB.layout, .flexibleSpace,
         TB.cine, TB.sync, TB.annotations, TB.advanced, TB.export, .inspectorTrackingSeparator, TB.inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [TB.library, TB.pacs, .flexibleSpace, .space]
    }

    private func symbol(_ name: String, _ desc: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: desc) ?? NSImage()
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case TB.open:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Open"
            item.toolTip = "Open DICOM files, folders, ZIP archives or discs"
            item.image = symbol("folder", "Open")
            item.menu = makeOpenMenu()
            item.showsIndicator = true
            item.target = self
            item.action = #selector(openDocument(_:))
            return item
        case TB.tools:
            let tools = Tool.navigation
            let group = NSToolbarItemGroup(itemIdentifier: id, images: tools.map { symbol($0.symbol, $0.title) }, selectionMode: .selectOne,
                                           labels: tools.map(\.title), target: self, action: #selector(toolGroupChanged(_:)))
            group.label = "Tools"
            group.selectedIndex = 0
            group.controlRepresentation = .expanded
            for (i, sub) in group.subitems.enumerated() { sub.toolTip = tools[i].title + ["  (B)", "  (W)", "  (P)", "  (Z)"][i] }
            toolGroup = group
            return group
        case TB.measure:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Measure"
            item.toolTip = "Measurements and annotations"
            item.image = symbol(lastMeasureTool.symbol, "Measure")
            item.menu = makeMeasureMenu()
            item.target = self
            item.action = #selector(selectLastMeasureTool(_:))
            measureItem = item
            return item
        case TB.layout:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Layout"
            item.toolTip = "Split screen"
            item.image = symbol("square.grid.2x2", "Layout")
            item.menu = makeLayoutMenu()
            return item
        case TB.window:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Window"
            item.toolTip = "Window presets (brightness / contrast)"
            item.image = symbol("circle.lefthalf.filled.righthalf.striped.horizontal", "Window presets")
            item.menu = makePresetMenu()
            item.menu.delegate = self
            return item
        case TB.transform:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Rotate"
            item.toolTip = "Rotate and flip"
            item.image = symbol("rotate.right", "Rotate")
            item.target = self
            item.action = #selector(rotateCW(_:))
            let m = NSMenu()
            m.addItem(withTitle: "Rotate 90° Clockwise", action: #selector(rotateCW(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Rotate 90° Counterclockwise", action: #selector(rotateCCW(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Rotate 180°", action: #selector(rotate180(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Flip Horizontal", action: #selector(flipHorizontal(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Flip Vertical", action: #selector(flipVertical(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Clear Transformations", action: #selector(clearTransformations(_:)), keyEquivalent: "")
            item.menu = m
            return item
        case TB.cine:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Cine"
            item.toolTip = "Play / pause cine (Space)"
            item.image = symbol("play.fill", "Play")
            item.target = self
            item.action = #selector(toggleCine(_:))
            item.isBordered = true
            cineItem = item
            return item
        case TB.sync:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Sync"
            item.toolTip = "Synchronize series (slice position, zoom & pan)"
            item.image = symbol("link", "Sync")
            item.target = self
            item.action = #selector(toggleSync(_:))
            item.isBordered = true
            return item
        case TB.annotations:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Annotations"
            item.toolTip = "Toggle annotations"
            item.image = symbol("textformat.size", "Annotations")
            item.target = self
            item.action = #selector(toggleAnnotations(_:))
            item.isBordered = true
            return item
        case TB.advanced:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "3D"
            item.toolTip = "MPR, volume rendering, fusion and subtraction"
            item.image = symbol("cube.transparent", "3D")
            item.target = self
            item.action = #selector(openMPR(_:))
            let m = NSMenu()
            m.addItem(withTitle: "3D MPR", action: #selector(openMPR(_:)), keyEquivalent: "")
            m.addItem(withTitle: "3D Volume Rendering", action: #selector(openVR(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "PET-CT Fusion…", action: #selector(openFusion(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Subtraction (DSA)", action: #selector(toggleSubtraction(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Time-Intensity Curve…", action: #selector(timeIntensityCurve(_:)), keyEquivalent: "")
            item.menu = m
            return item
        case TB.export:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Export"
            item.toolTip = "Export, copy, print or share images"
            item.image = symbol("square.and.arrow.up", "Export")
            item.target = self
            item.action = #selector(exportImages(_:))
            let m = NSMenu()
            m.addItem(withTitle: "Export Images…", action: #selector(exportImages(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Copy Image", action: #selector(copyImage(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Share…", action: #selector(shareImage(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Print…", action: #selector(printImage(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Anonymize…", action: #selector(anonymize(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Send to PACS…", action: #selector(sendToPACS(_:)), keyEquivalent: "")
            item.menu = m
            return item
        case TB.inspector:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Inspector"
            item.toolTip = "Show or hide the inspector"
            item.image = symbol("sidebar.trailing", "Inspector")
            item.target = self
            item.action = #selector(toggleInspector(_:))
            return item
        case TB.library:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Library"
            item.image = symbol("books.vertical", "Library")
            item.action = #selector(AppDelegate.showLibrary(_:))
            return item
        case TB.pacs:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "PACS"
            item.image = symbol("network", "PACS")
            item.action = #selector(AppDelegate.showPACS(_:))
            return item
        default:
            return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case TB.sync:
            item.image = symbol(session.syncMode == .disabled ? "link.badge.plus" : "link", "Sync")
        case TB.annotations:
            item.image = symbol(session.showAnnotations ? "textformat.size" : "textformat.size.smaller", "Annotations")
        default: break
        }
        return true
    }

    private func syncToolUI(_ t: Tool) {
        if let i = Tool.navigation.firstIndex(of: t) { toolGroup?.selectedIndex = i } else { toolGroup?.setSelected(false, at: toolGroup?.selectedIndex ?? 0) }
        if t.isMeasurement {
            lastMeasureTool = t
            measureItem?.image = symbol(t.symbol, t.title)
        }
    }

    private func updateCineItem() {
        let playing = session.activeState?.cine.playing ?? false
        cineItem?.image = symbol(playing ? "pause.fill" : "play.fill", playing ? "Pause" : "Play")
    }

    @objc func toolGroupChanged(_ sender: NSToolbarItemGroup) {
        session.tool = Tool.navigation[safe: sender.selectedIndex] ?? .browse
    }

    @objc func selectLastMeasureTool(_ sender: Any?) { session.tool = lastMeasureTool }

    @objc func selectTool(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let t = Tool(rawValue: raw) { session.tool = t }
    }

    func makeOpenMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Open Files or Folder…", action: #selector(openDocument(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Open ZIP Archive…", action: #selector(openZip(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Open CD/DVD…", action: #selector(openDisc(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Local Library", action: #selector(AppDelegate.showLibrary(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Search PACS…", action: #selector(AppDelegate.showPACS(_:)), keyEquivalent: "")
        return m
    }

    func makeMeasureMenu() -> NSMenu {
        let m = NSMenu()
        for t in Tool.measurements {
            let i = NSMenuItem(title: t.title, action: #selector(selectTool(_:)), keyEquivalent: "")
            i.image = symbol(t.symbol, t.title)
            i.representedObject = t.rawValue
            m.addItem(i)
            if t == .deviation || t == .pencil { m.addItem(.separator()) }
        }
        m.addItem(.separator())
        let c = NSMenuItem(title: "3D Cursor", action: #selector(selectTool(_:)), keyEquivalent: "")
        c.image = symbol(Tool.cursor3D.symbol, "3D Cursor")
        c.representedObject = Tool.cursor3D.rawValue
        m.addItem(c)
        m.addItem(withTitle: "Calibrate Length…", action: #selector(calibrate(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Length Ratio", action: #selector(lengthRatio(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Ellipsoid / Bullet Volume", action: #selector(ellipsoidVolume(_:)), keyEquivalent: "")
        return m
    }

    func makeLayoutMenu() -> NSMenu {
        let m = NSMenu()
        let layouts: [(Int, Int)] = [(1, 1), (1, 2), (2, 1), (2, 2), (1, 3), (2, 3), (3, 3), (3, 4), (4, 4)]
        for (r, c) in layouts {
            let i = NSMenuItem(title: "\(r) × \(c)", action: #selector(setLayoutFromMenu(_:)), keyEquivalent: "")
            i.representedObject = [r, c]
            i.image = LayoutIcon.make(rows: r, cols: c)
            m.addItem(i)
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Custom…", action: #selector(customLayout(_:)), keyEquivalent: "")
        return m
    }

    func makePresetMenu() -> NSMenu {
        let m = NSMenu(title: "Window")
        m.delegate = self
        rebuildPresetMenu(m)
        return m
    }

    fileprivate func rebuildPresetMenu(_ m: NSMenu) {
        m.removeAllItems()
        m.addItem(withTitle: "Default Window  (1)", action: #selector(defaultWindow(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Full Dynamic  (0)", action: #selector(fullDynamic(_:)), keyEquivalent: "")
        m.addItem(.separator())
        let modality = session.activeState?.series?.modality ?? "CT"
        for p in WindowPreset.presets(for: modality) {
            let i = NSMenuItem(title: "\(p.name)  (\(Int(p.center)) / \(Int(p.width)))" + (p.key.map { "  (\($0))" } ?? ""), action: #selector(applyPresetItem(_:)), keyEquivalent: "")
            i.representedObject = p.id
            m.addItem(i)
        }
        if let explanations = session.activeState?.current?.attributes.windowCenters, explanations.count > 1, let r = session.activeState?.current {
            m.addItem(.separator())
            for (k, c) in explanations.enumerated() {
                let w = r.attributes.windowWidths[safe: k] ?? 0
                let name = r.instance.windowExplanations[safe: k] ?? "Window \(k + 1)"
                let i = NSMenuItem(title: "\(name)  (\(Int(c)) / \(Int(w)))", action: #selector(applyFileWindow(_:)), keyEquivalent: "")
                i.tag = k
                m.addItem(i)
            }
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Custom Window…", action: #selector(customWindow(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Negative", action: #selector(toggleNegative(_:)), keyEquivalent: "")
        let cm = NSMenuItem(title: "Color Map", action: nil, keyEquivalent: "")
        let cmm = NSMenu()
        for c in Colormap.allCases {
            let i = NSMenuItem(title: c.title, action: #selector(setColormap(_:)), keyEquivalent: "")
            i.representedObject = c.rawValue
            cmm.addItem(i)
        }
        cm.submenu = cmm
        m.addItem(cm)
    }

    // MARK: - Actions: opening

    @objc func openDocument(_ sender: Any?) {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.message = "Choose DICOM files, folders, DICOMDIR or ZIP archives"
        p.prompt = "Open"
        p.beginSheetModal(for: window!) { [weak self] r in
            if r == .OK { self?.session.open(urls: p.urls) }
        }
    }

    @objc func openZip(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType.zip]
        p.allowsMultipleSelection = true
        p.beginSheetModal(for: window!) { [weak self] r in if r == .OK { self?.session.open(urls: p.urls) } }
    }

    @objc func openDisc(_ sender: Any?) {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey], options: [.skipHiddenVolumes]) ?? []
        let removable = volumes.filter { u in
            let v = try? u.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey])
            return v?.volumeIsRemovable == true || v?.volumeIsEjectable == true
        }
        if let disc = removable.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("DICOMDIR").path) }) ?? removable.first {
            session.open(urls: [disc])
        } else {
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.directoryURL = URL(fileURLWithPath: "/Volumes")
            p.message = "No disc was found. Choose the disc or folder that contains DICOMDIR"
            p.beginSheetModal(for: window!) { [weak self] r in if r == .OK { self?.session.open(urls: p.urls) } }
        }
    }

    // MARK: - Actions: tools / display

    @objc func setLayoutFromMenu(_ sender: NSMenuItem) {
        guard let rc = sender.representedObject as? [Int], rc.count == 2 else { return }
        session.setLayout(rows: rc[0], columns: rc[1])
    }

    @objc func customLayout(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "Split screen"
        a.informativeText = "Rows and columns (1–6)"
        let rows = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 24)), cols = NSTextField(frame: NSRect(x: 70, y: 0, width: 60, height: 24))
        rows.integerValue = session.layout.rows; cols.integerValue = session.layout.columns
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 130, height: 24))
        box.addSubview(rows); box.addSubview(cols)
        a.accessoryView = box
        a.addButton(withTitle: "Apply"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window!) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.session.setLayout(rows: rows.integerValue, columns: cols.integerValue) }
        }
    }

    @objc func applyPresetItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let m = session.activeState?.series?.modality,
              let p = WindowPreset.presets(for: m).first(where: { $0.id == id }) else { return }
        session.applyPreset(p)
    }

    @objc func applyFileWindow(_ sender: NSMenuItem) {
        guard let r = session.activeState?.current else { return }
        let k = sender.tag
        session.applyToActive { s in
            s.display.windowCenter = r.attributes.windowCenters[k]
            s.display.windowWidth = r.attributes.windowWidths[safe: k] ?? s.display.windowWidth
            s.display.windowName = r.instance.windowExplanations[safe: k]
        }
    }

    @objc func defaultWindow(_ sender: Any?) { session.applyDefaultWindow() }
    @objc func fullDynamic(_ sender: Any?) { session.applyFullDynamic() }
    @objc func presetKey(_ sender: NSMenuItem) { session.applyPresetKey(sender.tag) }

    @objc func customWindow(_ sender: Any?) {
        guard let s = session.activeState else { return }
        CustomWindowSheet.present(on: window!, center: s.display.windowCenter, width: s.display.windowWidth) { [weak self] c, w in
            self?.session.applyToActive { st in st.display.windowCenter = c; st.display.windowWidth = w; st.display.windowName = "Custom" }
        }
    }

    @objc func toggleNegative(_ sender: Any?) { session.applyToActive { $0.display.negative.toggle() } }
    @objc func setColormap(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = Colormap(rawValue: raw) else { return }
        session.applyToActive { $0.display.colormap = c }
    }

    @objc func rotateCW(_ sender: Any?) { if let s = session.activeState { session.applyOrientation(.rotateCW, to: s) } }
    @objc func rotateCCW(_ sender: Any?) { if let s = session.activeState { session.applyOrientation(.rotateCCW, to: s) } }
    @objc func rotate180(_ sender: Any?) { if let s = session.activeState { session.applyOrientation(.rotateCW.then(.rotateCW), to: s) } }
    @objc func flipHorizontal(_ sender: Any?) { if let s = session.activeState { session.applyOrientation(.flipH, to: s) } }
    @objc func flipVertical(_ sender: Any?) { if let s = session.activeState { session.applyOrientation(.flipV, to: s) } }
    @objc func clearTransformations(_ sender: Any?) {
        session.applyToActive { s in
            s.display.orientation = .identity
            s.display.fitMode = .fit
            s.display.pan = .zero
        }
    }

    @objc func fitImage(_ sender: Any?) { session.applyToActive { $0.display.fitMode = .fit }; if let s = session.activeState { session.viewportDisplayChanged(s, zoomPan: true) } }
    @objc func fillViewport(_ sender: Any?) { session.applyToActive { $0.display.fitMode = .fill } }
    @objc func actualSize(_ sender: Any?) { session.applyToActive { $0.display.fitMode = .actual; $0.display.pan = .zero } }
    @objc func zoomIn(_ sender: Any?) { zoomBy(1.25) }
    @objc func zoomOut(_ sender: Any?) { zoomBy(0.8) }

    private func zoomBy(_ f: Double) {
        guard let v = session.active else { return }
        if v.state.display.fitMode != .custom { v.materializeZoom() }
        let c = CGPoint(x: v.bounds.midX, y: v.bounds.midY)
        guard let ip = v.imagePoint(c) else { return }
        v.zoom(to: v.state.display.zoom * f, anchorView: c, anchorImage: ip)
    }

    @objc func nextFilter(_ sender: Any?) { session.applyToActive { $0.display.filter = ($0.display.filter + 1) % DisplayState.filterNames.count } }
    @objc func previousFilter(_ sender: Any?) { session.applyToActive { $0.display.filter = ($0.display.filter + DisplayState.filterNames.count - 1) % DisplayState.filterNames.count } }
    @objc func nextSharpen(_ sender: Any?) { session.applyToActive { $0.display.filter = $0.display.filter == 2 ? 3 : ($0.display.filter == 3 ? 0 : 2) } }
    @objc func toggleInterpolation(_ sender: Any?) { session.applyToActive { $0.display.interpolate.toggle() } }

    @objc func toggleAnnotations(_ sender: Any?) { session.showAnnotations.toggle() }
    @objc func toggleHidePatient(_ sender: Any?) { session.hidePatientData.toggle(); updateTitle() }
    @objc func toggleCrossReference(_ sender: Any?) { session.showCrossReference.toggle() }
    @objc func toggleMeasurements(_ sender: Any?) { session.showMeasurements.toggle() }
    @objc func increaseFont(_ sender: Any?) { session.fontScale = min(2.5, session.fontScale * 1.12) }
    @objc func decreaseFont(_ sender: Any?) { session.fontScale = max(0.6, session.fontScale / 1.12) }
    @objc func toggleSync(_ sender: Any?) { session.syncMode = session.syncMode == .disabled ? .auto : .disabled; window?.toolbar?.validateVisibleItems() }
    @objc func setSyncAuto(_ sender: Any?) { session.syncMode = .auto }
    @objc func setSyncManual(_ sender: Any?) { session.setManualSync() }
    @objc func setSyncDisabled(_ sender: Any?) { session.syncMode = .disabled }
    @objc func toggleSyncSlice(_ sender: Any?) { session.syncSlice.toggle() }
    @objc func toggleSyncZoom(_ sender: Any?) { session.syncZoom.toggle() }
    @objc func toggleSyncWindow(_ sender: Any?) { session.syncWindow.toggle() }
    @objc func toggleSidebarPane(_ sender: Any?) { sidebarItem.animator().isCollapsed.toggle() }
    @objc func toggleInspector(_ sender: Any?) { inspectorItem.animator().isCollapsed.toggle() }

    // MARK: - Actions: navigation

    @objc func nextImage(_ sender: Any?) { session.active?.step(1) }
    @objc func previousImage(_ sender: Any?) { session.active?.step(-1) }
    @objc func skipForward(_ sender: Any?) { if let v = session.active { v.step(max(1, v.state.imageCount / 10)) } }
    @objc func skipBack(_ sender: Any?) { if let v = session.active { v.step(-max(1, v.state.imageCount / 10)) } }
    @objc func firstImage(_ sender: Any?) { if let v = session.active { v.state.setIndex(0); session.viewportImageChanged(v.state) } }
    @objc func lastImage(_ sender: Any?) { if let v = session.active { v.state.setIndex(v.state.imageCount - 1); session.viewportImageChanged(v.state) } }
    @objc func nextSeries(_ sender: Any?) { if let v = session.active { session.stepSeries(in: v, by: 1) } }
    @objc func previousSeries(_ sender: Any?) { if let v = session.active { session.stepSeries(in: v, by: -1) } }
    @objc func firstSeriesAction(_ sender: Any?) { if let v = session.active { session.firstSeries(v) } }
    @objc func lastSeriesAction(_ sender: Any?) { if let v = session.active { session.lastSeries(v) } }
    @objc func toggleCine(_ sender: Any?) { session.toggleCine() }
    @objc func cineFaster(_ sender: Any?) { session.applyToActive { $0.cine.fps = min(120, $0.cine.fps + 2) } }
    @objc func cineSlower(_ sender: Any?) { session.applyToActive { $0.cine.fps = max(1, $0.cine.fps - 2) } }

    @objc func sortSeries(_ sender: NSMenuItem) {
        guard let s = session.activeState?.series, let raw = sender.representedObject as? String else { return }
        if let mode = SortMode(rawValue: raw) { s.sortMode = mode } else if raw == "asc" { s.ascending = true } else if raw == "desc" { s.ascending = false }
        let cur = session.activeState?.current
        s.rebuildImages()
        if let c = cur, let i = s.images.firstIndex(of: c) { session.activeState?.index = i }
        session.redrawAll()
    }

    @objc func splitSeries(_ sender: Any?) {
        guard let v = session.active, let s = v.state.series else { return }
        let parts = session.collection.split(s)
        if let first = parts.first { session.show(first, in: v) }
    }

    @objc func closePanel(_ sender: Any?) { session.closeActivePanel() }
    @objc func closeAllPanelsAction(_ sender: Any?) { session.closeAllPanels() }
    @objc func maximizePanel(_ sender: Any?) { if let v = session.active { session.toggleMaximize(v) } }

    // MARK: - Actions: measurements

    @objc func deleteSelectedMeasurement(_ sender: Any?) { session.deleteMeasurements(scope: .selected) }
    @objc func deleteImageMeasurements(_ sender: Any?) { session.deleteMeasurements(scope: .image) }
    @objc func deleteSeriesMeasurements(_ sender: Any?) { session.deleteMeasurements(scope: .series) }
    @objc func deleteVisibleMeasurements(_ sender: Any?) { session.deleteMeasurements(scope: .allVisible) }
    @objc func copySelectedMeasurement(_ sender: Any?) { session.copyMeasurements(all: false) }
    @objc func copyAllMeasurements(_ sender: Any?) { session.copyMeasurements(all: true) }
    @objc func pasteMeasurements(_ sender: Any?) { session.pasteMeasurements() }
    @objc func duplicateToPanels(_ sender: Any?) { session.duplicateMeasurements(toAllImagesOfSeries: false) }
    @objc func duplicateToSeries(_ sender: Any?) { session.duplicateMeasurements(toAllImagesOfSeries: true) }

    @objc func calibrate(_ sender: Any?) {
        guard let v = session.active else { return }
        CalibrationSheet.present(for: v, session: session)
    }

    @objc func lengthRatio(_ sender: Any?) { MeasurementCalculations.lengthRatio(session: session) }
    @objc func ellipsoidVolume(_ sender: Any?) { MeasurementCalculations.ellipsoidVolume(session: session) }

    // MARK: - Actions: data

    @objc func copy(_ sender: Any?) { copyImage(sender) }
    @objc func paste(_ sender: Any?) { session.pasteMeasurements() }
    @objc func delete(_ sender: Any?) { session.deleteMeasurements(scope: .selected) }

    @objc func copyImage(_ sender: Any?) {
        guard let img = session.active?.snapshot() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    @objc func copyAllImages(_ sender: Any?) {
        let r = session.gridView.bounds
        guard let rep = session.gridView.bitmapImageRepForCachingDisplay(in: r) else { return }
        // Composite each viewport snapshot
        let img = NSImage(size: r.size)
        img.lockFocusFlipped(true)
        NSColor.black.setFill(); r.fill()
        for v in session.viewports where v.superview != nil {
            v.snapshot()?.draw(in: v.frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        img.unlockFocus()
        _ = rep
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    @objc func shareImage(_ sender: Any?) {
        guard let v = session.active, let img = v.snapshot() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Specula Image.png")
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: v.bounds, of: v, preferredEdge: .minY)
        }
    }

    @objc func printImage(_ sender: Any?) { PrintController.printImages(session: session, all: false) }
    @objc func printAll(_ sender: Any?) { PrintController.printImages(session: session, all: true) }
    @objc func exportImages(_ sender: Any?) { ExportSheet.present(session: session, on: window!) }
    @objc func showTags(_ sender: Any?) {
        guard let r = session.activeState?.current ?? session.active?.mpr?.volume.images.first else { return }
        TagBrowserWindow.show(ref: r)
    }
    @objc func revealInFinder(_ sender: Any?) {
        guard let r = session.activeState?.current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([r.instance.url])
    }
    @objc func anonymize(_ sender: Any?) { AnonymizerWindow.show(session: session) }
    @objc func sendToPACS(_ sender: Any?) { SendToPACSSheet.present(session: session, on: window!) }
    @objc func importToLibrary(_ sender: Any?) {
        let urls = session.collection.studies.flatMap { $0.series.flatMap { $0.instances.map(\.url) } }
        LibraryWindowController.shared.importFiles(urls)
        LibraryWindowController.shared.showWindow(nil)
    }

    // MARK: - Actions: advanced

    @objc func openMPR(_ sender: Any?) {
        guard let s = session.activeState?.series else { return }
        MPRWindowController.open(series: s, session: session, mode: .mpr)
    }

    @objc func openVR(_ sender: Any?) {
        guard let s = session.activeState?.series else { return }
        MPRWindowController.open(series: s, session: session, mode: .vr)
    }

    @objc func openFusion(_ sender: Any?) { FusionSheet.present(session: session, on: window!) }

    @objc func toggleSubtraction(_ sender: Any?) {
        guard let v = session.active, v.state.imageCount > 1 else { return }
        v.state.subtraction.enabled.toggle()
        if v.state.subtraction.enabled {
            if v.state.subtraction.maskIndex >= v.state.imageCount { v.state.subtraction.maskIndex = 0 }
            v.state.display.windowCenter = 0
            v.state.display.windowWidth = 256
            v.state.display.windowName = "DSA"
        } else {
            v.state.display.initialized = false
        }
        v.needsRedraw()
    }

    @objc func useCurrentAsMask(_ sender: Any?) {
        guard let v = session.active else { return }
        v.state.subtraction.enabled = true
        v.state.subtraction.maskIndex = v.state.index
        v.state.display.windowCenter = 0; v.state.display.windowWidth = 256
        v.needsRedraw()
    }

    @objc func resetMask(_ sender: Any?) {
        guard let v = session.active else { return }
        v.state.subtraction.maskIndex = 0
        v.state.subtraction.shift = .zero
        v.needsRedraw()
    }

    @objc func manualPixelShift(_ sender: Any?) {
        guard let v = session.active else { return }
        v.dragState = nil
        session.tool = .pan
        DSAShiftMode.begin(on: v)
    }

    @objc func autoPixelShift(_ sender: Any?) {
        guard let v = session.active else { return }
        DSAShiftMode.autoShift(v)
    }

    @objc func timeIntensityCurve(_ sender: Any?) { TimeIntensityWindow.show(session: session) }
    @objc func openMultipleSeries(_ sender: Any?) { MultiSeriesPicker.present(session: session, on: window!) }

    @objc func newViewerWindow(_ sender: Any?) {
        let wc = ViewerWindowController()
        wc.showWindow(nil)
    }

    @objc func duplicateWindow(_ sender: Any?) {
        let wc = ViewerWindowController()
        let urls = session.collection.studies.flatMap { $0.series.flatMap { $0.instances.map(\.url) } }
        wc.showWindow(nil)
        wc.session.open(urls: urls)
    }

    // MARK: - Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let s = session.activeState
        let hasImage = s?.current != nil
        switch item.action {
        case #selector(toggleNegative(_:)): item.state = s?.display.negative == true ? .on : .off; return hasImage
        case #selector(toggleAnnotations(_:)): item.state = session.showAnnotations ? .on : .off
        case #selector(toggleHidePatient(_:)): item.state = session.hidePatientData ? .on : .off
        case #selector(toggleCrossReference(_:)): item.state = session.showCrossReference ? .on : .off
        case #selector(toggleMeasurements(_:)): item.state = session.showMeasurements ? .on : .off
        case #selector(toggleSync(_:)): item.state = session.syncMode != .disabled ? .on : .off
        case #selector(setSyncAuto(_:)): item.state = session.syncMode == .auto ? .on : .off
        case #selector(setSyncManual(_:)): item.state = session.syncMode == .manual ? .on : .off
        case #selector(setSyncDisabled(_:)): item.state = session.syncMode == .disabled ? .on : .off
        case #selector(toggleSyncSlice(_:)): item.state = session.syncSlice ? .on : .off
        case #selector(toggleSyncZoom(_:)): item.state = session.syncZoom ? .on : .off
        case #selector(toggleSyncWindow(_:)): item.state = session.syncWindow ? .on : .off
        case #selector(toggleInterpolation(_:)): item.state = s?.display.interpolate == true ? .on : .off
        case #selector(toggleCine(_:)): item.title = s?.cine.playing == true ? "Stop Cine" : "Play Cine"; return (s?.imageCount ?? 0) > 1
        case #selector(toggleSubtraction(_:)): item.state = s?.subtraction.enabled == true ? .on : .off; return (s?.imageCount ?? 0) > 1
        case #selector(selectTool(_:)): item.state = (item.representedObject as? String) == session.tool.rawValue ? .on : .off
        case #selector(setColormap(_:)): item.state = (item.representedObject as? String) == s?.display.colormap.rawValue ? .on : .off
        case #selector(sortSeries(_:)):
            if let raw = item.representedObject as? String {
                if let m = SortMode(rawValue: raw) { item.state = s?.series?.sortMode == m ? .on : .off }
                else { item.state = (raw == "asc") == (s?.series?.ascending ?? true) ? .on : .off }
            }
            return s?.series != nil
        case #selector(openMPR(_:)), #selector(openVR(_:)): return s?.series?.volumeCandidate == true
        case #selector(deleteSelectedMeasurement(_:)), #selector(copySelectedMeasurement(_:)): return session.active?.selectedMeasurement != nil
        case #selector(copyImage(_:)), #selector(printImage(_:)), #selector(shareImage(_:)), #selector(showTags(_:)), #selector(revealInFinder(_:)),
             #selector(rotateCW(_:)), #selector(rotateCCW(_:)), #selector(rotate180(_:)), #selector(flipHorizontal(_:)), #selector(flipVertical(_:)),
             #selector(clearTransformations(_:)), #selector(fitImage(_:)), #selector(actualSize(_:)), #selector(fillViewport(_:)), #selector(customWindow(_:)),
             #selector(defaultWindow(_:)), #selector(fullDynamic(_:)), #selector(applyPresetItem(_:)), #selector(calibrate(_:)):
            return hasImage || session.active?.mpr != nil
        case #selector(exportImages(_:)), #selector(anonymize(_:)), #selector(sendToPACS(_:)), #selector(importToLibrary(_:)), #selector(duplicateWindow(_:)):
            return !session.collection.isEmpty
        default: break
        }
        return true
    }
}

extension ViewerWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Window" { rebuildPresetMenu(menu) }
    }
}

/// Small grid glyphs for the layout menu.
enum LayoutIcon {
    static func make(rows: Int, cols: Int) -> NSImage {
        let s = NSSize(width: 18, height: 14)
        let img = NSImage(size: s, flipped: false) { r in
            NSColor.labelColor.setStroke()
            let gw = r.width / CGFloat(cols), gh = r.height / CGFloat(rows)
            for i in 0..<rows { for j in 0..<cols {
                let cell = NSRect(x: CGFloat(j) * gw + 0.5, y: CGFloat(i) * gh + 0.5, width: gw - 1, height: gh - 1)
                let p = NSBezierPath(roundedRect: cell, xRadius: 1, yRadius: 1)
                p.lineWidth = 1
                p.stroke()
            } }
            return true
        }
        img.isTemplate = true
        return img
    }
}
