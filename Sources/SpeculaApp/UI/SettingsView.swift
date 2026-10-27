import SwiftUI
import AppKit
import DICOMCore

/// Settings panes, shown in an NSTabViewController with a toolbar (the standard Mac settings window).
enum SettingsPanes {
    static func make() -> [(String, String, AnyView)] {
        let prefs = Preferences.shared
        return [
            ("General", "gearshape", AnyView(GeneralSettings(prefs: prefs))),
            ("Mouse", "computermouse", AnyView(MouseSettings(prefs: prefs))),
            ("Display", "rectangle.on.rectangle", AnyView(DisplaySettings(prefs: prefs))),
            ("Annotations", "textformat", AnyView(OverlaySettings(prefs: prefs))),
            ("Measurements", "ruler", AnyView(MeasurementSettings(prefs: prefs))),
            ("Presets", "circle.lefthalf.filled", AnyView(PresetSettings(prefs: prefs))),
            ("PACS", "network", AnyView(PACSSettingsView())),
        ]
    }

    static func controller() -> NSTabViewController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = false
        for (title, symbol, view) in make() {
            let host = NSHostingController(rootView: view.frame(width: 680, height: 560))
            host.sizingOptions = []
            host.preferredContentSize = NSSize(width: 680, height: 560)
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        return tabs
    }
}

private struct GeneralSettings: View {
    @ObservedObject var prefs: Preferences
    var body: some View {
        Form {
            Section("Loading") {
                Toggle("Show the first image while files are still loading", isOn: $prefs.autoShowFirstImage)
                Toggle("Load non-image objects (reports, PDF, video)", isOn: $prefs.loadNonImage)
                Toggle("Newest studies first", isOn: $prefs.studiesDescending)
                Toggle("Show series numbers on thumbnails", isOn: $prefs.showSeriesNumbers)
            }
            Section("Startup") {
                Toggle("Show the library window at launch", isOn: $prefs.showLibraryOnLaunch)
            }
            Section("Character set") {
                Picker("Force character set", selection: $prefs.forcedCharacterSet) {
                    Text("Use value from files").tag("")
                    ForEach(["ISO_IR 100", "ISO_IR 101", "ISO_IR 109", "ISO_IR 110", "ISO_IR 144", "ISO_IR 127", "ISO_IR 126", "ISO_IR 138", "ISO_IR 148", "ISO_IR 13", "ISO_IR 166", "ISO_IR 192", "GB18030", "GBK", "CP1251"], id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Library") {
                LabeledContent("Location") {
                    HStack {
                        Text(prefs.libraryPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") {
                            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                            if p.runModal() == .OK, let u = p.url { prefs.libraryPath = u.path }
                        }
                    }
                }
                Toggle("Copy imported files into the library (otherwise keep links)", isOn: $prefs.importCopiesFiles)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MouseSettings: View {
    @ObservedObject var prefs: Preferences
    var body: some View {
        Form {
            Section("Buttons") {
                Picker("Left button", selection: $prefs.leftButton) { ForEach(MouseAction.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("Right button", selection: $prefs.rightButton) { ForEach(MouseAction.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("Middle button", selection: $prefs.middleButton) { ForEach(MouseAction.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("Back button", selection: $prefs.backButton) { ForEach(MouseAction.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("Forward button", selection: $prefs.forwardButton) { ForEach(MouseAction.allCases, id: \.self) { Text($0.title).tag($0) } }
                Text("With a trackpad: ⌥-drag adjusts the window, ⇧-drag pans, ⌘-drag zooms, pinch zooms, rotate turns the image by 90°.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Scrolling") {
                Toggle("Scroll wheel zooms instead of browsing", isOn: $prefs.wheelZooms)
                Toggle("Horizontal scrolling changes series", isOn: $prefs.horizontalWheelChangesSeries)
                Toggle("Reverse browsing direction", isOn: $prefs.invertScroll)
                Toggle("Endless scrolling (wrap at the ends of a series)", isOn: $prefs.endlessScrolling)
                Toggle("Zoom around the pointer", isOn: $prefs.zoomAroundCursor)
            }
            Section("Window adjustment") {
                Toggle("Swap level and width directions", isOn: Binding(get: { prefs.windowDirections & 1 != 0 }, set: { prefs.windowDirections = $0 ? prefs.windowDirections | 1 : prefs.windowDirections & ~1 }))
                Toggle("Reverse vertical direction", isOn: Binding(get: { prefs.windowDirections & 2 != 0 }, set: { prefs.windowDirections = $0 ? prefs.windowDirections | 2 : prefs.windowDirections & ~2 }))
                Toggle("Reverse horizontal direction", isOn: Binding(get: { prefs.windowDirections & 4 != 0 }, set: { prefs.windowDirections = $0 ? prefs.windowDirections | 4 : prefs.windowDirections & ~4 }))
            }
            Section("Keyboard") {
                Text("Every menu command can be given a custom shortcut in System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts.").font(.caption).foregroundStyle(.secondary)
                Button("Open Keyboard Settings…") { NSApp.sendAction(#selector(AppDelegate.openKeyboardSettings(_:)), to: nil, from: nil) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DisplaySettings: View {
    @ObservedObject var prefs: Preferences
    var body: some View {
        Form {
            Section("Images") {
                Toggle("Smooth interpolation when zoomed", isOn: $prefs.interpolate)
                Toggle("Orientation labels", isOn: $prefs.showOrientationLabels)
                Toggle("Scale bar", isOn: $prefs.showScaleBar)
                Stepper("Annotation font size: \(Int(prefs.overlayFontSize)) pt", value: $prefs.overlayFontSize, in: 8...24)
            }
            Section("Default layout") {
                Stepper("Rows: \(prefs.defaultLayoutRows)", value: $prefs.defaultLayoutRows, in: 1...6)
                Stepper("Columns: \(prefs.defaultLayoutColumns)", value: $prefs.defaultLayoutColumns, in: 1...6)
            }
            Section("Cine") {
                Toggle("Play ultrasound and angiography loops automatically", isOn: $prefs.cineAutoRun)
                Stepper("Default frame rate: \(Int(prefs.defaultCineFPS)) fps", value: $prefs.defaultCineFPS, in: 1...60)
            }
            Section("Synchronization defaults") {
                Toggle("Synchronize series automatically", isOn: $prefs.syncEnabled)
                Toggle("Slice position", isOn: $prefs.syncSlice)
                Toggle("Zoom & pan", isOn: $prefs.syncZoom)
                Toggle("Window settings", isOn: $prefs.syncWindow)
            }
            Section("MPR & 3D") {
                Toggle("Keep MPR axes centred", isOn: $prefs.mprAutoCenter)
                Picker("Volume rendering quality", selection: $prefs.vrQuality) {
                    Text("Favor performance").tag(0); Text("Balanced").tag(1); Text("Favor resolution").tag(2)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct OverlaySettings: View {
    @ObservedObject var prefs: Preferences
    @State private var setIndex = 0
    @State private var corner: OverlayCorner = .topLeft
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Set", selection: $setIndex) {
                    ForEach(prefs.overlay.sets.indices, id: \.self) { i in
                        let s = prefs.overlay.sets[i]
                        Text(s.modality.map { "\($0) (extends default)" } ?? (s.cine ? "Cine" : "Default")).tag(i)
                    }
                }
                Picker("Corner", selection: $corner) { ForEach(OverlayCorner.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
            List {
                ForEach(rows) { r in
                    HStack {
                        Text("Row \(r.row + 1)").foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                        Text(describe(r))
                        Spacer()
                        if r.hideWhenAnonymous { Image(systemName: "eye.slash").help("Hidden when patient data is hidden") }
                        if r.highlight { Image(systemName: "paintbrush.fill").foregroundStyle(.orange).help("Highlighted") }
                        Button { remove(r) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Menu("Add Item") {
                    ForEach(OverlayItem.allCases, id: \.self) { item in Button(item.title) { add(OverlayRow(nextRow, item)) } }
                }
                TextField("Tag (e.g. 0018,0015)", text: $newTag).frame(width: 160)
                Button("Add Tag") {
                    if let t = Tag(string: newTag) { add(OverlayRow(nextRow, tag: t, label: DataDictionary.name(for: t) + ": ")); newTag = "" }
                }
                Spacer()
                Button("Restore Defaults") { prefs.overlay = .radiantDefault }
            }
        }
    }

    var rows: [OverlayRow] { (prefs.overlay.sets[safe: setIndex]?.rows[corner] ?? []).sorted { $0.row < $1.row } }
    var nextRow: Int { (rows.map(\.row).max() ?? -1) + 1 }

    func describe(_ r: OverlayRow) -> String {
        if let i = r.item { return i.title }
        return r.elements.map { e in e.text ?? e.tag.map { DataDictionary.name(for: Tag(raw: $0)) } ?? "" }.joined()
    }

    func add(_ r: OverlayRow) {
        guard prefs.overlay.sets.indices.contains(setIndex) else { return }
        prefs.overlay.sets[setIndex].rows[corner, default: []].append(r)
    }

    func remove(_ r: OverlayRow) {
        guard prefs.overlay.sets.indices.contains(setIndex) else { return }
        prefs.overlay.sets[setIndex].rows[corner]?.removeAll { $0.id == r.id }
    }
}

private struct MeasurementSettings: View {
    @ObservedObject var prefs: Preferences
    var body: some View {
        Form {
            Picker("Length units", selection: $prefs.lengthUnits) {
                Text("Automatic").tag(0); Text("Millimetres").tag(1); Text("Centimetres").tag(2); Text("Metres").tag(3); Text("Micrometres").tag(4); Text("Nanometres").tag(5)
            }
            Stepper("Decimal places: \(prefs.lengthPrecision)", value: $prefs.lengthPrecision, in: 0...4)
            Toggle("Mark the middle of length measurements", isOn: $prefs.lengthMidMark)
            Toggle("Mark the centre of ellipses", isOn: $prefs.ellipseCenterMark)
            ColorPicker("Default colour", selection: Binding(get: { Color(nsColor: prefs.measurementColor.nsColor) }, set: { prefs.measurementColor = CodableColor(NSColor($0)) }))
            Text("Lengths on projection radiographs that use Imager Pixel Spacing are marked with * (not corrected for magnification). Use Calibrate Length for exact values.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct PresetSettings: View {
    @ObservedObject var prefs: Preferences
    @State private var name = ""
    @State private var modality = "CT"
    @State private var center = 40.0
    @State private var width = 400.0
    @State private var key = 8

    var body: some View {
        VStack(alignment: .leading) {
            Text("Built-in CT presets: Abdomen 60/400 (2), Angio 300/600 (3), Bone 300/1500 (4), Brain 40/80 (5), Chest 40/400 (6), Lungs −400/1500 (7). Keys 0 and 1 select full dynamic and the default window.")
                .font(.caption).foregroundStyle(.secondary)
            Table(prefs.userPresets) {
                TableColumn("Name", value: \.name)
                TableColumn("Modality") { p in Text(p.modality ?? "All") }
                TableColumn("Key") { p in Text(p.key.map(String.init) ?? "") }
                TableColumn("Level") { p in Text(DataSet.formatDS(p.center)) }
                TableColumn("Width") { p in Text(DataSet.formatDS(p.width)) }
                TableColumn("") { p in Button { prefs.userPresets.removeAll { $0.id == p.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }.width(30)
            }
            HStack {
                TextField("Name", text: $name).frame(width: 120)
                Picker("", selection: $modality) { ForEach(["CT", "MR", "CR", "DX", "MG", "PT", "NM", "US", "XA"], id: \.self) { Text($0) } }.frame(width: 70).labelsHidden()
                TextField("Level", value: $center, format: .number).frame(width: 64)
                TextField("Width", value: $width, format: .number).frame(width: 64)
                Picker("Key", selection: $key) { ForEach(2...9, id: \.self) { Text("\($0)") } }.frame(width: 80)
                Button("Add") {
                    guard !name.isEmpty else { return }
                    prefs.userPresets.append(WindowPreset(name: name, center: center, width: width, modality: modality, key: key))
                    name = ""
                }
            }
        }
    }
}

/// Short built-in help.
enum HelpWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Specula Help"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: HelpView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct HelpView: View {
    let sections: [(String, [(String, String)])] = [
        ("Opening studies", [("⌘O", "Open files, folders, DICOMDIR or ZIP archives"), ("⇧⌘O", "Open a CD/DVD"), ("⌘L", "Local library"), ("⌘K", "Search PACS"), ("Drag & drop", "Drop files on the window or the Dock icon")]),
        ("Browsing", [("Scroll / ↑ ↓", "Previous / next image"), ("← →", "Previous / next series"), ("Page Up / Down", "Skip images"), ("Home / End", "First / last image"), ("Space", "Play / stop cine"), ("Double-click", "Maximize panel")]),
        ("Mouse & trackpad", [("Left drag", "Active tool (Browse by default)"), ("Right drag", "Zoom"), ("Middle drag / ⌥-drag", "Window (brightness / contrast)"), ("⇧-drag", "Pan"), ("⌘-drag / pinch", "Zoom"), ("Rotate gesture", "Rotate by 90°"), ("⌃-click", "Context menu")]),
        ("Tools (keys in the image)", [("B W P Z", "Browse, Window, Pan, Zoom"), ("L A C E R G", "Length, Angle, Cobb, Ellipse, Rectangle, Polygon"), ("T X V", "Text, Arrow, Pixel probe"), ("0 – 9", "Full dynamic, default window, presets"), ("⌫", "Delete selected measurement")]),
        ("Image", [("⌘I", "Negative"), ("⌘] / ⌘[", "Rotate"), ("⌥⌘] / ⌥⌘[", "Flip"), ("⌘0 / ⌥⌘0", "Fit / actual size"), ("⌘J", "DICOM tags"), ("⇧⌘C", "Copy image")]),
        ("3D", [("⌥⌘M", "MPR"), ("⌥⌘V", "Volume rendering"), ("⌥⌘U", "PET-CT fusion"), ("⌥⌘S", "Subtraction (DSA)")]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Specula").font(.largeTitle.weight(.semibold))
                Text("A native macOS DICOM viewer. Not a certified medical device.").foregroundStyle(.secondary)
                ForEach(sections, id: \.0) { s in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.0).font(.headline)
                        ForEach(s.1, id: \.0) { k, v in
                            HStack(alignment: .firstTextBaseline) {
                                Text(k).font(.system(.body, design: .rounded).weight(.medium)).frame(width: 170, alignment: .leading)
                                Text(v).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
