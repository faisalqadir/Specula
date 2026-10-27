import Foundation

/// DICOM RLE Lossless (PS3.5 Annex G).
public enum RLECodec {
    /// Decodes one RLE frame into interleaved samples.
    public static func decode(_ data: Data, width: Int, height: Int, samplesPerPixel: Int, bitsAllocated: Int) throws -> DecodedImage {
        guard data.count >= 64 else { throw DICOMError.decode("RLE header") }
        let bytesPerSample = bitsAllocated / 8
        let pixels = width * height
        var samples = [UInt16](repeating: 0, count: pixels * samplesPerPixel)
        try data.withUnsafeBytes { raw in
            let n = raw.count
            let nseg = Int(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian)
            guard nseg >= 1, nseg <= 15 else { throw DICOMError.decode("RLE segment count \(nseg)") }
            var offsets: [Int] = []
            for i in 0..<nseg { offsets.append(Int(raw.loadUnaligned(fromByteOffset: 4 + 4 * i, as: UInt32.self).littleEndian)) }
            let bytes = raw.bindMemory(to: UInt8.self)
            var plane = [UInt8](repeating: 0, count: pixels)
            for s in 0..<min(nseg, samplesPerPixel * bytesPerSample) {
                let start = offsets[s]
                let end = s + 1 < nseg ? offsets[s + 1] : n
                guard start < n, start <= end else { continue }
                var p = start, o = 0
                while p < min(end, n) && o < pixels {
                    let c = Int8(bitPattern: bytes[p]); p += 1
                    if c >= 0 {
                        let cnt = min(Int(c) + 1, pixels - o, n - p)
                        for k in 0..<cnt { plane[o + k] = bytes[p + k] }
                        o += cnt; p += Int(c) + 1
                    } else if c != -128 {
                        guard p < n else { break }
                        let cnt = min(1 - Int(c), pixels - o)
                        let v = bytes[p]; p += 1
                        for k in 0..<cnt { plane[o + k] = v }
                        o += cnt
                    }
                }
                let sample = s / bytesPerSample
                let byteIndex = s % bytesPerSample          // 0 = most significant
                let shift = UInt16(8 * (bytesPerSample - 1 - byteIndex))
                if bytesPerSample <= 2 {
                    var i = sample
                    for k in 0..<pixels {
                        samples[i] |= UInt16(plane[k]) << shift
                        i += samplesPerPixel
                    }
                } else if byteIndex >= bytesPerSample - 2 {
                    // 32-bit samples: keep the low 16 bits only (rare)
                    let sh = UInt16(8 * (bytesPerSample - 1 - byteIndex))
                    var i = sample
                    for k in 0..<pixels { samples[i] |= UInt16(plane[k]) << sh; i += samplesPerPixel }
                }
            }
        }
        return DecodedImage(width: width, height: height, components: samplesPerPixel, precision: min(16, bitsAllocated), samples: samples, isRGB: false)
    }

    /// Decodes one RLE frame into the equivalent uncompressed little endian frame (planar configuration 0).
    public static func decodeToNative(_ data: Data, width: Int, height: Int, samplesPerPixel: Int, bitsAllocated: Int) throws -> Data {
        guard data.count >= 64 else { throw DICOMError.decode("RLE header") }
        let pixels = width * height
        let bytesPerSample = max(1, bitsAllocated / 8)
        // 1-bit data may be RLE coded either bit-packed or (as GDCM/pydicom do) one byte per pixel.
        let packedLength = (pixels * samplesPerPixel + 7) / 8
        let segmentLength = bitsAllocated == 1 ? pixels * samplesPerPixel : pixels
        var out = Data(count: bitsAllocated == 1 ? packedLength : pixels * samplesPerPixel * bytesPerSample)
        try data.withUnsafeBytes { raw in
            let n = raw.count
            let nseg = Int(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian)
            guard nseg >= 1, nseg <= 15 else { throw DICOMError.decode("RLE segment count \(nseg)") }
            var offsets: [Int] = []
            for i in 0..<nseg { offsets.append(Int(raw.loadUnaligned(fromByteOffset: 4 + 4 * i, as: UInt32.self).littleEndian)) }
            let bytes = raw.bindMemory(to: UInt8.self)
            var plane = [UInt8](repeating: 0, count: segmentLength)
            out.withUnsafeMutableBytes { dstRaw in
                let dst = dstRaw.bindMemory(to: UInt8.self)
                for s in 0..<min(nseg, bitsAllocated == 1 ? 1 : samplesPerPixel * bytesPerSample) {
                    let start = offsets[s]
                    let end = s + 1 < nseg ? offsets[s + 1] : n
                    guard start < n, start <= end else { continue }
                    for k in 0..<segmentLength { plane[k] = 0 }
                    var p = start, o = 0
                    while p < min(end, n) && o < segmentLength {
                        let c = Int8(bitPattern: bytes[p]); p += 1
                        if c >= 0 {
                            let cnt = min(Int(c) + 1, segmentLength - o, n - p)
                            for k in 0..<max(0, cnt) { plane[o + k] = bytes[p + k] }
                            o += max(0, cnt); p += Int(c) + 1
                        } else if c != -128 {
                            guard p < n else { break }
                            let cnt = min(1 - Int(c), segmentLength - o)
                            let v = bytes[p]; p += 1
                            for k in 0..<cnt { plane[o + k] = v }
                            o += cnt
                        }
                    }
                    if bitsAllocated == 1 {
                        if o <= packedLength {
                            for k in 0..<packedLength { dst[k] = plane[k] }          // already bit-packed
                        } else {
                            for k in 0..<packedLength { dst[k] = 0 }
                            for k in 0..<segmentLength where plane[k] != 0 { dst[k >> 3] |= UInt8(1 << (k & 7)) }
                        }
                        continue
                    }
                    let sample = s / bytesPerSample
                    let byteInSample = bytesPerSample - 1 - s % bytesPerSample   // segments are MSB first; output little endian
                    var o2 = sample * bytesPerSample + byteInSample
                    let stride = samplesPerPixel * bytesPerSample
                    for k in 0..<pixels { dst[o2] = plane[k]; o2 += stride }
                }
            }
        }
        return out
    }

    /// Encodes interleaved samples as one RLE frame (used for export and tests).
    public static func encode(samples: [UInt16], width: Int, height: Int, samplesPerPixel: Int, bitsAllocated: Int) -> Data {
        let bytesPerSample = bitsAllocated / 8
        let pixels = width * height
        var segments: [Data] = []
        for s in 0..<(samplesPerPixel * bytesPerSample) {
            let sample = s / bytesPerSample
            let shift = UInt16(8 * (bytesPerSample - 1 - s % bytesPerSample))
            var plane = [UInt8](repeating: 0, count: pixels)
            for k in 0..<pixels { plane[k] = UInt8(truncatingIfNeeded: samples[k * samplesPerPixel + sample] >> shift) }
            var seg = Data()
            for row in 0..<height { packBits(plane[(row * width)..<((row + 1) * width)], into: &seg) }
            if seg.count % 2 == 1 { seg.append(0) }
            segments.append(seg)
        }
        var out = Data(count: 64)
        out.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(segments.count).littleEndian, toByteOffset: 0, as: UInt32.self)
            var off = 64
            for (i, s) in segments.enumerated() {
                raw.storeBytes(of: UInt32(off).littleEndian, toByteOffset: 4 + 4 * i, as: UInt32.self)
                off += s.count
            }
        }
        for s in segments { out.append(s) }
        return out
    }

    static func packBits(_ src: ArraySlice<UInt8>, into out: inout Data) {
        let a = Array(src)
        var i = 0
        while i < a.count {
            // run?
            var run = 1
            while i + run < a.count && a[i + run] == a[i] && run < 128 { run += 1 }
            if run >= 2 {
                out.append(UInt8(bitPattern: Int8(1 - run)))
                out.append(a[i])
                i += run
                continue
            }
            var lit = 1
            while i + lit < a.count && lit < 128 {
                if i + lit + 1 < a.count && a[i + lit] == a[i + lit + 1] { break }
                lit += 1
            }
            out.append(UInt8(lit - 1))
            out.append(contentsOf: a[i..<(i + lit)])
            i += lit
        }
    }
}
