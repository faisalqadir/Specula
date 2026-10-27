import Foundation
import simd

enum SlabMode: Int, CaseIterable {
    case mpr = 0, mip = 1, minip = 2, average = 3
    var title: String {
        switch self {
        case .mpr: return "MPR"
        case .mip: return "MIP"
        case .minip: return "MinIP"
        case .average: return "Avg"
        }
    }
}

enum MPROrientation: Int, CaseIterable {
    case axial, coronal, sagittal
    var title: String { ["Axial", "Coronal", "Sagittal"][rawValue] }
    var color: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .axial: return (0.25, 0.55, 1.0)
        case .coronal: return (0.3, 0.85, 0.35)
        case .sagittal: return (1.0, 0.35, 0.3)
        }
    }

    /// Default in-plane axes (screen right, screen down) in patient coordinates, radiological convention.
    var axes: (Vec3, Vec3) {
        switch self {
        case .axial: return (Vec3(1, 0, 0), Vec3(0, 1, 0))      // right = patient left, down = posterior
        case .coronal: return (Vec3(1, 0, 0), Vec3(0, 0, -1))   // right = patient left, down = feet
        case .sagittal: return (Vec3(0, 1, 0), Vec3(0, 0, -1))  // right = posterior, down = feet
        }
    }
}

/// A reformatted plane through a volume.
final class MPRPlane {
    let volume: Volume
    let orientation: MPROrientation
    var center: Vec3            // crosshair point (patient mm)
    var u: Vec3                 // screen right
    var v: Vec3                 // screen down
    var thickness: Double = 0   // slab thickness (mm), 0 = single slice
    var mode: SlabMode = .mpr
    let pixelSize: Double

    init(volume: Volume, orientation: MPROrientation) {
        self.volume = volume
        self.orientation = orientation
        center = volume.center
        (u, v) = orientation.axes
        pixelSize = min(volume.spacing.x, volume.spacing.y, volume.spacing.z)
        // Snap the default axes to the volume's own axes when the acquisition is oblique
        let axesVol = [volume.rowDir, volume.colDir, volume.sliceDir.cross(volume.rowDir).cross(volume.rowDir) * -1]
        _ = axesVol
    }

    var normal: Vec3 { u.cross(v).normalized }

    /// Grid covering the volume footprint, anchored to the volume centre so it does not drift while scrolling.
    var grid: (origin: Vec3, width: Int, height: Int) {
        let vc = volume.center
        let n = normal
        let base = vc + n * (center - vc).dot(n)
        var minU = Double.greatestFiniteMagnitude, maxU = -Double.greatestFiniteMagnitude
        var minV = Double.greatestFiniteMagnitude, maxV = -Double.greatestFiniteMagnitude
        for i in [-0.5, Double(volume.width) - 0.5] {
            for j in [-0.5, Double(volume.height) - 0.5] {
                for k in [-0.5, Double(volume.depth) - 0.5] {
                    let p = volume.patient(i: i, j: j, k: k) - base
                    minU = min(minU, p.dot(u)); maxU = max(maxU, p.dot(u))
                    minV = min(minV, p.dot(v)); maxV = max(maxV, p.dot(v))
                }
            }
        }
        let w = max(1, Int(((maxU - minU) / pixelSize).rounded(.up)))
        let h = max(1, Int(((maxV - minV) / pixelSize).rounded(.up)))
        let origin = base + u * (minU + pixelSize / 2) + v * (minV + pixelSize / 2)
        return (origin, w, h)
    }

    var imagePlane: ImagePlane {
        let g = grid
        return ImagePlane(position: g.origin, rowDirection: u, columnDirection: v, rowSpacing: pixelSize, columnSpacing: pixelSize, rows: g.height, columns: g.width, thickness: thickness > 0 ? thickness : nil)
    }

    /// Plane pixel (center space) of the crosshair.
    var centerPixel: CGPoint {
        let p = imagePlane.pixel(of: center)
        return CGPoint(x: p.x, y: p.y)
    }

    /// Maps plane pixel (x, y, 0, 1) -> volume texture coordinate.
    func planeToTexture() -> simd_float4x4 {
        let g = grid
        let m = volume.patientToTex
        var p = matrix_identity_float4x4
        let su = u * pixelSize, sv = v * pixelSize
        p[0] = SIMD4<Float>(Float(su.x), Float(su.y), Float(su.z), 0)
        p[1] = SIMD4<Float>(Float(sv.x), Float(sv.y), Float(sv.z), 0)
        p[2] = SIMD4<Float>(0, 0, 0, 0)
        p[3] = SIMD4<Float>(Float(g.origin.x), Float(g.origin.y), Float(g.origin.z), 1)
        return m * p
    }

    /// Slab sampling: (samples, texture-space step).
    func slab() -> (Int32, SIMD4<Float>) {
        let m = volume.patientToTex
        let n = normal
        let step = min(volume.spacing.x, volume.spacing.y, volume.spacing.z) * 0.75
        let count = thickness > step ? Int(thickness / step) + 1 : 1
        let d = n * step
        let t = m * SIMD4<Float>(Float(d.x), Float(d.y), Float(d.z), 0)
        return (Int32(min(count, 512)), t)
    }

    /// Moves the plane along its normal by mm.
    func move(by mm: Double) {
        center += normal * mm
        clampCenter()
    }

    func clampCenter() {
        let vox = volume.voxel(of: center)
        let c = Vec3(max(0, min(Double(volume.width - 1), vox.x)), max(0, min(Double(volume.height - 1), vox.y)), max(0, min(Double(volume.depth - 1), vox.z)))
        center = volume.patient(i: c.x, j: c.y, k: c.z)
    }

    /// Distance of the crosshair along the normal from the volume start (for "Im: x/y" display).
    var sliceInfo: (index: Int, count: Int) {
        let n = normal
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for i in [0.0, Double(volume.width - 1)] { for j in [0.0, Double(volume.height - 1)] { for k in [0.0, Double(volume.depth - 1)] {
            let d = volume.patient(i: i, j: j, k: k).dot(n); lo = min(lo, d); hi = max(hi, d)
        } } }
        let step = abs(n.dot(volume.sliceDir)) > 0.9 ? volume.spacing.z : pixelSize
        let count = max(1, Int(((hi - lo) / step).rounded()) + 1)
        let idx = Int(((center.dot(n) - lo) / step).rounded())
        return (max(0, min(count - 1, idx)), count)
    }

    var stepMM: Double { abs(normal.dot(volume.sliceDir)) > 0.9 ? volume.spacing.z : pixelSize }

    /// Rotates the in-plane axes around an axis through the centre.
    func rotate(axis: Vec3, angle: Double) {
        let q = simd_quatd(angle: angle, axis: axis.normalized)
        u = q.act(u).normalized
        v = q.act(v).normalized
    }
}
