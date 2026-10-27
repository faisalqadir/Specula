import Foundation
import AppKit
import DICOMCore

/// Mouse / trackpad actions that can be bound to buttons.
enum MouseAction: Int, CaseIterable, Codable {
    case activeTool = 0, browse = 1, zoom = 2, pan = 3, window = 4, roi = 5, none = 6

    var title: String {
        switch self {
        case .activeTool: return "Active tool"
        case .browse: return "Browse series"
        case .zoom: return "Zoom"
        case .pan: return "Pan"
        case .window: return "Window (brightness/contrast)"
        case .roi: return "Length measurement"
        case .none: return "Nothing"
        }
    }
}

/// App-wide settings stored in UserDefaults (mirrors RadiAnt's options.xml defaults).
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let d = UserDefaults.standard

    private func get<T>(_ k: String, _ def: T) -> T { (d.object(forKey: k) as? T) ?? def }

    // Mouse (RadiAnt defaults: left browse, middle window, right zoom, back pan, forward ROI)
    @Published var leftButton: MouseAction { didSet { d.set(leftButton.rawValue, forKey: "leftButton") } }
    @Published var rightButton: MouseAction { didSet { d.set(rightButton.rawValue, forKey: "rightButton") } }
    @Published var middleButton: MouseAction { didSet { d.set(middleButton.rawValue, forKey: "middleButton") } }
    @Published var backButton: MouseAction { didSet { d.set(backButton.rawValue, forKey: "backButton") } }
    @Published var forwardButton: MouseAction { didSet { d.set(forwardButton.rawValue, forKey: "forwardButton") } }
    @Published var wheelZooms: Bool { didSet { d.set(wheelZooms, forKey: "wheelZooms") } }
    @Published var horizontalWheelChangesSeries: Bool { didSet { d.set(horizontalWheelChangesSeries, forKey: "hwheelSeries") } }
    @Published var invertScroll: Bool { didSet { d.set(invertScroll, forKey: "invertScroll") } }
    @Published var windowDirections: Int { didSet { d.set(windowDirections, forKey: "windowDirs") } }
    @Published var zoomAroundCursor: Bool { didSet { d.set(zoomAroundCursor, forKey: "zoomAroundCursor") } }
    @Published var endlessScrolling: Bool { didSet { d.set(endlessScrolling, forKey: "endlessScrolling") } }

    // Sync
    @Published var syncEnabled: Bool { didSet { d.set(syncEnabled, forKey: "syncEnabled") } }
    @Published var syncSlice: Bool { didSet { d.set(syncSlice, forKey: "syncSlice") } }
    @Published var syncZoom: Bool { didSet { d.set(syncZoom, forKey: "syncZoom") } }
    @Published var syncWindow: Bool { didSet { d.set(syncWindow, forKey: "syncWindow") } }

    // Cine
    @Published var cineAutoRun: Bool { didSet { d.set(cineAutoRun, forKey: "cineAutoRun") } }
    @Published var defaultCineFPS: Double { didSet { d.set(defaultCineFPS, forKey: "cineFPS") } }

    // Loading
    @Published var autoShowFirstImage: Bool { didSet { d.set(autoShowFirstImage, forKey: "autoShow") } }
    @Published var studiesDescending: Bool { didSet { d.set(studiesDescending, forKey: "studiesDesc") } }
    @Published var loadNonImage: Bool { didSet { d.set(loadNonImage, forKey: "loadNonImage") } }
    @Published var showSeriesNumbers: Bool { didSet { d.set(showSeriesNumbers, forKey: "seriesNumbers") } }

    // Display
    @Published var overlayFontSize: Double { didSet { d.set(overlayFontSize, forKey: "overlayFont") } }
    @Published var showOrientationLabels: Bool { didSet { d.set(showOrientationLabels, forKey: "orientLabels") } }
    @Published var showScaleBar: Bool { didSet { d.set(showScaleBar, forKey: "scaleBar") } }
    @Published var interpolate: Bool { didSet { d.set(interpolate, forKey: "interpolate") } }
    @Published var defaultLayoutRows: Int { didSet { d.set(defaultLayoutRows, forKey: "layoutRows") } }
    @Published var defaultLayoutColumns: Int { didSet { d.set(defaultLayoutColumns, forKey: "layoutCols") } }
    @Published var closePanelClears: Bool { didSet { d.set(closePanelClears, forKey: "closeClears") } }
    @Published var forcedCharacterSet: String { didSet { d.set(forcedCharacterSet, forKey: "forcedCharset"); DICOMStringDecoder.forcedCharacterSet = forcedCharacterSet.isEmpty ? nil : forcedCharacterSet } }

    // Measurements
    @Published var lengthUnits: Int { didSet { d.set(lengthUnits, forKey: "lengthUnits") } }
    @Published var lengthPrecision: Int { didSet { d.set(lengthPrecision, forKey: "lengthPrecision") } }
    @Published var lengthMidMark: Bool { didSet { d.set(lengthMidMark, forKey: "lengthMid") } }
    @Published var ellipseCenterMark: Bool { didSet { d.set(ellipseCenterMark, forKey: "ellipseCenter") } }
    @Published var measurementColor: CodableColor { didSet { save(measurementColor, "measurementColor") } }

    // MPR / VR
    @Published var mprAutoCenter: Bool { didSet { d.set(mprAutoCenter, forKey: "mprAutoCenter") } }
    @Published var vrQuality: Int { didSet { d.set(vrQuality, forKey: "vrQuality") } }

    // Window presets defined by the user
    @Published var userPresets: [WindowPreset] { didSet { save(userPresets, "userPresets") } }

    // Library
    @Published var libraryPath: String { didSet { d.set(libraryPath, forKey: "libraryPath") } }
    @Published var importCopiesFiles: Bool { didSet { d.set(importCopiesFiles, forKey: "importCopies") } }
    @Published var showLibraryOnLaunch: Bool { didSet { d.set(showLibraryOnLaunch, forKey: "libraryOnLaunch") } }

    // Overlay configuration (corner annotations)
    @Published var overlay: OverlayConfiguration { didSet { save(overlay, "overlayConfig") } }

    // Keyboard shortcut overrides: command id -> "cmd+shift+K"
    @Published var shortcuts: [String: String] { didSet { save(shortcuts, "shortcuts") } }

    private func save<T: Encodable>(_ v: T, _ k: String) { d.set(try? JSONEncoder().encode(v), forKey: k) }
    private func load<T: Decodable>(_ k: String, _ def: T) -> T {
        guard let data = d.data(forKey: k), let v = try? JSONDecoder().decode(T.self, from: data) else { return def }
        return v
    }

    private init() {
        leftButton = MouseAction(rawValue: UserDefaults.standard.object(forKey: "leftButton") as? Int ?? 0) ?? .activeTool
        rightButton = MouseAction(rawValue: UserDefaults.standard.object(forKey: "rightButton") as? Int ?? 2) ?? .zoom
        middleButton = MouseAction(rawValue: UserDefaults.standard.object(forKey: "middleButton") as? Int ?? 4) ?? .window
        backButton = MouseAction(rawValue: UserDefaults.standard.object(forKey: "backButton") as? Int ?? 3) ?? .pan
        forwardButton = MouseAction(rawValue: UserDefaults.standard.object(forKey: "forwardButton") as? Int ?? 5) ?? .roi
        let ud = UserDefaults.standard
        func g<T>(_ k: String, _ def: T) -> T { (ud.object(forKey: k) as? T) ?? def }
        wheelZooms = g("wheelZooms", false)
        horizontalWheelChangesSeries = g("hwheelSeries", true)
        invertScroll = g("invertScroll", false)
        windowDirections = g("windowDirs", 0)
        zoomAroundCursor = g("zoomAroundCursor", true)
        endlessScrolling = g("endlessScrolling", true)
        syncEnabled = g("syncEnabled", true)
        syncSlice = g("syncSlice", true)
        syncZoom = g("syncZoom", true)
        syncWindow = g("syncWindow", false)
        cineAutoRun = g("cineAutoRun", true)
        defaultCineFPS = g("cineFPS", 10.0)
        autoShowFirstImage = g("autoShow", true)
        studiesDescending = g("studiesDesc", false)
        loadNonImage = g("loadNonImage", true)
        showSeriesNumbers = g("seriesNumbers", false)
        overlayFontSize = g("overlayFont", 12.0)
        showOrientationLabels = g("orientLabels", true)
        showScaleBar = g("scaleBar", true)
        interpolate = g("interpolate", true)
        defaultLayoutRows = g("layoutRows", 1)
        defaultLayoutColumns = g("layoutCols", 1)
        closePanelClears = g("closeClears", false)
        forcedCharacterSet = g("forcedCharset", "")
        lengthUnits = g("lengthUnits", 0)
        lengthPrecision = g("lengthPrecision", 2)
        lengthMidMark = g("lengthMid", false)
        ellipseCenterMark = g("ellipseCenter", false)
        mprAutoCenter = g("mprAutoCenter", true)
        vrQuality = g("vrQuality", 1)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        libraryPath = g("libraryPath", docs.appendingPathComponent("Specula Library").path)
        importCopiesFiles = g("importCopies", true)
        showLibraryOnLaunch = g("libraryOnLaunch", false)
        measurementColor = CodableColor(NSColor.systemYellow)
        userPresets = []
        overlay = OverlayConfiguration.radiantDefault
        shortcuts = [:]
        measurementColor = load("measurementColor", CodableColor(NSColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 1)))
        userPresets = load("userPresets", [])
        overlay = load("overlayConfig", OverlayConfiguration.radiantDefault)
        shortcuts = load("shortcuts", [:])
        if !forcedCharacterSet.isEmpty { DICOMStringDecoder.forcedCharacterSet = forcedCharacterSet }
    }

    func action(forButton b: Int) -> MouseAction {
        switch b {
        case 0: return leftButton
        case 1: return rightButton
        case 2: return middleButton
        case 3: return backButton
        case 4: return forwardButton
        default: return .none
        }
    }
}
