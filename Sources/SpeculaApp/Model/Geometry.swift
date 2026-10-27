import Foundation
import simd

typealias Vec3 = SIMD3<Double>

extension SIMD3 where Scalar == Double {
    var length: Double { simd_length(self) }
    var normalized: Vec3 { let l = simd_length(self); return l > 0 ? self / l : self }
    func dot(_ o: Vec3) -> Double { simd_dot(self, o) }
    func cross(_ o: Vec3) -> Vec3 { simd_cross(self, o) }
}

/// Patient-space geometry of one 2D image (frame).
struct ImagePlane: Equatable {
    var position: Vec3          // centre of the first (top-left) pixel, mm
    var rowDirection: Vec3      // direction of increasing column index (along a row)
    var columnDirection: Vec3   // direction of increasing row index (down a column)
    var rowSpacing: Double      // mm between rows (vertical pixel size)
    var columnSpacing: Double   // mm between columns (horizontal pixel size)
    var rows: Int
    var columns: Int
    var thickness: Double?

    var normal: Vec3 { rowDirection.cross(columnDirection).normalized }

    /// Patient coordinate of pixel (x = column, y = row), fractional allowed.
    func patientPoint(x: Double, y: Double) -> Vec3 {
        position + rowDirection * (x * columnSpacing) + columnDirection * (y * rowSpacing)
    }

    /// Projects a patient point into fractional pixel coordinates (and signed distance from plane).
    func pixel(of p: Vec3) -> (x: Double, y: Double, distance: Double) {
        let d = p - position
        return (d.dot(rowDirection) / columnSpacing, d.dot(columnDirection) / rowSpacing, d.dot(normal))
    }

    var center: Vec3 { patientPoint(x: Double(columns - 1) / 2, y: Double(rows - 1) / 2) }

    var corners: [Vec3] {
        [patientPoint(x: -0.5, y: -0.5), patientPoint(x: Double(columns) - 0.5, y: -0.5),
         patientPoint(x: Double(columns) - 0.5, y: Double(rows) - 0.5), patientPoint(x: -0.5, y: Double(rows) - 0.5)]
    }

    /// Intersection line of another plane with this plane, as two pixel-space endpoints clipped to this image.
    func intersection(with other: ImagePlane) -> (CGPoint, CGPoint)? {
        let n1 = normal, n2 = other.normal
        let dir = n1.cross(n2)
        guard dir.length > 1e-3 else { return nil } // parallel
        // Point on both planes: solve with plane equations n·x = d
        let d1 = n1.dot(position), d2 = n2.dot(other.position)
        let n1n2 = n1.dot(n2)
        let det = 1 - n1n2 * n1n2
        let c1 = (d1 - d2 * n1n2) / det
        let c2 = (d2 - d1 * n1n2) / det
        let p0 = n1 * c1 + n2 * c2
        // Clip line p0 + t*dir to the other image's extent first (so we only draw its footprint)
        let corners = other.corners
        var ts: [Double] = []
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            // intersect line with segment a-b inside other's plane
            let e = b - a
            let m = dir.cross(e)
            let mlen2 = m.dot(m)
            if mlen2 < 1e-12 { continue }
            let t = (a - p0).cross(e).dot(m) / mlen2
            let s = (a - p0).cross(dir).dot(m) / mlen2
            if s >= -1e-6 && s <= 1 + 1e-6 { ts.append(t) }
        }
        guard let t0 = ts.min(), let t1 = ts.max(), t1 - t0 > 1e-6 else { return nil }
        let a = pixel(of: p0 + dir * t0), b = pixel(of: p0 + dir * t1)
        return (CGPoint(x: a.x, y: a.y), CGPoint(x: b.x, y: b.y))
    }

    /// Patient orientation label for a direction vector (e.g. "L", "PF", "RAH").
    static func orientationLabel(_ v: Vec3, maxLetters: Int = 2) -> String {
        var labels: [(Double, String)] = []
        let x = v.x, y = v.y, z = v.z
        labels.append((abs(x), x > 0 ? "L" : "R"))
        labels.append((abs(y), y > 0 ? "P" : "A"))
        labels.append((abs(z), z > 0 ? "H" : "F"))
        labels.sort { $0.0 > $1.0 }
        var s = ""
        for (mag, l) in labels.prefix(maxLetters) where mag > 0.25 { s += l }
        if s.isEmpty, let first = labels.first { s = first.1 }
        // RadiAnt-style uses S/I for head/feet
        return s.replacingOccurrences(of: "H", with: "S").replacingOccurrences(of: "F", with: "I")
    }
}

/// Converts DICOM orientation letters ("L", "P", "H", "F", "A", "R") of Patient Orientation (0020,0020)
/// to display labels.
enum OrientationText {
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "H", with: "S").replacingOccurrences(of: "F", with: "I")
    }

    static func opposite(_ s: String) -> String {
        String(s.map { c -> Character in
            switch c {
            case "L": return "R"; case "R": return "L"
            case "A": return "P"; case "P": return "A"
            case "S", "H": return "I"; case "I", "F": return "S"
            default: return c
            }
        })
    }
}
