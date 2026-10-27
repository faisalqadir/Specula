import Foundation

/// Image Pixel Module attributes.
public struct ImagePixelInfo: Sendable {
    public var rows: Int
    public var columns: Int
    public var samplesPerPixel: Int
    public var photometric: String
    public var bitsAllocated: Int
    public var bitsStored: Int
    public var highBit: Int
    public var pixelRepresentation: Int
    public var planarConfiguration: Int
    public var numberOfFrames: Int
    public var isFloat: Bool

    public init(_ ds: DataSet) {
        rows = ds.int(.rows) ?? 0
        columns = ds.int(.columns) ?? 0
        samplesPerPixel = max(1, ds.int(.samplesPerPixel) ?? 1)
        photometric = (ds.string(.photometricInterpretation) ?? (samplesPerPixel == 3 ? "RGB" : "MONOCHROME2")).uppercased()
        bitsAllocated = ds.int(.bitsAllocated) ?? 16
        bitsStored = ds.int(.bitsStored) ?? bitsAllocated
        highBit = ds.int(.highBit) ?? (bitsStored - 1)
        pixelRepresentation = ds.int(.pixelRepresentation) ?? 0
        planarConfiguration = ds.int(.planarConfiguration) ?? 0
        numberOfFrames = max(1, ds.int(.numberOfFrames) ?? 1)
        isFloat = ds.contains(.floatPixelData) || ds.contains(.doubleFloatPixelData)
        if bitsStored <= 0 || bitsStored > bitsAllocated { bitsStored = bitsAllocated }
    }

    public var isMonochrome: Bool { photometric.hasPrefix("MONOCHROME") }
    public var isPalette: Bool { photometric == "PALETTE COLOR" }
    public var signed: Bool { pixelRepresentation == 1 }
    /// Bits per frame (handles 1-bit data whose frames are not byte aligned).
    public var frameBits: Int {
        if photometric == "YBR_FULL_422" && samplesPerPixel == 3 && bitsAllocated == 8 { return rows * columns * 2 * 8 }
        return rows * columns * samplesPerPixel * bitsAllocated
    }

    public var frameBytes: Int {
        if bitsAllocated == 1 { return (rows * columns * samplesPerPixel + 7) / 8 }
        if photometric == "YBR_FULL_422" && samplesPerPixel == 3 { return rows * columns * 2 * (bitsAllocated / 8) }
        return rows * columns * samplesPerPixel * (bitsAllocated / 8)
    }
}

/// Decoded frame ready for display.
public struct PixelFrame: @unchecked Sendable {
    public enum Format: Sendable {
        case gray8        // UInt8
        case gray16       // UInt16
        case gray16Signed // Int16
        case float32      // Float
        case rgba8        // 4 x UInt8
    }

    public var width: Int
    public var height: Int
    public var format: Format
    public var pixels: Data
    /// Actual minimum and maximum stored values (grayscale only).
    public var minValue: Double
    public var maxValue: Double

    public var bytesPerPixel: Int {
        switch format {
        case .gray8: return 1
        case .gray16, .gray16Signed: return 2
        case .float32, .rgba8: return 4
        }
    }

    public var isColor: Bool { format == .rgba8 }

    /// Stored value at (x, y) for grayscale formats.
    public func storedValue(x: Int, y: Int) -> Double? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = y * width + x
        return pixels.withUnsafeBytes { raw -> Double in
            switch format {
            case .gray8: return Double(raw.load(fromByteOffset: i, as: UInt8.self))
            case .gray16: return Double(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
            case .gray16Signed: return Double(raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
            case .float32: return Double(raw.loadUnaligned(fromByteOffset: i * 4, as: Float.self))
            case .rgba8:
                let r = Double(raw.load(fromByteOffset: i * 4, as: UInt8.self))
                let g = Double(raw.load(fromByteOffset: i * 4 + 1, as: UInt8.self))
                let b = Double(raw.load(fromByteOffset: i * 4 + 2, as: UInt8.self))
                return 0.299 * r + 0.587 * g + 0.114 * b
            }
        }
    }

    public func rgb(x: Int, y: Int) -> (UInt8, UInt8, UInt8)? {
        guard format == .rgba8, x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        return pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (UInt8, UInt8, UInt8) in (raw[i], raw[i + 1], raw[i + 2]) }
    }

    /// Stored values as Float array (grayscale), used for volume building and statistics.
    public func floatValues() -> [Float] {
        let n = width * height
        var out = [Float](repeating: 0, count: n)
        pixels.withUnsafeBytes { raw in
            switch format {
            case .gray8: let p = raw.bindMemory(to: UInt8.self); for i in 0..<n { out[i] = Float(p[i]) }
            case .gray16: let p = raw.bindMemory(to: UInt16.self); for i in 0..<n { out[i] = Float(p[i]) }
            case .gray16Signed: let p = raw.bindMemory(to: Int16.self); for i in 0..<n { out[i] = Float(p[i]) }
            case .float32: let p = raw.bindMemory(to: Float.self); for i in 0..<n { out[i] = p[i] }
            case .rgba8:
                let p = raw.bindMemory(to: UInt8.self)
                for i in 0..<n { out[i] = 0.299 * Float(p[i * 4]) + 0.587 * Float(p[i * 4 + 1]) + 0.114 * Float(p[i * 4 + 2]) }
            }
        }
        return out
    }
}

public enum PixelDecoder {
    /// Splits encapsulated pixel data into per-frame fragment lists.
    public static func frameFragments(_ enc: EncapsulatedPixelData, numberOfFrames: Int, codec: PixelCodec, extendedOffsets: [UInt64]? = nil) -> [[Data]] {
        let frags = enc.fragments
        if frags.isEmpty { return [] }
        if numberOfFrames <= 1 { return [frags] }
        if frags.count == numberOfFrames { return frags.map { [$0] } }
        // Basic offset table
        var offsets: [Int] = []
        if let ext = extendedOffsets, !ext.isEmpty {
            offsets = ext.map { Int($0) }
        } else if enc.basicOffsetTable.count >= 4 {
            enc.basicOffsetTable.withUnsafeBytes { raw in
                for i in 0..<(raw.count / 4) { offsets.append(Int(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian)) }
            }
        }
        if offsets.count == numberOfFrames {
            var positions: [Int] = []
            var p = 0
            for f in frags { positions.append(p); p += 8 + f.count }
            var result: [[Data]] = []
            for (i, start) in offsets.enumerated() {
                let end = i + 1 < offsets.count ? offsets[i + 1] : Int.max
                result.append(zip(positions, frags).filter { $0.0 >= start && $0.0 < end }.map { $0.1 })
            }
            if result.allSatisfy({ !$0.isEmpty }) { return result }
        }
        // Detect frame starts by codestream signatures
        var result: [[Data]] = []
        for f in frags {
            let isStart: Bool = f.withUnsafeBytes { raw in
                guard raw.count >= 2 else { return false }
                let a = raw[0], b = raw[1]
                switch codec {
                case .jpegProcess1, .jpegProcess2_4, .jpegLossless, .jpegLS: return a == 0xFF && b == 0xD8
                case .jpeg2000, .htj2k: return (a == 0xFF && b == 0x4F) || (raw.count >= 8 && raw[4] == 0x6A && raw[5] == 0x50)
                default: return true
                }
            }
            if isStart || result.isEmpty { result.append([f]) } else { result[result.count - 1].append(f) }
        }
        return result
    }

    static func concat(_ parts: [Data]) -> Data {
        if parts.count == 1 { return parts[0] }
        var d = Data(capacity: parts.reduce(0) { $0 + $1.count })
        for p in parts { d.append(p) }
        return d
    }

    /// Number of frames actually available in the file.
    public static func availableFrames(_ file: DICOMFile) -> Int {
        let ds = file.dataSet
        let info = ImagePixelInfo(ds)
        if let e = ds[.pixelData], let enc = e.encapsulated {
            let ext = ds.data(.extendedOffsetTable).map { d -> [UInt64] in d.withUnsafeBytes { r in (0..<(r.count / 8)).map { r.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self).littleEndian } } }
            return min(info.numberOfFrames, max(1, frameFragments(enc, numberOfFrames: info.numberOfFrames, codec: file.transferSyntax.codec, extendedOffsets: ext).count))
        }
        if let d = ds.data(.pixelData) ?? ds.data(.floatPixelData) ?? ds.data(.doubleFloatPixelData) {
            var fbits = info.frameBits
            if ds.contains(.floatPixelData) { fbits = info.rows * info.columns * 32 } else if ds.contains(.doubleFloatPixelData) { fbits = info.rows * info.columns * 64 }
            guard fbits > 0 else { return 0 }
            return max(1, min(info.numberOfFrames, d.count * 8 / fbits))
        }
        return 0
    }

    public static func decodeFrame(_ file: DICOMFile, frame: Int) throws -> PixelFrame {
        let ds = file.dataSet
        var info = ImagePixelInfo(ds)
        guard info.rows > 0, info.columns > 0 else { throw DICOMError.decode("missing image dimensions") }
        let ts = file.transferSyntax

        // Float pixel data
        if let d = ds.data(.floatPixelData) ?? ds.data(.doubleFloatPixelData) {
            let isDouble = ds.contains(.doubleFloatPixelData)
            let n = info.rows * info.columns
            let size = isDouble ? 8 : 4
            let start = frame * n * size
            guard start + n * size <= d.count else { throw DICOMError.truncated }
            var out = Data(count: n * 4)
            var mn = Double.greatestFiniteMagnitude, mx = -Double.greatestFiniteMagnitude
            d.withUnsafeBytes { src in
                out.withUnsafeMutableBytes { dst in
                    let o = dst.bindMemory(to: Float.self)
                    for i in 0..<n {
                        var v: Float
                        if isDouble {
                            var bits = src.loadUnaligned(fromByteOffset: start + i * 8, as: UInt64.self)
                            if ds.bigEndian { bits = bits.byteSwapped }
                            v = Float(Double(bitPattern: bits))
                        } else {
                            var bits = src.loadUnaligned(fromByteOffset: start + i * 4, as: UInt32.self)
                            if ds.bigEndian { bits = bits.byteSwapped }
                            v = Float(bitPattern: bits)
                        }
                        if !v.isFinite { v = 0 }
                        o[i] = v
                        mn = min(mn, Double(v)); mx = max(mx, Double(v))
                    }
                }
            }
            return PixelFrame(width: info.columns, height: info.rows, format: .float32, pixels: out, minValue: mn, maxValue: mx)
        }

        guard let pe = ds[.pixelData] else { throw DICOMError.decode("no pixel data") }

        if let enc = pe.encapsulated {
            let ext = ds.data(.extendedOffsetTable).map { d -> [UInt64] in d.withUnsafeBytes { r in (0..<(r.count / 8)).map { r.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self).littleEndian } } }
            let frames = frameFragments(enc, numberOfFrames: info.numberOfFrames, codec: ts.codec, extendedOffsets: ext)
            guard frame < frames.count else { throw DICOMError.decode("frame \(frame + 1) not present") }
            let stream = concat(frames[frame])
            var decoded: DecodedImage
            switch ts.codec {
            case .rle:
                let native = try RLECodec.decodeToNative(stream, width: info.columns, height: info.rows, samplesPerPixel: info.samplesPerPixel, bitsAllocated: info.bitsAllocated)
                var ni = info
                ni.planarConfiguration = 0
                if ni.photometric == "YBR_FULL_422" { ni.photometric = "YBR_FULL" }
                return try decodeNative(native, bitOffset: 0, info: ni, ds: ds, bigEndian: false, owSwap: false)
            case .deflatedFrame:
                guard let native = Inflate.raw(stream) ?? Inflate.zlib(stream) else { throw DICOMError.decode("deflated frame") }
                return try decodeNative(native, bitOffset: 0, info: info, ds: ds, bigEndian: false, owSwap: false)
            case .encapsulatedUncompressed:
                return try decodeNative(stream, bitOffset: 0, info: info, ds: ds, bigEndian: false, owSwap: false)
            case .jpegXL:
                decoded = try ImageIOCodec.decode(stream, typeHint: "public.jxl")
            case .jpegProcess1, .jpegProcess2_4, .jpegLossless:
                decoded = try JPEGDecoder.decode(stream, rawComponents: info.photometric == "RGB" && ts.codec == .jpegLossless, assumeRGB: info.photometric == "RGB")
            case .jpegLS:
                decoded = try JPEGLSDecoder.decode(stream)
            case .jpeg2000:
                decoded = try JPEG2000Codec.decode(stream)
            case .htj2k:
                decoded = try JPEG2000Codec.decode(stream)
            case .unknown:
                // Sniff the stream type
                let b0 = stream.first ?? 0, b1 = stream.dropFirst().first ?? 0
                if b0 == 0xFF && b1 == 0xD8 {
                    if let fi = JPEGDecoder.frameInfo(stream), fi.process == 0x37 { decoded = try JPEGLSDecoder.decode(stream) }
                    else { decoded = try JPEGDecoder.decode(stream) }
                } else {
                    decoded = try JPEG2000Codec.decode(stream)
                }
            case .mpeg2, .h264, .hevc:
                throw DICOMError.unsupported("video transfer syntax (use the movie player)")
            case .native:
                throw DICOMError.decode("encapsulated data with native syntax")
            }
            // JPEG-LS can be detected inside a .jpeg* syntax when mislabelled
            if decoded.width != info.columns || decoded.height != info.rows {
                info.columns = decoded.width
                info.rows = decoded.height
            }
            if decoded.signed {
                info.pixelRepresentation = 1
            }
            if decoded.isRGB && info.samplesPerPixel == 3 { info.photometric = "RGB" }
            if decoded.components == 3 && info.samplesPerPixel == 1 { info.samplesPerPixel = 3; info.photometric = "RGB" }
            if ts.codec == .jpeg2000 || ts.codec == .htj2k {
                if info.photometric == "YBR_ICT" || info.photometric == "YBR_RCT" { info.photometric = "RGB" }
            }
            return try finish(samples: decoded.samples, components: decoded.components, info: info, ds: ds, bitsStoredHint: decoded.precision, codec: ts.codec)
        }

        guard let raw = pe.data else { throw DICOMError.decode("pixel data") }
        let frameBits = info.frameBits
        guard frameBits > 0 else { throw DICOMError.decode("frame size") }
        let bitOffset = frame * frameBits
        if bitOffset >= raw.count * 8 { throw DICOMError.truncated }
        let owSwap = ds.bigEndian && info.bitsAllocated == 8 && pe.vr == .OW
        return try decodeNative(raw, bitOffset: bitOffset, info: info, ds: ds, bigEndian: ds.bigEndian, owSwap: owSwap)
    }

    /// Decodes one frame of uncompressed pixel data starting at a bit offset.
    static func decodeNative(_ raw: Data, bitOffset: Int, info: ImagePixelInfo, ds: DataSet, bigEndian: Bool, owSwap: Bool) throws -> PixelFrame {
        var info = info
        let rows = info.rows, cols = info.columns, spp = info.samplesPerPixel
        let n = rows * cols
        let startByte = bitOffset / 8
        let avail = max(0, raw.count - startByte)
        var samples = [UInt16](repeating: 0, count: n * spp)
        var floatFallback: [Float]? = nil
        var colorShift32 = 0
        raw.withUnsafeBytes { src in
            let base = src.baseAddress!.advanced(by: startByte)
            // Byte reader honouring OW byte swapping for 8-bit data in big endian files
            @inline(__always) func byte(_ i: Int) -> UInt8 {
                let j = owSwap ? ((startByte + i) ^ 1) - startByte : i
                return j >= 0 && j < avail ? base.load(fromByteOffset: j, as: UInt8.self) : 0
            }
            switch info.bitsAllocated {
            case 1:
                let firstBit = bitOffset % 8
                for i in 0..<(n * spp) {
                    let b = firstBit + i
                    guard b / 8 < avail else { break }
                    samples[i] = UInt16((base.load(fromByteOffset: b / 8, as: UInt8.self) >> UInt8(b % 8)) & 1)
                }
            case 8:
                if info.photometric == "YBR_FULL_422" && spp == 3 {
                    var o = 0, i = 0
                    while i + 3 < avail && o + 5 < samples.count {
                        let y0 = byte(i), y1 = byte(i + 1), cb = byte(i + 2), cr = byte(i + 3)
                        samples[o] = UInt16(y0); samples[o + 1] = UInt16(cb); samples[o + 2] = UInt16(cr)
                        samples[o + 3] = UInt16(y1); samples[o + 4] = UInt16(cb); samples[o + 5] = UInt16(cr)
                        o += 6; i += 4
                    }
                    info.photometric = "YBR_FULL"
                } else if spp > 1 && info.planarConfiguration == 1 {
                    for c in 0..<spp { for i in 0..<n { samples[i * spp + c] = UInt16(byte(c * n + i)) } }
                } else {
                    for i in 0..<(n * spp) { samples[i] = UInt16(byte(i)) }
                }
            case 16:
                func word(_ k: Int) -> UInt16 {
                    guard k * 2 + 1 < avail else { return 0 }
                    let v = base.loadUnaligned(fromByteOffset: k * 2, as: UInt16.self)
                    return bigEndian ? v.byteSwapped : v
                }
                if spp > 1 && info.planarConfiguration == 1 {
                    for c in 0..<spp { for i in 0..<n { samples[i * spp + c] = word(c * n + i) } }
                } else if !bigEndian && Int(bitPattern: base) % 2 == 0 && avail >= n * spp * 2 {
                    samples.withUnsafeMutableBufferPointer { dst in _ = memcpy(dst.baseAddress!, base, n * spp * 2) }
                } else {
                    for k in 0..<(n * spp) { samples[k] = word(k) }
                }
            case 32:
                func dword(_ k: Int) -> UInt32 {
                    guard k * 4 + 3 < avail else { return 0 }
                    let v = base.loadUnaligned(fromByteOffset: k * 4, as: UInt32.self)
                    return bigEndian ? v.byteSwapped : v
                }
                let planar = spp > 1 && info.planarConfiguration == 1
                if spp == 1 {
                    var f = [Float](repeating: 0, count: n)
                    let bs = info.bitsStored
                    for i in 0..<n {
                        var v = dword(i)
                        if bs < 32 { v &= UInt32((UInt64(1) << UInt64(bs)) - 1) }
                        if info.signed {
                            let shift = UInt32(32 - bs)
                            f[i] = Float(Int32(bitPattern: v << shift) >> Int32(shift))
                        } else {
                            f[i] = Float(v)
                        }
                    }
                    floatFallback = f
                } else {
                    // Colour with 32-bit samples: keep the 16 most significant stored bits
                    colorShift32 = max(0, info.bitsStored - 16)
                    for c in 0..<spp {
                        for i in 0..<n {
                            let v = dword(planar ? c * n + i : i * spp + c)
                            samples[i * spp + c] = UInt16(truncatingIfNeeded: v >> UInt32(colorShift32))
                        }
                    }
                }
            default:
                break
            }
        }
        if let f = floatFallback {
            var d = Data(count: n * 4)
            var mn = Double.greatestFiniteMagnitude, mx = -Double.greatestFiniteMagnitude
            d.withUnsafeMutableBytes { dst in
                let o = dst.bindMemory(to: Float.self)
                for i in 0..<n { o[i] = f[i]; mn = min(mn, Double(f[i])); mx = max(mx, Double(f[i])) }
            }
            return PixelFrame(width: cols, height: rows, format: .float32, pixels: d, minValue: mn, maxValue: mx)
        }
        if info.bitsAllocated == 1 { info.bitsStored = 1; info.highBit = 0 }
        if info.bitsAllocated == 32 && spp > 1 {
            info.bitsAllocated = 16
            info.bitsStored = min(16, info.bitsStored)
            info.highBit = info.bitsStored - 1
        }
        return try finish(samples: samples, components: spp, info: info, ds: ds, bitsStoredHint: nil, codec: .native)
    }

    /// Masking / sign extension and colour conversion.
    static func finish(samples inSamples: [UInt16], components: Int, info: ImagePixelInfo, ds: DataSet, bitsStoredHint: Int?, codec: PixelCodec) throws -> PixelFrame {
        var samples = inSamples
        let w = info.columns, h = info.rows
        let n = w * h
        if components == 1 && !info.isPalette {
            let bitsStored = info.bitsStored
            let isEncapsulatedLossy = codec == .jpegProcess1 || codec == .jpegProcess2_4
            // High bit shift for native data where HighBit != BitsStored-1
            let shift = codec == .native ? max(0, info.highBit + 1 - bitsStored) : 0
            if info.signed && bitsStored < 16 || info.signed && bitsStored == 16 {
                var out = Data(count: n * 2)
                var mn = Int.max, mx = Int.min
                out.withUnsafeMutableBytes { dst in
                    let o = dst.bindMemory(to: Int16.self)
                    let s = 16 - bitsStored
                    for i in 0..<n {
                        var v = samples[i] >> UInt16(shift)
                        if bitsStored < 16 { v &= UInt16((1 << bitsStored) - 1) }
                        let x = Int16(bitPattern: v << UInt16(s)) >> Int16(s)
                        o[i] = x
                        let xi = Int(x)
                        if xi < mn { mn = xi }
                        if xi > mx { mx = xi }
                    }
                }
                return PixelFrame(width: w, height: h, format: .gray16Signed, pixels: out, minValue: Double(mn), maxValue: Double(mx))
            }
            let effectiveBits = isEncapsulatedLossy ? (bitsStoredHint ?? bitsStored) : bitsStored
            let mask = effectiveBits >= 16 ? UInt16.max : UInt16((1 << effectiveBits) - 1)
            var mn = Int.max, mx = Int.min
            if info.bitsAllocated <= 8 && (bitsStoredHint ?? 8) <= 8 {
                var out = Data(count: n)
                out.withUnsafeMutableBytes { dst in
                    let o = dst.bindMemory(to: UInt8.self)
                    for i in 0..<n {
                        let v = UInt8(truncatingIfNeeded: (samples[i] >> UInt16(shift)) & mask)
                        o[i] = v
                        let vi = Int(v)
                        if vi < mn { mn = vi }
                        if vi > mx { mx = vi }
                    }
                }
                return PixelFrame(width: w, height: h, format: .gray8, pixels: out, minValue: Double(mn), maxValue: Double(mx))
            }
            var out = Data(count: n * 2)
            out.withUnsafeMutableBytes { dst in
                let o = dst.bindMemory(to: UInt16.self)
                for i in 0..<n {
                    let v = (samples[i] >> UInt16(shift)) & mask
                    o[i] = v
                    let vi = Int(v)
                    if vi < mn { mn = vi }
                    if vi > mx { mx = vi }
                }
            }
            return PixelFrame(width: w, height: h, format: .gray16, pixels: out, minValue: Double(mn), maxValue: Double(mx))
        }

        // Colour
        var rgba = Data(count: n * 4)
        if info.isPalette {
            let lut = PaletteLUT(ds)
            rgba.withUnsafeMutableBytes { dst in
                let o = dst.bindMemory(to: UInt8.self)
                for i in 0..<n {
                    let (r, g, b) = lut.lookup(Int(samples[i * components]))
                    o[i * 4] = r; o[i * 4 + 1] = g; o[i * 4 + 2] = b; o[i * 4 + 3] = 255
                }
            }
            return PixelFrame(width: w, height: h, format: .rgba8, pixels: rgba, minValue: 0, maxValue: 255)
        }
        let photometric = info.photometric
        let ybr = photometric.hasPrefix("YBR_FULL") || photometric == "YBR_PARTIAL_422" || photometric == "YBR_PARTIAL_420"
        let partial = photometric.hasPrefix("YBR_PARTIAL")
        let bits = info.bitsAllocated > 8 ? (bitsStoredHint ?? info.bitsStored) : 8
        let down = UInt16(max(0, bits - 8))
        rgba.withUnsafeMutableBytes { dst in
            let o = dst.bindMemory(to: UInt8.self)
            for i in 0..<n {
                let base = i * components
                var r = Float(samples[base] >> down)
                var g = Float(samples[min(base + 1, samples.count - 1)] >> down)
                var b = Float(samples[min(base + 2, samples.count - 1)] >> down)
                if ybr && components >= 3 {
                    let y = r, cb = g - 128, cr = b - 128
                    if partial {
                        let yy = 1.1644 * (y - 16)
                        r = yy + 1.5960 * cr
                        g = yy - 0.3917 * cb - 0.8129 * cr
                        b = yy + 2.0172 * cb
                    } else {
                        r = y + 1.402 * cr
                        g = y - 0.344136 * cb - 0.714136 * cr
                        b = y + 1.772 * cb
                    }
                }
                o[i * 4] = UInt8(max(0, min(255, r + 0.5)))
                o[i * 4 + 1] = UInt8(max(0, min(255, g + 0.5)))
                o[i * 4 + 2] = UInt8(max(0, min(255, b + 0.5)))
                o[i * 4 + 3] = 255
            }
        }
        return PixelFrame(width: w, height: h, format: .rgba8, pixels: rgba, minValue: 0, maxValue: 255)
    }
}

/// Palette colour lookup tables (normal and segmented).
public struct PaletteLUT {
    var first = 0
    var red: [UInt8] = []
    var green: [UInt8] = []
    var blue: [UInt8] = []

    public init(_ ds: DataSet) {
        func table(_ descTag: Tag, _ dataTag: Tag, _ segTag: Tag) -> [UInt8] {
            let desc = ds.uint16s(descTag)
            var entries = desc.count > 0 ? Int(desc[0]) : 256
            if entries == 0 { entries = 65536 }
            if desc.count > 1 { first = Int(Int16(bitPattern: desc[1])) < 0 ? Int(desc[1]) : Int(desc[1]) }
            let bits = desc.count > 2 ? Int(desc[2]) : 16
            var values: [Int] = []
            if let d = ds.data(dataTag) {
                if bits == 8 && d.count == entries {
                    values = d.map { Int($0) }
                } else {
                    values = ds.uint16s(d).map { Int($0) }
                    if bits == 8 && values.count * 2 == entries {
                        // 8-bit entries packed in 16-bit words
                        var v8: [Int] = []
                        for w in values { v8.append(w & 0xFF); v8.append(w >> 8) }
                        values = v8
                    }
                }
            } else if let d = ds.data(segTag) {
                values = PaletteLUT.expandSegmented(ds.uint16s(d).map { Int($0) })
            }
            let maxIn = bits == 8 ? 255.0 : 65535.0
            let scale = values.max().map { $0 <= 255 && bits == 16 ? 1.0 : 255.0 / maxIn } ?? 1.0
            return values.map { UInt8(max(0, min(255, Double($0) * scale))) }
        }
        red = table(.redPaletteColorLookupTableDescriptor, .redPaletteColorLookupTableData, .segmentedRedPaletteColorLookupTableData)
        green = table(.greenPaletteColorLookupTableDescriptor, .greenPaletteColorLookupTableData, .segmentedGreenPaletteColorLookupTableData)
        blue = table(.bluePaletteColorLookupTableDescriptor, .bluePaletteColorLookupTableData, .segmentedBluePaletteColorLookupTableData)
    }

    static func expandSegmented(_ seg: [Int]) -> [Int] {
        var out: [Int] = []
        var i = 0
        while i + 1 < seg.count {
            let op = seg[i], len = seg[i + 1]
            i += 2
            switch op {
            case 0:
                for k in 0..<len where i + k < seg.count { out.append(seg[i + k]) }
                i += len
            case 1:
                guard i < seg.count else { return out }
                let y1 = seg[i]; i += 1
                let y0 = out.last ?? y1
                for k in 1...max(1, len) { out.append(y0 + (y1 - y0) * k / max(1, len)) }
            case 2:
                guard i + 1 < seg.count else { return out }
                let off = seg[i] | seg[i + 1] << 16
                i += 2
                // Indirect: copy segments from the start offset (rare)
                let sub = expandSegmented(Array(seg[min(off, seg.count)...].prefix(len * 4)))
                out.append(contentsOf: sub)
            default:
                return out
            }
        }
        return out
    }

    public func lookup(_ v: Int) -> (UInt8, UInt8, UInt8) {
        func at(_ t: [UInt8]) -> UInt8 {
            guard !t.isEmpty else { return 0 }
            let i = max(0, min(t.count - 1, v - first))
            return t[i]
        }
        return (at(red), at(green), at(blue))
    }
}
