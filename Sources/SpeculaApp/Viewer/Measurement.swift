import Foundation
import AppKit
import DICOMCore

enum MeasurementKind: String, Codable {
    case length, angle, cobbAngle, ellipse, rectangle, closedPolygon, openPolygon, pencil, arrow, text, probe, deviation

    init?(tool: Tool) {
        switch tool {
        case .length: self = .length
        case .angle: self = .angle
        case .cobbAngle: self = .cobbAngle
        case .ellipse: self = .ellipse
        case .rectangle: self = .rectangle
        case .closedPolygon: self = .closedPolygon
        case .openPolygon: self = .openPolygon
        case .pencil: self = .pencil
        case .arrow: self = .arrow
        case .text: self = .text
        case .probe: self = .probe
        case .deviation: self = .deviation
        default: return nil
        }
    }

    /// Number of points for fixed-point shapes (nil = variable).
    var fixedPoints: Int? {
        switch self {
        case .length, .arrow, .ellipse, .rectangle: return 2
        case .angle: return 3
        case .cobbAngle, .deviation: return 4
        case .text, .probe: return 1
        default: return nil
        }
    }

    var isArea: Bool { self == .ellipse || self == .rectangle || self == .closedPolygon || self == .pencil }
}

struct MeasurementStyle: Codable, Equatable {
    var color: CodableColor = CodableColor(NSColor.systemYellow)
    var lineWidth: CGFloat = 1.5
    var fontSize: CGFloat = 12
    var fill = false
}

struct CodableColor: Codable, Equatable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    init(_ c: NSColor) {
        let s = c.usingColorSpace(.sRGB) ?? c
        r = s.redComponent; g = s.greenComponent; b = s.blueComponent; a = s.alphaComponent
    }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

struct Measurement: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: MeasurementKind
    var points: [CGPoint]          // image pixel coordinates (pixel centres at integer + 0.5? no: centre at integer)
    var text: String = ""
    var style = MeasurementStyle()
    var labelOffset = CGPoint(x: 12, y: -12)

    static func == (a: Measurement, b: Measurement) -> Bool { a.id == b.id && a.points == b.points && a.text == b.text && a.style == b.style }
}

/// Result of measuring a shape on an image.
struct MeasurementResult {
    var lines: [String]
}

enum MeasurementCalculator {
    static func distance(_ a: CGPoint, _ b: CGPoint, spacing: (Double, Double)?) -> Double {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        if let s = spacing { return sqrt(pow(dx * s.1, 2) + pow(dy * s.0, 2)) }
        return sqrt(dx * dx + dy * dy)
    }

    static func formatLength(_ mm: Double, calibrated: Bool, hasSpacing: Bool) -> String {
        guard hasSpacing else { return String(format: "%.1f px", mm) }
        let prefs = Preferences.shared
        let precision = prefs.lengthPrecision
        switch prefs.lengthUnits {
        case 1: return String(format: "%.\(precision)f mm", mm)
        case 2: return String(format: "%.\(precision)f cm", mm / 10)
        case 3: return String(format: "%.\(precision)f m", mm / 1000)
        case 4: return String(format: "%.\(precision)f µm", mm * 1000)
        case 5: return String(format: "%.\(precision)f nm", mm * 1e6)
        default:
            if mm < 0.1 { return String(format: "%.\(precision)f µm", mm * 1000) }
            if mm >= 1000 { return String(format: "%.\(precision)f m", mm / 1000) }
            return String(format: "%.\(precision)f mm", mm)
        }
    }

    static func angle(_ a: CGPoint, _ vertex: CGPoint, _ c: CGPoint, spacing: (Double, Double)?) -> Double {
        let sx = spacing?.1 ?? 1, sy = spacing?.0 ?? 1
        let v1 = (Double(a.x - vertex.x) * sx, Double(a.y - vertex.y) * sy)
        let v2 = (Double(c.x - vertex.x) * sx, Double(c.y - vertex.y) * sy)
        let dot = v1.0 * v2.0 + v1.1 * v2.1
        let l = sqrt(v1.0 * v1.0 + v1.1 * v1.1) * sqrt(v2.0 * v2.0 + v2.1 * v2.1)
        guard l > 0 else { return 0 }
        return acos(max(-1, min(1, dot / l))) * 180 / .pi
    }

    static func lineAngle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, spacing: (Double, Double)?) -> Double {
        let sx = spacing?.1 ?? 1, sy = spacing?.0 ?? 1
        let v1 = (Double(b.x - a.x) * sx, Double(b.y - a.y) * sy)
        let v2 = (Double(d.x - c.x) * sx, Double(d.y - c.y) * sy)
        let dot = v1.0 * v2.0 + v1.1 * v2.1
        let l = sqrt(v1.0 * v1.0 + v1.1 * v1.1) * sqrt(v2.0 * v2.0 + v2.1 * v2.1)
        guard l > 0 else { return 0 }
        var ang = acos(max(-1, min(1, dot / l))) * 180 / .pi
        if ang > 90 { ang = 180 - ang }
        return ang
    }

    /// Polygon outline for area shapes, in image pixel coordinates.
    static func outline(_ m: Measurement) -> [CGPoint] {
        switch m.kind {
        case .ellipse:
            guard m.points.count >= 2 else { return [] }
            let a = m.points[0], b = m.points[1]
            let cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2, rx = abs(b.x - a.x) / 2, ry = abs(b.y - a.y) / 2
            return (0..<96).map { i in
                let t = Double(i) / 96 * 2 * .pi
                return CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
            }
        case .rectangle:
            guard m.points.count >= 2 else { return [] }
            let a = m.points[0], b = m.points[1]
            return [a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y)]
        default:
            return m.points
        }
    }

    static func polygonArea(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            s += Double(a.x * b.y - b.x * a.y)
        }
        return abs(s) / 2
    }

    static func selfIntersects(_ pts: [CGPoint]) -> Bool {
        let n = pts.count
        guard n >= 4 else { return false }
        func ccw(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool { (c.y - a.y) * (b.x - a.x) > (b.y - a.y) * (c.x - a.x) }
        func inter(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool { ccw(a, c, d) != ccw(b, c, d) && ccw(a, b, c) != ccw(a, b, d) }
        if n > 400 { return false }
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            var j = i + 2
            while j < n {
                if !(i == 0 && j == n - 1), inter(a, b, pts[j], pts[(j + 1) % n]) { return true }
                j += 1
            }
        }
        return false
    }

    static func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    struct Stats { var count = 0; var mean = 0.0; var sd = 0.0; var min = 0.0; var max = 0.0; var sum = 0.0 }

    static func stats(polygon: [CGPoint], frame: PixelFrame, slope: Double, intercept: Double, transform: ((Double) -> Double)? = nil) -> Stats {
        guard polygon.count >= 3 else { return Stats() }
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        let x0 = max(0, Int(floor(xs.min()!))), x1 = min(frame.width - 1, Int(ceil(xs.max()!)))
        let y0 = max(0, Int(floor(ys.min()!))), y1 = min(frame.height - 1, Int(ceil(ys.max()!)))
        guard x0 <= x1, y0 <= y1 else { return Stats() }
        var s = Stats(); s.min = .greatestFiniteMagnitude; s.max = -.greatestFiniteMagnitude
        var sum2 = 0.0
        // Scanline fill using pixel centres
        for y in y0...y1 {
            let py = CGFloat(y)
            var crossings: [CGFloat] = []
            var j = polygon.count - 1
            for i in 0..<polygon.count {
                let a = polygon[i], b = polygon[j]
                if (a.y > py) != (b.y > py) { crossings.append((b.x - a.x) * (py - a.y) / (b.y - a.y) + a.x) }
                j = i
            }
            crossings.sort()
            var k = 0
            while k + 1 < crossings.count {
                let xa = max(x0, Int(ceil(crossings[k]))), xb = min(x1, Int(floor(crossings[k + 1])))
                if xa <= xb {
                    for x in xa...xb {
                        guard var v = frame.storedValue(x: x, y: y) else { continue }
                        v = v * slope + intercept
                        if let t = transform { v = t(v) }
                        s.count += 1; s.sum += v; sum2 += v * v
                        s.min = min(s.min, v); s.max = max(s.max, v)
                    }
                }
                k += 2
            }
        }
        if s.count > 0 {
            s.mean = s.sum / Double(s.count)
            s.sd = sqrt(max(0, sum2 / Double(s.count) - s.mean * s.mean))
        } else { s.min = 0; s.max = 0 }
        return s
    }

    /// Text lines shown next to a measurement.
    static func describe(_ m: Measurement, ref: ImageRef?, frame: PixelFrame?, calibration: Double?) -> [String] {
        let rawSpacing = ref.flatMap { $0.instance.pixelSpacing(frame: $0.frame) }
        let spacing: (Double, Double)? = calibration.map { ($0, $0) } ?? rawSpacing
        let hasSpacing = spacing != nil
        let pts = m.points
        func len(_ a: CGPoint, _ b: CGPoint) -> String { formatLength(distance(a, b, spacing: spacing), calibrated: calibration != nil, hasSpacing: hasSpacing) }
        switch m.kind {
        case .length:
            guard pts.count >= 2 else { return [] }
            var s = [len(pts[0], pts[1])]
            if ref?.instance.effectiveSpacingSource == .imagerPixelSpacing && calibration == nil { s[0] += " *" }
            return s
        case .arrow, .text: return m.text.isEmpty ? [] : [m.text]
        case .angle:
            guard pts.count >= 3 else { return [] }
            return [String(format: "%.1f°", angle(pts[0], pts[1], pts[2], spacing: spacing))]
        case .cobbAngle:
            guard pts.count >= 4 else { return [] }
            return [String(format: "%.1f°", lineAngle(pts[0], pts[1], pts[2], pts[3], spacing: spacing))]
        case .deviation:
            guard pts.count >= 3 else { return [] }
            // perpendicular distance from point(s) to the base line
            let a = pts[0], b = pts[1]
            var out: [String] = []
            for p in pts.dropFirst(2) {
                let sx = spacing?.1 ?? 1, sy = spacing?.0 ?? 1
                let ab = (Double(b.x - a.x) * sx, Double(b.y - a.y) * sy), ap = (Double(p.x - a.x) * sx, Double(p.y - a.y) * sy)
                let l = sqrt(ab.0 * ab.0 + ab.1 * ab.1)
                let dist = l > 0 ? abs(ab.0 * ap.1 - ab.1 * ap.0) / l : 0
                out.append(formatLength(dist, calibrated: calibration != nil, hasSpacing: hasSpacing))
            }
            return out
        case .openPolygon:
            guard pts.count >= 2 else { return [] }
            var total = 0.0
            for i in 1..<pts.count { total += distance(pts[i - 1], pts[i], spacing: spacing) }
            return [formatLength(total, calibrated: calibration != nil, hasSpacing: hasSpacing)]
        case .probe:
            guard let p = pts.first, let ref, let frame else { return [] }
            let x = Int(p.x.rounded()), y = Int(p.y.rounded())
            if frame.isColor, let (r, g, b) = frame.rgb(x: x, y: y) { return ["R \(r) G \(g) B \(b)"] }
            guard let v = frame.storedValue(x: x, y: y) else { return [] }
            let a = ref.attributes
            let mv = v * a.rescaleSlope + a.rescaleIntercept
            var lines = [String(format: "%@ %@", DataSet.formatDS(mv), unitLabel(ref))]
            if let suv = SUV.factor(ref) { lines.append(String(format: "SUVbw %.2f", mv * suv)) }
            return lines
        case .ellipse, .rectangle, .closedPolygon, .pencil:
            let poly = outline(m)
            guard poly.count >= 3 else { return [] }
            if m.kind == .closedPolygon || m.kind == .pencil, selfIntersects(poly) {
                return ["The area cannot be calculated", "for self-intersecting polygons."]
            }
            var lines: [String] = []
            let areaPx = polygonArea(poly)
            if let s = spacing {
                let mm2 = areaPx * s.0 * s.1
                lines.append(mm2 >= 100 ? String(format: "Area: %.2f cm²", mm2 / 100) : String(format: "Area: %.2f mm²", mm2))
            } else {
                lines.append(String(format: "Area: %.0f px²", areaPx))
            }
            if let ref, let frame, !frame.isColor {
                let a = ref.attributes
                let st = stats(polygon: poly, frame: frame, slope: a.rescaleSlope, intercept: a.rescaleIntercept)
                let u = unitLabel(ref)
                lines.append(String(format: "Mean: %.2f %@ SD: %.2f", st.mean, u, st.sd))
                lines.append(String(format: "Min: %@ Max: %@", DataSet.formatDS(st.min), DataSet.formatDS(st.max)))
                if let suv = SUV.factor(ref) {
                    lines.append(String(format: "SUVbw mean %.2f max %.2f", st.mean * suv, st.max * suv))
                }
            }
            return lines
        }
    }

    static func unitLabel(_ ref: ImageRef) -> String {
        if ref.instance.modality == "CT" { return "HU" }
        if let u = ref.instance.string(.units) {
            switch u.uppercased() {
            case "BQML": return "Bq/ml"
            case "GML": return "g/ml"
            default: return u
            }
        }
        return ""
    }
}

/// SUV body-weight factor for PET images (activity concentration -> g/ml).
enum SUV {
    static func factor(_ ref: ImageRef) -> Double? {
        let inst = ref.instance
        guard inst.modality == "PT" else { return nil }
        let h = inst.header
        let units = (h.string(.units) ?? "").uppercased()
        if units == "GML" { return 1 }
        guard units == "BQML", let weightKg = h.double(.patientWeight), weightKg > 0,
              let radio = h.sequence(.radiopharmaceuticalInformationSequence)?.first,
              let dose = radio.double(.radionuclideTotalDose), dose > 0,
              let half = radio.double(.radionuclideHalfLife), half > 0 else { return nil }
        // Time of injection and scan reference time
        var injection: Double?
        if let dt = DICOMDate.dateTime(radio.string(.radiopharmaceuticalStartDateTime)) { injection = dt.timeIntervalSince(Calendar.current.startOfDay(for: dt)) }
        else { injection = DICOMDate.parseTime(radio.string(.radiopharmaceuticalStartTime)) }
        let decay = (h.string(.decayCorrection) ?? "START").uppercased()
        let scanTime = DICOMDate.parseTime(h.string(.seriesTime)) ?? DICOMDate.parseTime(h.string(.acquisitionTime))
        var decayedDose = dose
        if decay == "START", let inj = injection, let st = scanTime {
            var dt = st - inj
            if dt < 0 { dt += 86400 }
            decayedDose = dose * pow(2, -dt / half)
        }
        return weightKg * 1000 / decayedDose
    }
}
