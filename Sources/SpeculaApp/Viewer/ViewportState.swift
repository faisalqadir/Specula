import Foundation
import AppKit
import simd
import DICOMCore

enum Tool: String, CaseIterable, Codable {
    case browse, window, pan, zoom
    case length, angle, cobbAngle, ellipse, rectangle, closedPolygon, openPolygon, pencil, arrow, text, probe, deviation
    case cursor3D

    var title: String {
        switch self {
        case .browse: return "Browse"
        case .window: return "Window"
        case .pan: return "Pan"
        case .zoom: return "Zoom"
        case .length: return "Length"
        case .angle: return "Angle"
        case .cobbAngle: return "Cobb Angle"
        case .ellipse: return "Ellipse"
        case .rectangle: return "Rectangle"
        case .closedPolygon: return "Closed Polygon"
        case .openPolygon: return "Open Polygon"
        case .pencil: return "Pencil"
        case .arrow: return "Arrow"
        case .text: return "Text"
        case .probe: return "Pixel Probe"
        case .deviation: return "Deviation"
        case .cursor3D: return "3D Cursor"
        }
    }

    var symbol: String {
        switch self {
        case .browse: return "square.stack.3d.down.right"
        case .window: return "circle.lefthalf.filled"
        case .pan: return "hand.raised"
        case .zoom: return "plus.magnifyingglass"
        case .length: return "ruler"
        case .angle: return "angle"
        case .cobbAngle: return "line.diagonal.arrow"
        case .ellipse: return "circle.dashed"
        case .rectangle: return "rectangle.dashed"
        case .closedPolygon: return "pentagon"
        case .openPolygon: return "point.topleft.down.to.point.bottomright.curvepath"
        case .pencil: return "pencil.tip"
        case .arrow: return "arrow.up.left"
        case .text: return "textformat"
        case .probe: return "eyedropper"
        case .deviation: return "line.3.horizontal.decrease"
        case .cursor3D: return "scope"
        }
    }

    var isMeasurement: Bool {
        switch self {
        case .browse, .window, .pan, .zoom, .cursor3D: return false
        default: return true
        }
    }

    static let navigation: [Tool] = [.browse, .window, .pan, .zoom]
    static let measurements: [Tool] = [.length, .angle, .cobbAngle, .deviation, .ellipse, .rectangle, .closedPolygon, .openPolygon, .pencil, .arrow, .text, .probe]
}

struct WindowPreset: Identifiable, Equatable, Codable {
    var id: String { "\(modality ?? "*"):\(name)" }
    var name: String
    var center: Double
    var width: Double
    var modality: String?
    var key: Int?
    var minMax = false

    /// Built-in presets (values recovered from RadiAnt's preset table).
    static let ct: [WindowPreset] = [
        WindowPreset(name: "CT Abdomen", center: 60, width: 400, modality: "CT", key: 2),
        WindowPreset(name: "CT Angio", center: 300, width: 600, modality: "CT", key: 3),
        WindowPreset(name: "CT Bone", center: 300, width: 1500, modality: "CT", key: 4),
        WindowPreset(name: "CT Brain", center: 40, width: 80, modality: "CT", key: 5),
        WindowPreset(name: "CT Chest", center: 40, width: 400, modality: "CT", key: 6),
        WindowPreset(name: "CT Lungs", center: -400, width: 1500, modality: "CT", key: 7),
    ]

    static func presets(for modality: String) -> [WindowPreset] {
        var list: [WindowPreset]
        switch modality {
        case "CT": list = ct
        case "PT", "NM":
            list = []
        case "MG", "DX", "CR", "RF", "XA", "DR":
            list = zip([30.0, 125, 500, 1875, 3750, 7500, 15000, 30000], 2...9).map { WindowPreset(name: "\(Int($0.0 * 2)) / \(Int($0.0))", center: $0.0, width: $0.0 * 2, modality: modality, key: $0.1) }
        default:
            list = zip([20.0, 40, 80, 160, 320, 640, 1280, 2560], 2...9).map { WindowPreset(name: "\(Int($0.0 * 2)) / \(Int($0.0))", center: $0.0, width: $0.0 * 2, modality: modality, key: $0.1) }
        }
        let user = Preferences.shared.userPresets.filter { $0.modality == nil || $0.modality == modality }
        for u in user {
            if let k = u.key { list.removeAll { $0.key == k } }
            list.append(u)
        }
        return list
    }
}

/// Orthogonal screen-space transform (rotations by 90 degrees and flips).
struct OrthoTransform: Equatable {
    var a = 1, b = 0, c = 0, d = 1  // [a b; c d] applied to (x, y)

    static let identity = OrthoTransform()
    static let rotateCW = OrthoTransform(a: 0, b: -1, c: 1, d: 0)
    static let rotateCCW = OrthoTransform(a: 0, b: 1, c: -1, d: 0)
    static let flipH = OrthoTransform(a: -1, b: 0, c: 0, d: 1)
    static let flipV = OrthoTransform(a: 1, b: 0, c: 0, d: -1)

    /// Returns op ∘ self.
    func then(_ op: OrthoTransform) -> OrthoTransform {
        OrthoTransform(a: op.a * a + op.b * c, b: op.a * b + op.b * d, c: op.c * a + op.d * c, d: op.c * b + op.d * d)
    }

    func apply(_ p: CGPoint) -> CGPoint { CGPoint(x: CGFloat(a) * p.x + CGFloat(b) * p.y, y: CGFloat(c) * p.x + CGFloat(d) * p.y) }
    var inverse: OrthoTransform { OrthoTransform(a: d, b: -b, c: -c, d: a) } // orthogonal with det ±1: inverse = transpose
    var transposed: OrthoTransform { OrthoTransform(a: a, b: c, c: b, d: d) }
    var swapsAxes: Bool { a == 0 }
    var isFlipped: Bool { a * d - b * c < 0 }

    /// Rotation (in quarter turns clockwise) and whether a horizontal flip precedes it.
    var description: String {
        var flip = false
        var m = self
        if isFlipped { flip = true; m = OrthoTransform.flipH.then(m) }
        // m is now a pure rotation; find k such that rotateCW^k == m
        var r = OrthoTransform.identity
        var k = 0
        for i in 0..<4 { if r == m { k = i; break }; r = r.then(.rotateCW) }
        var parts: [String] = []
        switch k {
        case 1: parts.append("R: 90° CW")
        case 2: parts.append("R: 180°")
        case 3: parts.append("R: 90° CCW")
        default: break
        }
        if flip { parts.append("F: H") }
        return parts.joined(separator: " ")
    }
}

enum FitMode { case fit, fill, actual, custom }

struct DisplayState: Equatable {
    var windowCenter: Double = 0
    var windowWidth: Double = 0
    var windowName: String?
    var negative = false
    var zoom: Double = 1        // points per image pixel
    var pan = CGPoint.zero      // points
    var fitMode: FitMode = .fit
    var orientation = OrthoTransform.identity
    var filter: Int = 0         // 0 none, 1 smooth, 2 sharpen, 3 sharpen strong, 4 edge
    var colormap: Colormap = .gray
    var interpolate = true
    var initialized = false

    static let filterNames = ["", "Smooth", "Sharpen", "Sharpen+", "Edge enhance"]
}

struct CineState {
    var playing = false
    var fps: Double = 10
    var measuredFPS: Double = 0
}

/// DSA subtraction state.
struct SubtractionState {
    var enabled = false
    var maskIndex = 0
    var shift = CGPoint.zero
}

/// The model behind one viewport panel.
final class ViewportState {
    weak var session: ViewerSession?
    private(set) var series: Series?
    var index = 0
    var display = DisplayState()
    var cine = CineState()
    var subtraction = SubtractionState()
    var fusion: FusionLayer?
    var perSeriesDisplay: [ObjectIdentifier: (DisplayState, Int)] = [:]
    var syncOffset: Double = 0  // manual sync offset in mm
    var onChange: ((ViewportState) -> Void)?
    var loadError: String?

    var current: ImageRef? { series?.images[safe: index] }
    var imageCount: Int { series?.images.count ?? 0 }

    func setSeries(_ s: Series?, index startIndex: Int? = nil) {
        if let old = series { perSeriesDisplay[ObjectIdentifier(old)] = (display, index) }
        series = s
        subtraction = SubtractionState()
        cine.playing = false
        if let s, let saved = perSeriesDisplay[ObjectIdentifier(s)] {
            display = saved.0
            index = startIndex ?? min(saved.1, max(0, s.images.count - 1))
        } else {
            display = DisplayState()
            index = startIndex ?? 0
            if let s, let ft = s.first?.frameTimeMs, ft > 0 { cine.fps = min(60, max(1, 1000 / ft)) } else { cine.fps = Preferences.shared.defaultCineFPS }
        }
        loadError = nil
        changed()
    }

    func changed() { onChange?(self) }

    func setIndex(_ i: Int, wrap: Bool = false) {
        let n = imageCount
        guard n > 0 else { return }
        var j = i
        if wrap { j = ((i % n) + n) % n } else { j = max(0, min(n - 1, i)) }
        if j != index { index = j; changed() }
    }

    /// Applies default window from the image (or full dynamic range).
    func defaultWindow(for ref: ImageRef, frame: PixelFrame?) -> (Double, Double, String?) {
        let a = ref.attributes
        if let c = a.windowCenters.first, let w = a.windowWidths.first, w > 0 {
            return (c, w, ref.instance.windowExplanations.first)
        }
        if let f = frame {
            if f.isColor { return (127.5, 256, nil) }
            let lo = f.minValue * a.rescaleSlope + a.rescaleIntercept
            let hi = f.maxValue * a.rescaleSlope + a.rescaleIntercept
            return ((lo + hi) / 2, max(1, hi - lo), nil)
        }
        return (128, 256, nil)
    }

    func fullDynamic(frame: PixelFrame, ref: ImageRef) -> (Double, Double) {
        let a = ref.attributes
        let lo = min(frame.minValue, frame.maxValue) * a.rescaleSlope + a.rescaleIntercept
        let hi = max(frame.minValue, frame.maxValue) * a.rescaleSlope + a.rescaleIntercept
        return ((lo + hi) / 2, max(1, hi - lo))
    }
}

/// Fusion (PET over CT) layer bound to a viewport.
final class FusionLayer {
    let series: Series
    let volume: Volume
    var opacity: Double = 0.5
    var colormap: Colormap = .hotIron
    var windowCenter: Double
    var windowWidth: Double
    var threshold: Double = 0.05

    init(series: Series, volume: Volume) {
        self.series = series
        self.volume = volume
        let hi = volume.maxValue
        windowCenter = hi * 0.35
        windowWidth = hi * 0.7
    }
}
