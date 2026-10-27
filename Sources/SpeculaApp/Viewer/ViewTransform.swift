import Foundation
import CoreGraphics
import simd

/// Maps image pixel coordinates (pixel centres at integers) to view points (y down) and NDC.
struct ViewTransform {
    var imageSize: CGSize
    var aspect: CGFloat          // displayed height scale (row spacing / column spacing)
    var zoom: CGFloat
    var pan: CGPoint
    var ortho: OrthoTransform
    var viewSize: CGSize

    func toView(_ p: CGPoint) -> CGPoint {
        let c = CGPoint(x: p.x + 0.5 - imageSize.width / 2, y: (p.y + 0.5 - imageSize.height / 2) * aspect)
        let r = ortho.apply(c)
        return CGPoint(x: viewSize.width / 2 + pan.x + r.x * zoom, y: viewSize.height / 2 + pan.y + r.y * zoom)
    }

    func toImage(_ v: CGPoint) -> CGPoint {
        let r = CGPoint(x: (v.x - viewSize.width / 2 - pan.x) / zoom, y: (v.y - viewSize.height / 2 - pan.y) / zoom)
        let c = ortho.inverse.apply(r)
        return CGPoint(x: c.x + imageSize.width / 2 - 0.5, y: c.y / aspect + imageSize.height / 2 - 0.5)
    }

    /// Edge-space pixel (0...W, 0...H) -> NDC.
    var ndcMatrix: simd_float4x4 {
        let W = Float(imageSize.width), H = Float(imageSize.height)
        let t1 = simd_float4x4(translation: SIMD3(-W / 2, -H / 2, 0))
        let s1 = simd_float4x4(scale: SIMD3(1, Float(aspect), 1))
        var o = matrix_identity_float4x4
        o[0][0] = Float(ortho.a); o[1][0] = Float(ortho.b)
        o[0][1] = Float(ortho.c); o[1][1] = Float(ortho.d)
        let s2 = simd_float4x4(scale: SIMD3(Float(zoom), Float(zoom), 1))
        let t2 = simd_float4x4(translation: SIMD3(Float(viewSize.width / 2 + pan.x), Float(viewSize.height / 2 + pan.y), 0))
        var n = matrix_identity_float4x4
        n[0][0] = 2 / Float(viewSize.width); n[3][0] = -1
        n[1][1] = -2 / Float(viewSize.height); n[3][1] = 1
        return n * t2 * s2 * o * s1 * t1
    }

    /// Size of the displayed image in points at zoom 1 (after rotation).
    var displayedUnitSize: CGSize {
        let w = imageSize.width, h = imageSize.height * aspect
        return ortho.swapsAxes ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    func fitZoom(fill: Bool = false) -> CGFloat {
        let s = displayedUnitSize
        guard s.width > 0, s.height > 0, viewSize.width > 0, viewSize.height > 0 else { return 1 }
        let zx = viewSize.width / s.width, zy = viewSize.height / s.height
        return fill ? max(zx, zy) : min(zx, zy)
    }
}

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        self[3] = SIMD4(t.x, t.y, t.z, 1)
    }

    init(scale s: SIMD3<Float>) {
        self = matrix_identity_float4x4
        self[0][0] = s.x; self[1][1] = s.y; self[2][2] = s.z
    }
}

extension CGPoint {
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
    var length: CGFloat { sqrt(x * x + y * y) }
    func distance(to p: CGPoint) -> CGFloat { (self - p).length }

    /// Distance from this point to segment a-b.
    func distance(toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = b - a, ap = self - a
        let l2 = ab.x * ab.x + ab.y * ab.y
        if l2 == 0 { return ap.length }
        let t = max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / l2))
        return (a + ab * t).distance(to: self)
    }
}
