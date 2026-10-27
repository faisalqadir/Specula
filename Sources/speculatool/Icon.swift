import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Draws the Specula app icon: a dark rounded square with a glowing axial cross-section.
enum IconRenderer {
    static func render(size: Int) -> CGImage {
        let s = CGFloat(size)
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
        // macOS icon grid: 824/1024 body with ~185 corner radius
        let inset = s * 100 / 1024
        let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let radius = body.width * 0.225
        let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(srgbRed: 0.10, green: 0.13, blue: 0.19, alpha: 1), CGColor(srgbRed: 0.02, green: 0.03, blue: 0.05, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        let c = CGPoint(x: body.midX, y: body.midY - body.height * 0.02)
        // body outline (ellipse), soft tissue glow
        let torso = CGRect(x: c.x - body.width * 0.34, y: c.y - body.height * 0.26, width: body.width * 0.68, height: body.height * 0.52)
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(srgbRed: 0.70, green: 0.76, blue: 0.82, alpha: 0.95), CGColor(srgbRed: 0.40, green: 0.46, blue: 0.54, alpha: 0.9)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addEllipse(in: torso)
        ctx.clip()
        ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: torso.width * 0.55, options: [])
        // rib ring
        ctx.setStrokeColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.94, alpha: 0.85))
        ctx.setLineWidth(torso.width * 0.025)
        ctx.strokeEllipse(in: torso.insetBy(dx: torso.width * 0.07, dy: torso.height * 0.08))
        // lungs (dark), kidney shaped
        ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.05, blue: 0.07, alpha: 1))
        for sx in [-1.0, 1.0] {
            let lung = CGRect(x: c.x + CGFloat(sx) * torso.width * 0.215 - torso.width * 0.135, y: c.y - torso.height * 0.27, width: torso.width * 0.27, height: torso.height * 0.58)
            ctx.addPath(CGPath(roundedRect: lung, cornerWidth: lung.width * 0.48, cornerHeight: lung.height * 0.38, transform: nil))
        }
        ctx.fillPath()
        // heart (mid grey, anterior / top in image coordinates = maxY here)
        ctx.setFillColor(CGColor(srgbRed: 0.62, green: 0.66, blue: 0.72, alpha: 1))
        ctx.addEllipse(in: CGRect(x: c.x - torso.width * 0.10, y: c.y + torso.height * 0.02, width: torso.width * 0.19, height: torso.height * 0.24))
        ctx.fillPath()
        // vertebra and aorta (bright, posterior = bottom)
        ctx.setFillColor(CGColor(srgbRed: 0.99, green: 0.99, blue: 0.97, alpha: 1))
        ctx.addEllipse(in: CGRect(x: c.x - torso.width * 0.065, y: torso.minY + torso.height * 0.10, width: torso.width * 0.13, height: torso.height * 0.17))
        ctx.addEllipse(in: CGRect(x: c.x + torso.width * 0.015, y: c.y - torso.height * 0.13, width: torso.width * 0.075, height: torso.width * 0.075))
        ctx.fillPath()
        ctx.restoreGState()
        // accent scan line
        ctx.setStrokeColor(CGColor(srgbRed: 0.25, green: 0.78, blue: 1.0, alpha: 0.95))
        ctx.setLineWidth(max(1, s * 0.012))
        ctx.setShadow(offset: .zero, blur: s * 0.025, color: CGColor(srgbRed: 0.25, green: 0.78, blue: 1.0, alpha: 0.9))
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: body.minX + body.width * 0.08, y: c.y - torso.height * 0.72))
        ctx.addLine(to: CGPoint(x: body.maxX - body.width * 0.08, y: c.y - torso.height * 0.72))
        ctx.strokePath()
        ctx.restoreGState()
        return ctx.makeImage()!
    }

    static func renderSet(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                           ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
            let url = dir.appendingPathComponent(name + ".png")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, render(size: px), nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
