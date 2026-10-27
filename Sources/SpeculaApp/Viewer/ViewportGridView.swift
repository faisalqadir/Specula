import AppKit
import DICOMCore

/// Lays out viewport panels in a rows x columns grid with hairline separators.
final class ViewportGridView: NSView {
    weak var session: ViewerSession?
    private let gap: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func rebuild() {
        guard let s = session else { return }
        subviews.forEach { $0.removeFromSuperview() }
        if let m = s.maximized {
            addSubview(m)
        } else {
            for v in s.viewports { addSubview(v) }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard let s = session else { return }
        if let m = s.maximized {
            m.frame = bounds
            m.needsRedraw()
            return
        }
        let rows = s.layout.rows, cols = s.layout.columns
        let w = (bounds.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let h = (bounds.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        for (i, v) in s.viewports.enumerated() {
            let r = i / cols, c = i % cols
            v.frame = CGRect(x: CGFloat(c) * (w + gap), y: CGFloat(r) * (h + gap), width: w, height: h).integral
            v.needsRedraw()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        session?.open(urls: urls)
        return true
    }
}

/// Generates series thumbnails in the background.
final class ThumbnailGenerator {
    static let shared = ThumbnailGenerator()
    private let queue = OperationQueue()

    init() {
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .utility
    }

    func generate(for series: [Series]) {
        for s in series {
            guard let ref = s.middleImage(), s.kind == .image || s.kind == .video else { continue }
            if s.thumbnail != nil && s.imageCount > 1 { continue }
            queue.addOperation {
                guard let f = try? FrameCache.shared.decode(ref) else { return }
                let img = ThumbnailGenerator.render(f, ref: ref, size: 128)
                DispatchQueue.main.async { s.thumbnail = img }
            }
        }
    }

    /// CPU rendering of a frame with its default window (used for thumbnails and drag images).
    static func render(_ f: PixelFrame, ref: ImageRef, size: Int) -> NSImage? {
        let scale = min(1, Double(size) / Double(max(f.width, f.height)))
        let w = max(1, Int(Double(f.width) * scale)), h = max(1, Int(Double(f.height) * scale))
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let a = ref.attributes
        var c: Double, ww: Double
        if let cc = a.windowCenters.first, let w0 = a.windowWidths.first, w0 > 0 { c = cc; ww = w0 }
        else {
            let lo = f.minValue * a.rescaleSlope + a.rescaleIntercept, hi = f.maxValue * a.rescaleSlope + a.rescaleIntercept
            c = (lo + hi) / 2; ww = max(1, hi - lo)
        }
        let invert = ref.instance.isMonochrome1
        for y in 0..<h {
            let sy = min(f.height - 1, Int(Double(y) / scale))
            for x in 0..<w {
                let sx = min(f.width - 1, Int(Double(x) / scale))
                let o = (y * w + x) * 4
                if f.isColor, let (r, g, b) = f.rgb(x: sx, y: sy) {
                    out[o] = r; out[o + 1] = g; out[o + 2] = b
                } else if let v = f.storedValue(x: sx, y: sy) {
                    let mv = v * a.rescaleSlope + a.rescaleIntercept
                    var t = (mv - (c - 0.5)) / max(1, ww - 1) + 0.5
                    t = max(0, min(1, t))
                    if invert { t = 1 - t }
                    let g = UInt8(t * 255)
                    out[o] = g; out[o + 1] = g; out[o + 2] = g
                }
                out[o + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }
}
