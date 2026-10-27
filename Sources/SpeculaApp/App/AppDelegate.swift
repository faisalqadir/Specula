import AppKit
import SwiftUI
import DICOMCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var pendingURLs: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        #if DEBUG
        Automation.install()
        #endif
        NSApp.servicesMenu = NSMenu()
        _ = MetalContext.shared
        if Preferences.shared.showLibraryOnLaunch {
            LibraryWindowController.shared.showWindow(nil)
        }
        let wc = ViewerWindowController()
        wc.showWindow(nil)
        launched = true
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
        let urls = pendingURLs + args.filter { FileManager.default.fileExists(atPath: $0.path) }
        pendingURLs = []
        if !urls.isEmpty { wc.session.open(urls: urls) }
        PACSService.shared.startListenerIfConfigured()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { pendingURLs += urls; return }
        let target = (NSApp.keyWindow?.windowController as? ViewerWindowController) ?? ViewerWindowController.all.first(where: { $0.session.collection.isEmpty }) ?? {
            let wc = ViewerWindowController(); wc.showWindow(nil); return wc
        }()
        // Opening into a window that already holds studies starts a new window (RadiAnt behaviour)
        if !target.session.collection.isEmpty && NSEvent.modifierFlags.contains(.option) == false {
            let wc = ViewerWindowController()
            wc.showWindow(nil)
            wc.session.open(urls: urls)
        } else {
            target.window?.makeKeyAndOrderFront(nil)
            target.session.open(urls: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { ViewerWindowController().showWindow(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: DICOMLoader.tempRoot)
        PACSService.shared.stopListener()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Global actions

    @objc func newDocument(_ sender: Any?) { ViewerWindowController().showWindow(nil) }

    @objc func openDocument(_ sender: Any?) {
        if let wc = NSApp.keyWindow?.windowController as? ViewerWindowController {
            wc.openDocument(sender)
            return
        }
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        if p.runModal() == .OK {
            let wc = ViewerWindowController()
            wc.showWindow(nil)
            wc.session.open(urls: p.urls)
        }
    }

    @objc func showLibrary(_ sender: Any?) { LibraryWindowController.shared.showWindow(nil) }
    @objc func showPACS(_ sender: Any?) { PACSWindowController.shared.showWindow(nil) }
    @objc func showDownloads(_ sender: Any?) { PACSWindowController.shared.showWindow(nil); PACSWindowController.shared.showDownloads() }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.toolbarStyle = .preference
            w.contentViewController = SettingsPanes.controller()
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Specula",
            .applicationVersion: "1.0",
            .credits: NSAttributedString(string: "A native macOS DICOM viewer.\nDICOM data dictionary derived from DCMTK (© OFFIS e.V., BSD licence).\n\nNot a certified medical device. For review and educational use.",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc func showHelp(_ sender: Any?) { HelpWindow.show() }

    @objc func openKeyboardSettings(_ sender: Any?) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(u) }
    }
}

enum MainMenu {
    static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], tag: Int = 0, represented: Any? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.tag = tag
        i.representedObject = represented
        return i
    }

    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach { m.addItem($0) }
        i.submenu = m
        return i
    }

    static func build() -> NSMenu {
        typealias W = ViewerWindowController
        let main = NSMenu()

        // App
        let app = NSMenu()
        app.addItem(item("About Specula", #selector(AppDelegate.showAbout(_:)), ""))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(item("Hide Specula", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""))
        app.addItem(.separator())
        app.addItem(item("Quit Specula", #selector(NSApplication.terminate(_:)), "q"))
        let appItem = NSMenuItem(); appItem.submenu = app; main.addItem(appItem)

        // File
        let file = NSMenu(title: "File")
        file.addItem(item("New Window", #selector(AppDelegate.newDocument(_:)), "n"))
        file.addItem(item("Open…", #selector(AppDelegate.openDocument(_:)), "o"))
        file.addItem(item("Open ZIP Archive…", #selector(W.openZip(_:)), "o", [.command, .option]))
        file.addItem(item("Open CD/DVD", #selector(W.openDisc(_:)), "o", [.command, .shift]))
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        recentMenu.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)), ""))
        recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(.separator())
        file.addItem(item("Library", #selector(AppDelegate.showLibrary(_:)), "l"))
        file.addItem(item("Search PACS…", #selector(AppDelegate.showPACS(_:)), "k"))
        file.addItem(item("PACS Downloads", #selector(AppDelegate.showDownloads(_:)), "k", [.command, .option]))
        file.addItem(item("Import into Library", #selector(W.importToLibrary(_:)), "i", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Export Images…", #selector(W.exportImages(_:)), "e"))
        file.addItem(item("Anonymize…", #selector(W.anonymize(_:)), "a", [.command, .option]))
        file.addItem(item("Send to PACS…", #selector(W.sendToPACS(_:)), ""))
        file.addItem(.separator())
        file.addItem(item("Page Setup…", #selector(NSApplication.runPageLayout(_:)), "p", [.command, .shift]))
        file.addItem(item("Print…", #selector(W.printImage(_:)), "p"))
        file.addItem(item("Print All Panels…", #selector(W.printAll(_:)), "p", [.command, .option]))
        let fileItem = NSMenuItem(); fileItem.submenu = file; main.addItem(fileItem)

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("Copy Image", #selector(W.copyImage(_:)), "c", [.command, .shift]))
        edit.addItem(item("Copy All Panels", #selector(W.copyAllImages(_:)), "c", [.command, .option]))
        edit.addItem(item("Paste Measurements", #selector(W.pasteMeasurements(_:)), "v", [.command, .shift]))
        let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)

        // View
        let view = NSMenu(title: "View")
        view.addItem(item("Show Sidebar", #selector(W.toggleSidebarPane(_:)), "s", [.command, .control]))
        view.addItem(item("Show Inspector", #selector(W.toggleInspector(_:)), "i", [.command, .option]))
        view.addItem(.separator())
        let layouts: [(Int, Int)] = [(1, 1), (1, 2), (2, 1), (2, 2), (2, 3), (3, 3), (4, 4)]
        view.addItem(submenu("Layout", layouts.enumerated().map { i, rc in
            let it = item("\(rc.0) × \(rc.1)", #selector(W.setLayoutFromMenu(_:)), i < 4 ? String(i + 1) : "", [.command, .control], represented: [rc.0, rc.1])
            it.image = LayoutIcon.make(rows: rc.0, cols: rc.1)
            return it
        } + [.separator(), item("Custom…", #selector(W.customLayout(_:)), "")]))
        view.addItem(item("Maximize Panel", #selector(W.maximizePanel(_:)), "m", [.command, .shift]))
        view.addItem(item("Close Panel", #selector(W.closePanel(_:)), ""))
        view.addItem(item("Close All Panels", #selector(W.closeAllPanelsAction(_:)), ""))
        view.addItem(.separator())
        view.addItem(item("Annotations", #selector(W.toggleAnnotations(_:)), "t", [.command, .shift]))
        view.addItem(item("Hide Patient Data", #selector(W.toggleHidePatient(_:)), "h", [.command, .shift]))
        view.addItem(item("Cross-Reference Lines", #selector(W.toggleCrossReference(_:)), "r", [.command, .shift]))
        view.addItem(item("Measurements", #selector(W.toggleMeasurements(_:)), ""))
        view.addItem(item("Increase Font Size", #selector(W.increaseFont(_:)), "+", [.command, .option]))
        view.addItem(item("Decrease Font Size", #selector(W.decreaseFont(_:)), "-", [.command, .option]))
        view.addItem(.separator())
        view.addItem(item("Zoom In", #selector(W.zoomIn(_:)), "+"))
        view.addItem(item("Zoom Out", #selector(W.zoomOut(_:)), "-"))
        view.addItem(item("Fit to Panel", #selector(W.fitImage(_:)), "0"))
        view.addItem(item("Fill Panel", #selector(W.fillViewport(_:)), "0", [.command, .shift]))
        view.addItem(item("Actual Size", #selector(W.actualSize(_:)), "0", [.command, .option]))
        view.addItem(.separator())
        view.addItem(item("New Viewer Window", #selector(W.newViewerWindow(_:)), ""))
        view.addItem(item("Duplicate Window", #selector(W.duplicateWindow(_:)), "d", [.command, .option]))
        let viewItem = NSMenuItem(); viewItem.submenu = view; main.addItem(viewItem)

        // Image
        let image = NSMenu(title: "Image")
        image.addItem(item("Default Window", #selector(W.defaultWindow(_:)), ""))
        image.addItem(item("Full Dynamic", #selector(W.fullDynamic(_:)), ""))
        image.addItem(submenu("Window Presets", WindowPreset.ct.map { p in item("\(p.name) (\(Int(p.center))/\(Int(p.width)))", #selector(W.presetKey(_:)), "", [], tag: p.key ?? 0) }))
        image.addItem(item("Custom Window…", #selector(W.customWindow(_:)), "w", [.command, .option]))
        image.addItem(item("Negative", #selector(W.toggleNegative(_:)), "i"))
        image.addItem(submenu("Color Map", Colormap.allCases.map { item($0.title, #selector(W.setColormap(_:)), "", [], represented: $0.rawValue) }))
        image.addItem(.separator())
        image.addItem(item("Next Filter", #selector(W.nextFilter(_:)), "f", [.command, .option]))
        image.addItem(item("Previous Filter", #selector(W.previousFilter(_:)), "f", [.command, .option, .shift]))
        image.addItem(item("Next Sharpen Filter", #selector(W.nextSharpen(_:)), ""))
        image.addItem(item("Smooth Interpolation", #selector(W.toggleInterpolation(_:)), ""))
        image.addItem(.separator())
        image.addItem(item("Rotate 90° Clockwise", #selector(W.rotateCW(_:)), "]"))
        image.addItem(item("Rotate 90° Counterclockwise", #selector(W.rotateCCW(_:)), "["))
        image.addItem(item("Rotate 180°", #selector(W.rotate180(_:)), ""))
        image.addItem(item("Flip Horizontal", #selector(W.flipHorizontal(_:)), "]", [.command, .option]))
        image.addItem(item("Flip Vertical", #selector(W.flipVertical(_:)), "[", [.command, .option]))
        image.addItem(item("Clear Transformations", #selector(W.clearTransformations(_:)), ""))
        image.addItem(.separator())
        image.addItem(item("Show DICOM Tags", #selector(W.showTags(_:)), "j"))
        image.addItem(item("Show in Finder", #selector(W.revealInFinder(_:)), "r", [.command, .option]))
        let imageItem = NSMenuItem(); imageItem.submenu = image; main.addItem(imageItem)

        // Series
        let series = NSMenu(title: "Series")
        series.addItem(item("Next Image", #selector(W.nextImage(_:)), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), [.command]))
        series.addItem(item("Previous Image", #selector(W.previousImage(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), [.command]))
        series.addItem(item("Skip Images Forward", #selector(W.skipForward(_:)), ""))
        series.addItem(item("Skip Images Back", #selector(W.skipBack(_:)), ""))
        series.addItem(item("First Image", #selector(W.firstImage(_:)), ""))
        series.addItem(item("Last Image", #selector(W.lastImage(_:)), ""))
        series.addItem(.separator())
        series.addItem(item("Next Series", #selector(W.nextSeries(_:)), String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), [.command]))
        series.addItem(item("Previous Series", #selector(W.previousSeries(_:)), String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), [.command]))
        series.addItem(item("First Series", #selector(W.firstSeriesAction(_:)), ""))
        series.addItem(item("Last Series", #selector(W.lastSeriesAction(_:)), ""))
        series.addItem(.separator())
        series.addItem(item("Play Cine", #selector(W.toggleCine(_:)), "\r", [.command]))
        series.addItem(item("Cine Faster", #selector(W.cineFaster(_:)), "."))
        series.addItem(item("Cine Slower", #selector(W.cineSlower(_:)), ","))
        series.addItem(.separator())
        series.addItem(submenu("Sort Images By", SortMode.allCases.map { item($0.title, #selector(W.sortSeries(_:)), "", [], represented: $0.rawValue) } +
                               [.separator(), item("Ascending", #selector(W.sortSeries(_:)), "", [], represented: "asc"), item("Descending", #selector(W.sortSeries(_:)), "", [], represented: "desc")]))
        series.addItem(item("Split Series", #selector(W.splitSeries(_:)), ""))
        series.addItem(item("Open Multiple Series…", #selector(W.openMultipleSeries(_:)), ""))
        series.addItem(.separator())
        series.addItem(submenu("Synchronization", [
            item("Automatic", #selector(W.setSyncAuto(_:)), ""), item("Manual (Keep Current Offsets)", #selector(W.setSyncManual(_:)), ""), item("Disabled", #selector(W.setSyncDisabled(_:)), ""),
            .separator(), item("Slice Position", #selector(W.toggleSyncSlice(_:)), ""), item("Zoom & Pan", #selector(W.toggleSyncZoom(_:)), ""), item("Window Settings", #selector(W.toggleSyncWindow(_:)), ""),
        ]))
        series.addItem(item("Toggle Synchronization", #selector(W.toggleSync(_:)), "y"))
        let seriesItem = NSMenuItem(); seriesItem.submenu = series; main.addItem(seriesItem)

        // 3D
        let adv = NSMenu(title: "3D")
        adv.addItem(item("3D MPR", #selector(W.openMPR(_:)), "m", [.command, .option]))
        adv.addItem(item("3D Volume Rendering", #selector(W.openVR(_:)), "v", [.command, .option]))
        adv.addItem(.separator())
        adv.addItem(item("PET-CT Fusion…", #selector(W.openFusion(_:)), "u", [.command, .option]))
        adv.addItem(submenu("Subtraction (DSA)", [
            item("Enable Subtraction", #selector(W.toggleSubtraction(_:)), "s", [.command, .option]),
            item("Use Current Image as Mask", #selector(W.useCurrentAsMask(_:)), ""),
            item("Reset Mask", #selector(W.resetMask(_:)), ""),
            .separator(),
            item("Manual Pixel Shift", #selector(W.manualPixelShift(_:)), ""),
            item("Auto Pixel Shift", #selector(W.autoPixelShift(_:)), ""),
        ]))
        adv.addItem(item("Time-Intensity Curve…", #selector(W.timeIntensityCurve(_:)), ""))
        let advItem = NSMenuItem(); advItem.submenu = adv; main.addItem(advItem)

        // Measure (tools)
        let tools = NSMenu(title: "Tools")
        for t in Tool.navigation + [.cursor3D] {
            let i = item(t.title, #selector(W.selectTool(_:)), "", [], represented: t.rawValue)
            i.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)
            tools.addItem(i)
        }
        tools.addItem(.separator())
        for t in Tool.measurements {
            let i = item(t.title, #selector(W.selectTool(_:)), "", [], represented: t.rawValue)
            i.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)
            tools.addItem(i)
        }
        tools.addItem(.separator())
        tools.addItem(item("Calibrate Length…", #selector(W.calibrate(_:)), ""))
        tools.addItem(item("Length Ratio", #selector(W.lengthRatio(_:)), ""))
        tools.addItem(item("Ellipsoid / Bullet Volume", #selector(W.ellipsoidVolume(_:)), ""))
        tools.addItem(.separator())
        tools.addItem(item("Delete Selected Measurement", #selector(W.deleteSelectedMeasurement(_:)), ""))
        tools.addItem(item("Delete All in Current Image", #selector(W.deleteImageMeasurements(_:)), ""))
        tools.addItem(item("Delete All in Current Series", #selector(W.deleteSeriesMeasurements(_:)), ""))
        tools.addItem(item("Delete All in Visible Panels", #selector(W.deleteVisibleMeasurements(_:)), ""))
        tools.addItem(.separator())
        tools.addItem(item("Copy Selected Measurement", #selector(W.copySelectedMeasurement(_:)), ""))
        tools.addItem(item("Copy All Measurements", #selector(W.copyAllMeasurements(_:)), ""))
        tools.addItem(item("Duplicate in Other Panels", #selector(W.duplicateToPanels(_:)), ""))
        tools.addItem(item("Duplicate in All Images of the Series", #selector(W.duplicateToSeries(_:)), ""))
        let toolsItem = NSMenuItem(); toolsItem.submenu = tools; main.addItem(toolsItem)

        // Window
        let win = NSMenu(title: "Window")
        win.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        win.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        win.addItem(.separator())
        win.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""))
        let winItem = NSMenuItem(); winItem.submenu = win; main.addItem(winItem)
        NSApp.windowsMenu = win

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(item("Specula Help", #selector(AppDelegate.showHelp(_:)), "?"))
        help.addItem(item("Customize Keyboard Shortcuts…", #selector(AppDelegate.openKeyboardSettings(_:)), ""))
        let helpItem = NSMenuItem(); helpItem.submenu = help; main.addItem(helpItem)
        NSApp.helpMenu = help
        for it in main.items { if let t = it.submenu?.title, !t.isEmpty { it.title = t } }
        return main
    }
}
