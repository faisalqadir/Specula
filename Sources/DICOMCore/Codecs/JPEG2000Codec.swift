import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// JPEG 2000 decoding via ImageIO, with codestream inspection to restore
/// precision and signedness that CGImage cannot express.
public enum JPEG2000Codec {
    public struct SIZInfo {
        public var width: Int
        public var height: Int
        public var components: Int
        public var precision: Int
        public var signed: Bool
    }

    /// Parses the SIZ marker of a raw codestream (or JP2 box structure).
    public static func siz(_ data: Data) -> SIZInfo? {
        let b = [UInt8](data.prefix(4096))
        var i = 0
        while i + 1 < b.count {
            if b[i] == 0xFF && b[i + 1] == 0x51 {
                guard i + 40 < b.count else { return nil }
                func u32(_ p: Int) -> Int { Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3]) }
                let xsiz = u32(i + 6), ysiz = u32(i + 10), xo = u32(i + 14), yo = u32(i + 18)
                let csiz = Int(b[i + 38]) << 8 | Int(b[i + 39])
                guard i + 40 < b.count else { return nil }
                let ssiz = b[i + 40]
                return SIZInfo(width: xsiz - xo, height: ysiz - yo, components: csiz, precision: Int(ssiz & 0x7F) + 1, signed: ssiz & 0x80 != 0)
            }
            i += 1
        }
        return nil
    }

    public static func decode(_ data: Data) throws -> DecodedImage {
        do {
            return try JPEG2000Decoder.decode(data)
        } catch {
            if let img = try? decodeWithImageIO(data) { return img }
            throw error
        }
    }

    static func decodeWithImageIO(_ data: Data) throws -> DecodedImage {
        let info = siz(data)
        let isJP2 = data.count > 12 && data.prefix(12) == Data([0, 0, 0, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A])
        let opts: [CFString: Any] = [kCGImageSourceTypeIdentifierHint: "public.jpeg-2000" as CFString,
                                     kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw DICOMError.decode("JPEG 2000 (ImageIO could not decode the codestream)") }
        guard let provider = img.dataProvider, let cfdata = provider.data else { throw DICOMError.decode("JPEG 2000 bitmap") }
        let w = img.width, h = img.height
        let bpc = img.bitsPerComponent
        let bpp = img.bitsPerPixel
        let rowBytes = img.bytesPerRow
        let alpha = img.alphaInfo
        let hasAlpha = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        let skipFirst = alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst
        let channelsInPixel = bpp / bpc
        let colorChannels = img.colorSpace?.numberOfComponents ?? (channelsInPixel - (hasAlpha ? 1 : 0))
        let comps = info?.components ?? colorChannels
        let outComps = comps >= 3 ? 3 : 1
        let byteOrder = img.bitmapInfo.intersection(.byteOrderMask)
        let little16 = byteOrder == .byteOrder16Little
        let little32 = byteOrder == .byteOrder32Little
        var samples = [UInt16](repeating: 0, count: w * h * outComps)
        let bytes = CFDataGetBytePtr(cfdata)!
        let firstChannel = skipFirst && channelsInPixel > colorChannels ? 1 : 0
        for y in 0..<h {
            let row = bytes + y * rowBytes
            for x in 0..<w {
                for c in 0..<outComps {
                    let ch = firstChannel + min(c, colorChannels - 1)
                    var v: UInt16
                    if bpc == 16 {
                        let p = row + (x * channelsInPixel + ch) * 2
                        let raw = UInt16(p[0]) | UInt16(p[1]) << 8
                        v = little16 ? raw : raw.byteSwapped
                    } else if bpc == 8 {
                        if little32 && channelsInPixel == 4 {
                            v = UInt16(row[x * 4 + (3 - ch)])
                        } else {
                            v = UInt16(row[x * channelsInPixel + ch])
                        }
                    } else if bpc == 32 {
                        let p = row + (x * channelsInPixel + ch) * 4
                        let f = Float(bitPattern: UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24)
                        v = UInt16(max(0, min(65535, f * 65535)))
                    } else {
                        v = 0
                    }
                    samples[(y * w + x) * outComps + c] = v
                }
            }
        }
        var precision = info?.precision ?? bpc
        var signed = false
        if let info {
            // ImageIO widens sub-16-bit codestreams to the container depth by scaling; undo it.
            if bpc == 16 && info.precision < 16 {
                let maxDecoded = samples.max() ?? 0
                let limit = UInt16((1 << info.precision) - 1)
                if maxDecoded > limit {
                    let shift = UInt16(16 - info.precision)
                    for i in samples.indices { samples[i] >>= shift }
                }
            } else if bpc == 8 && info.precision > 8 {
                // Decoder reduced precision: scale back up (lossy, best effort)
                let shift = UInt16(info.precision - 8)
                for i in samples.indices { samples[i] <<= shift }
            }
            if info.signed {
                // ImageIO presents signed components with a +2^(P-1) offset; restore two's complement.
                let offset = UInt16(1 << (info.precision - 1))
                for i in samples.indices { samples[i] = samples[i] &- offset }
                signed = true
            }
            precision = info.precision
        }
        return DecodedImage(width: w, height: h, components: outComps, precision: precision, samples: samples, isRGB: outComps == 3, signed: signed)
    }

    /// Lossless JPEG 2000 encoding via ImageIO for 8/16-bit grayscale (used for tests / export).
    public static func encode(samples: [UInt16], width: Int, height: Int, bits: Int, lossless: Bool = true) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg-2000" as CFString, 1, nil) else { return nil }
        let bpc = bits > 8 ? 16 : 8
        var bytes = Data(count: width * height * bpc / 8)
        bytes.withUnsafeMutableBytes { raw in
            if bpc == 16 {
                let p = raw.bindMemory(to: UInt16.self)
                for i in 0..<(width * height) { p[i] = samples[i].littleEndian }
            } else {
                let p = raw.bindMemory(to: UInt8.self)
                for i in 0..<(width * height) { p[i] = UInt8(truncatingIfNeeded: samples[i]) }
            }
        }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: bpc, bitsPerPixel: bpc, bytesPerRow: width * bpc / 8,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | (bpc == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: lossless ? 1.0 : 0.8]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
