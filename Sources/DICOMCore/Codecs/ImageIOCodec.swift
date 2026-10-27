import Foundation
import ImageIO
import CoreGraphics

/// Generic ImageIO-backed decoding (used for JPEG XL and as a JPEG 2000 fallback).
public enum ImageIOCodec {
    public static func decode(_ data: Data, typeHint: String) throws -> DecodedImage {
        let opts: [CFString: Any] = [kCGImageSourceTypeIdentifierHint: typeHint as CFString, kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw DICOMError.decode("ImageIO could not decode \(typeHint)") }
        let w = img.width, h = img.height
        let gray = (img.colorSpace?.numberOfComponents ?? 3) == 1
        let comps = gray ? 1 : 3
        let bpc = img.bitsPerComponent > 8 ? 16 : 8
        var samples = [UInt16](repeating: 0, count: w * h * comps)
        if bpc == 16 {
            var buf = [UInt16](repeating: 0, count: w * h * (gray ? 1 : 4))
            let space = gray ? CGColorSpaceCreateDeviceGray() : (img.colorSpace ?? CGColorSpaceCreateDeviceRGB())
            let info = (gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue) | CGBitmapInfo.byteOrder16Little.rawValue
            guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * (gray ? 2 : 8), space: space, bitmapInfo: info) else { throw DICOMError.decode("context") }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            for i in 0..<(w * h) { for c in 0..<comps { samples[i * comps + c] = buf[i * (gray ? 1 : 4) + c] } }
        } else {
            var buf = [UInt8](repeating: 0, count: w * h * (gray ? 1 : 4))
            let space = gray ? CGColorSpaceCreateDeviceGray() : (img.colorSpace ?? CGColorSpaceCreateDeviceRGB())
            let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
            guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * (gray ? 1 : 4), space: space, bitmapInfo: info) else { throw DICOMError.decode("context") }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            for i in 0..<(w * h) { for c in 0..<comps { samples[i * comps + c] = UInt16(buf[i * (gray ? 1 : 4) + c]) } }
        }
        return DecodedImage(width: w, height: h, components: comps, precision: bpc, samples: samples, isRGB: !gray)
    }
}
