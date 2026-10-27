import Foundation

/// Output of the still-image codecs: interleaved samples at full resolution.
public struct DecodedImage {
    public var width: Int
    public var height: Int
    public var components: Int
    public var precision: Int
    public var samples: [UInt16]
    /// True when the codec already converted YCbCr to RGB.
    public var isRGB: Bool
    /// True when sample values are two's-complement signed (JPEG 2000 signed components).
    public var signed: Bool = false

    public init(width: Int, height: Int, components: Int, precision: Int, samples: [UInt16], isRGB: Bool, signed: Bool = false) {
        self.width = width
        self.height = height
        self.components = components
        self.precision = precision
        self.samples = samples
        self.isRGB = isRGB
        self.signed = signed
    }
}

/// ITU-T T.81 decoder: baseline / extended sequential (8 & 12-bit), progressive, and lossless (process 14).
public final class JPEGDecoder {
    private struct Huffman {
        var lookup = [UInt16](repeating: 0, count: 512) // (length << 8) | value for codes <= 9 bits; 0 = miss
        var maxcode = [Int32](repeating: -1, count: 18)
        var valptr = [Int32](repeating: 0, count: 17)
        var mincode = [Int32](repeating: 0, count: 17)
        var values = [UInt8]()

        init() {}

        init(counts: [UInt8], values: [UInt8]) {
            self.values = values
            var code: Int32 = 0
            var k: Int32 = 0
            for len in 1...16 {
                let n = Int32(counts[len - 1])
                valptr[len] = k
                mincode[len] = code
                if n > 0 {
                    if len <= 9 {
                        for i in 0..<Int(n) {
                            let c = Int(code) + i
                            let shift = 9 - len
                            let base = c << shift
                            for j in 0..<(1 << shift) where base + j < 512 {
                                lookup[base + j] = UInt16(len << 8) | UInt16(values[Int(k) + i])
                            }
                        }
                    }
                    code += n
                    k += n
                    maxcode[len] = code - 1
                } else {
                    maxcode[len] = -1
                }
                code <<= 1
            }
            maxcode[17] = Int32.max
        }
    }

    private struct Component {
        var id: UInt8
        var h: Int
        var v: Int
        var tq: Int
        var width = 0       // samples
        var height = 0
        var blocksPerLine = 0
        var blocksPerColumn = 0
        var coefficients: [Int16] = []
        var dcTable = 0
        var acTable = 0
        var pred: Int32 = 0
        var plane: [UInt16] = []
    }

    private struct BitReader {
        let base: UnsafePointer<UInt8>
        let end: Int
        var pos: Int
        var buf: UInt64 = 0
        var count = 0
        var marker = false

        @inline(__always) mutating func fill() {
            while count <= 56 {
                var b: UInt8 = 0
                if !marker && pos < end {
                    b = base[pos]
                    if b == 0xFF {
                        let n: UInt8 = pos + 1 < end ? base[pos + 1] : 0xD9
                        if n == 0 { pos += 2 } else if n >= 0xD0 && n <= 0xD7 || n != 0 { marker = true; b = 0 }
                    } else {
                        pos += 1
                    }
                }
                buf |= UInt64(b) << UInt64(56 - count)
                count += 8
            }
        }

        @inline(__always) mutating func peek(_ n: Int) -> Int {
            if count < n { fill() }
            return Int(buf >> UInt64(64 - n))
        }

        @inline(__always) mutating func skip(_ n: Int) {
            buf <<= UInt64(n)
            count -= n
        }

        @inline(__always) mutating func bits(_ n: Int) -> Int {
            if n == 0 { return 0 }
            let v = peek(n)
            skip(n)
            return v
        }

        @inline(__always) mutating func bit() -> Int { bits(1) }

        mutating func restart() {
            buf = 0; count = 0; marker = false
            // find RSTn
            while pos + 1 < end {
                if base[pos] == 0xFF && base[pos + 1] >= 0xD0 && base[pos + 1] <= 0xD7 { pos += 2; return }
                if base[pos] == 0xFF && base[pos + 1] != 0 && base[pos + 1] != 0xFF { return }
                pos += 1
            }
        }
    }

    private var qt = [[Float]](repeating: [Float](repeating: 1, count: 64), count: 4)
    private var dcTables = [Huffman](repeating: Huffman(), count: 4)
    private var acTables = [Huffman](repeating: Huffman(), count: 4)
    private var components: [Component] = []
    private var frameType = 0 // 0 baseline/extended, 2 progressive, 3 lossless
    private var precision = 8
    private var width = 0
    private var height = 0
    private var hMax = 1
    private var vMax = 1
    private var mcusPerLine = 0
    private var mcusPerColumn = 0
    private var restartInterval = 0
    private var adobeTransform: Int? = nil
    private var jfif = false
    private var eobrun = 0

    static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21,
        28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61,
        54, 47, 55, 62, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63,
    ]

    static let aan: [Float] = [1.0, 1.387039845, 1.306562965, 1.175875602, 1.0, 0.785694958, 0.541196100, 0.275899379]

    public init() {}

    /// Decodes a complete JPEG stream. `rawComponents` disables YCbCr->RGB conversion.
    /// `assumeRGB` is used when the stream has no JFIF/Adobe marker to say how 3-component data is coded
    /// (DICOM Photometric Interpretation RGB means the components are already RGB).
    public static func decode(_ data: Data, rawComponents: Bool = false, assumeRGB: Bool = false) throws -> DecodedImage {
        let d = JPEGDecoder()
        d.assumeRGB = assumeRGB
        return try d.run(data, rawComponents: rawComponents)
    }

    var assumeRGB = false

    /// Reads SOF to report precision / components without decoding.
    public static func frameInfo(_ data: Data) -> (precision: Int, width: Int, height: Int, components: Int, process: Int)? {
        let b = [UInt8](data.prefix(65536))
        var i = 2
        while i + 4 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let m = b[i + 1]
            if m == 0xFF { i += 1; continue }
            if m == 0xD8 || (m >= 0xD0 && m <= 0xD7) || m == 0x01 { i += 2; continue }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if (m >= 0xC0 && m <= 0xC3) || (m >= 0xC5 && m <= 0xC7) || (m >= 0xC9 && m <= 0xCB) || (m >= 0xCD && m <= 0xCF) {
                guard i + 9 < b.count else { return nil }
                let p = Int(b[i + 4])
                let h = Int(b[i + 5]) << 8 | Int(b[i + 6])
                let w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                return (p, w, h, Int(b[i + 9]), Int(m - 0xC0))
            }
            i += 2 + len
        }
        return nil
    }

    private func run(_ data: Data, rawComponents: Bool) throws -> DecodedImage {
        try data.withUnsafeBytes { raw -> DecodedImage in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress, raw.count > 4 else { throw DICOMError.decode("empty JPEG") }
            let n = raw.count
            var pos = 0
            // Find SOI
            while pos + 1 < n && !(base[pos] == 0xFF && base[pos + 1] == 0xD8) { pos += 1 }
            guard pos + 1 < n else { throw DICOMError.decode("JPEG SOI not found") }
            pos += 2
            var frameSeen = false
            func u16(_ p: Int) -> Int { Int(base[p]) << 8 | Int(base[p + 1]) }

            markerLoop: while pos + 1 < n {
                if base[pos] != 0xFF { pos += 1; continue }
                var marker = base[pos + 1]
                pos += 2
                while marker == 0xFF && pos < n { marker = base[pos]; pos += 1 }
                switch marker {
                case 0xD8, 0x01, 0xD0...0xD7:
                    continue
                case 0xD9:
                    break markerLoop
                default:
                    break
                }
                guard pos + 2 <= n else { break }
                let len = u16(pos)
                let segStart = pos + 2
                let segEnd = min(n, pos + len)
                switch marker {
                case 0xDB: // DQT
                    var p = segStart
                    while p < segEnd {
                        let pq = Int(base[p] >> 4), tq = Int(base[p] & 15)
                        p += 1
                        var table = [Float](repeating: 0, count: 64)
                        for k in 0..<64 {
                            let v: Int
                            if pq == 0 { v = Int(base[p]); p += 1 } else { v = u16(p); p += 2 }
                            table[JPEGDecoder.zigzag[k]] = Float(v)
                        }
                        if tq < 4 { qt[tq] = table }
                    }
                case 0xC4: // DHT
                    var p = segStart
                    while p + 17 <= segEnd {
                        let tc = Int(base[p] >> 4), th = Int(base[p] & 15)
                        p += 1
                        var counts = [UInt8](repeating: 0, count: 16)
                        var total = 0
                        for i in 0..<16 { counts[i] = base[p + i]; total += Int(counts[i]) }
                        p += 16
                        guard p + total <= segEnd else { break }
                        let vals = Array(UnsafeBufferPointer(start: base + p, count: total))
                        p += total
                        let h = Huffman(counts: counts, values: vals)
                        if tc == 0 { dcTables[th & 3] = h } else { acTables[th & 3] = h }
                    }
                case 0xC0, 0xC1, 0xC2, 0xC3:
                    frameType = marker == 0xC2 ? 2 : (marker == 0xC3 ? 3 : 0)
                    precision = Int(base[segStart])
                    height = u16(segStart + 1)
                    width = u16(segStart + 3)
                    let nc = Int(base[segStart + 5])
                    components = []
                    var p = segStart + 6
                    for _ in 0..<nc {
                        let c = Component(id: base[p], h: max(1, Int(base[p + 1] >> 4)), v: max(1, Int(base[p + 1] & 15)), tq: Int(base[p + 2] & 3))
                        components.append(c)
                        p += 3
                    }
                    try prepareFrame()
                    frameSeen = true
                case 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
                    throw DICOMError.unsupported("JPEG process SOF\(marker - 0xC0) (hierarchical/arithmetic)")
                case 0xDD:
                    restartInterval = u16(segStart)
                case 0xEE:
                    if len >= 12, base[segStart] == 0x41, base[segStart + 1] == 0x64, base[segStart + 2] == 0x6F, base[segStart + 3] == 0x62, base[segStart + 4] == 0x65 {
                        adobeTransform = Int(base[segStart + 11])
                    }
                case 0xE0:
                    if len >= 7, base[segStart] == 0x4A, base[segStart + 1] == 0x46, base[segStart + 2] == 0x49, base[segStart + 3] == 0x46 { jfif = true }
                case 0xDC: // DNL
                    if height == 0 { height = u16(segStart); try prepareFrame() }
                case 0xDA:
                    guard frameSeen else { throw DICOMError.decode("SOS before SOF") }
                    let ns = Int(base[segStart])
                    var p = segStart + 1
                    var scomps: [Int] = []
                    for _ in 0..<ns {
                        let cid = base[p], tables = base[p + 1]
                        p += 2
                        if let idx = components.firstIndex(where: { $0.id == cid }) {
                            components[idx].dcTable = Int(tables >> 4) & 3
                            components[idx].acTable = Int(tables & 15) & 3
                            scomps.append(idx)
                        }
                    }
                    let ss = Int(base[p]), se = Int(base[p + 1]), ah = Int(base[p + 2] >> 4), al = Int(base[p + 2] & 15)
                    var reader = BitReader(base: base, end: n, pos: segEnd)
                    if frameType == 3 {
                        decodeLosslessScan(&reader, scomps: scomps, predictor: ss, pt: al)
                    } else {
                        decodeScan(&reader, scomps: scomps, ss: ss, se: se, ah: ah, al: al)
                    }
                    // continue after entropy-coded data
                    pos = reader.pos
                    while pos + 1 < n {
                        if base[pos] == 0xFF && base[pos + 1] != 0 && !(base[pos + 1] >= 0xD0 && base[pos + 1] <= 0xD7) { break }
                        pos += 1
                    }
                    continue markerLoop
                default:
                    break
                }
                pos = segStart - 2 + len
            }
            guard frameSeen else { throw DICOMError.decode("no JPEG frame") }
            return output(rawComponents: rawComponents)
        }
    }

    private func prepareFrame() throws {
        guard width > 0, height > 0, !components.isEmpty else {
            if height == 0 { return } // wait for DNL
            throw DICOMError.decode("bad JPEG frame header")
        }
        hMax = components.map(\.h).max() ?? 1
        vMax = components.map(\.v).max() ?? 1
        mcusPerLine = (width + 8 * hMax - 1) / (8 * hMax)
        mcusPerColumn = (height + 8 * vMax - 1) / (8 * vMax)
        for i in components.indices {
            var c = components[i]
            c.width = (width * c.h + hMax - 1) / hMax
            c.height = (height * c.v + vMax - 1) / vMax
            if frameType == 3 {
                c.plane = [UInt16](repeating: 0, count: c.width * c.height)
            } else {
                c.blocksPerLine = mcusPerLine * c.h
                c.blocksPerColumn = mcusPerColumn * c.v
                c.coefficients = [Int16](repeating: 0, count: c.blocksPerLine * c.blocksPerColumn * 64)
            }
            components[i] = c
        }
    }

    // MARK: - Huffman

    @inline(__always) private func decodeHuffman(_ r: inout BitReader, _ h: inout Huffman) -> Int {
        let look = h.lookup[r.peek(9)]
        if look != 0 {
            r.skip(Int(look >> 8))
            return Int(look & 0xFF)
        }
        var code = Int32(r.peek(10))
        var len = 10
        while len <= 16 && code > h.maxcode[len] {
            len += 1
            code = Int32(r.peek(len))
        }
        if len > 16 { r.skip(1); return 0 }
        r.skip(len)
        let idx = Int(h.valptr[len] + code - h.mincode[len])
        return idx < h.values.count ? Int(h.values[idx]) : 0
    }

    @inline(__always) private func extend(_ v: Int, _ t: Int) -> Int {
        t == 0 ? 0 : (v < (1 << (t - 1)) ? v - (1 << t) + 1 : v)
    }

    // MARK: - DCT scans

    private func decodeScan(_ r: inout BitReader, scomps: [Int], ss: Int, se: Int, ah: Int, al: Int) {
        let progressive = frameType == 2
        for i in components.indices { components[i].pred = 0 }
        eobrun = 0
        let single = scomps.count == 1
        let totalUnits: Int
        if single {
            let c = components[scomps[0]]
            let bpl = (c.width + 7) / 8, bpc = (c.height + 7) / 8
            totalUnits = bpl * bpc
        } else {
            totalUnits = mcusPerLine * mcusPerColumn
        }
        var unit = 0
        var restartsLeft = restartInterval
        while unit < totalUnits {
            if restartInterval > 0 {
                if restartsLeft == 0 {
                    r.restart()
                    for i in components.indices { components[i].pred = 0 }
                    eobrun = 0
                    restartsLeft = restartInterval
                }
                restartsLeft -= 1
            }
            if single {
                let ci = scomps[0]
                let bpl = (components[ci].width + 7) / 8
                let row = unit / bpl, col = unit % bpl
                let off = (row * components[ci].blocksPerLine + col) * 64
                decodeBlock(&r, ci, off, progressive: progressive, ss: ss, se: se, ah: ah, al: al)
            } else {
                let mrow = unit / mcusPerLine, mcol = unit % mcusPerLine
                for ci in scomps {
                    let c = components[ci]
                    for v in 0..<c.v {
                        for h in 0..<c.h {
                            let brow = mrow * c.v + v, bcol = mcol * c.h + h
                            let off = (brow * c.blocksPerLine + bcol) * 64
                            decodeBlock(&r, ci, off, progressive: progressive, ss: ss, se: se, ah: ah, al: al)
                        }
                    }
                }
            }
            unit += 1
        }
    }

    @inline(__always) private func decodeBlock(_ r: inout BitReader, _ ci: Int, _ off: Int, progressive: Bool, ss: Int, se: Int, ah: Int, al: Int) {
        let dct = components[ci].dcTable, act = components[ci].acTable
        if !progressive {
            // sequential: full block
            let t = decodeHuffman(&r, &dcTables[dct])
            let diff = t == 0 ? 0 : extend(r.bits(t), t)
            components[ci].pred += Int32(diff)
            components[ci].coefficients[off] = Int16(truncatingIfNeeded: components[ci].pred)
            var k = 1
            while k < 64 {
                let rs = decodeHuffman(&r, &acTables[act])
                let s = rs & 15, rr = rs >> 4
                if s == 0 {
                    if rr < 15 { break }
                    k += 16
                    continue
                }
                k += rr
                if k > 63 { break }
                components[ci].coefficients[off + JPEGDecoder.zigzag[k]] = Int16(truncatingIfNeeded: extend(r.bits(s), s))
                k += 1
            }
            return
        }
        if ss == 0 {
            // DC scan
            if ah == 0 {
                let t = decodeHuffman(&r, &dcTables[dct])
                let diff = t == 0 ? 0 : extend(r.bits(t), t)
                components[ci].pred += Int32(diff)
                components[ci].coefficients[off] = Int16(truncatingIfNeeded: components[ci].pred << Int32(al))
            } else if r.bit() != 0 {
                components[ci].coefficients[off] |= Int16(truncatingIfNeeded: 1 << al)
            }
            return
        }
        if ah == 0 {
            if eobrun > 0 { eobrun -= 1; return }
            var k = ss
            while k <= se {
                let rs = decodeHuffman(&r, &acTables[act])
                let s = rs & 15, rr = rs >> 4
                if s == 0 {
                    if rr < 15 {
                        eobrun = (1 << rr) - 1
                        if rr > 0 { eobrun += r.bits(rr) }
                        break
                    }
                    k += 16
                    continue
                }
                k += rr
                if k > 63 { break }
                components[ci].coefficients[off + JPEGDecoder.zigzag[k]] = Int16(truncatingIfNeeded: extend(r.bits(s), s) * (1 << al))
                k += 1
            }
            return
        }
        // AC refinement
        let p1 = Int16(truncatingIfNeeded: 1 << al), m1 = Int16(truncatingIfNeeded: -1 << al)
        var k = ss
        if eobrun == 0 {
            while k <= se {
                let rs = decodeHuffman(&r, &acTables[act])
                var rr = rs >> 4
                var s: Int16 = 0
                if rs & 15 != 0 {
                    s = r.bit() != 0 ? p1 : m1
                } else if rr != 15 {
                    eobrun = 1 << rr
                    if rr > 0 { eobrun += r.bits(rr) }
                    break
                }
                while k <= se {
                    let z = off + JPEGDecoder.zigzag[k]
                    let coef = components[ci].coefficients[z]
                    if coef != 0 {
                        if r.bit() != 0 && (coef & p1) == 0 {
                            components[ci].coefficients[z] = coef >= 0 ? coef &+ p1 : coef &+ m1
                        }
                    } else {
                        rr -= 1
                        if rr < 0 { break }
                    }
                    k += 1
                }
                if s != 0 && k <= 63 {
                    components[ci].coefficients[off + JPEGDecoder.zigzag[k]] = s
                }
                k += 1
            }
        }
        if eobrun > 0 {
            while k <= se {
                let z = off + JPEGDecoder.zigzag[k]
                let coef = components[ci].coefficients[z]
                if coef != 0 && r.bit() != 0 && (coef & p1) == 0 {
                    components[ci].coefficients[z] = coef >= 0 ? coef &+ p1 : coef &+ m1
                }
                k += 1
            }
            eobrun -= 1
        }
    }

    // MARK: - Lossless

    private func decodeLosslessScan(_ r: inout BitReader, scomps: [Int], predictor: Int, pt: Int) {
        let p = precision
        let initial = 1 << max(0, p - pt - 1)
        let mask = (1 << 16) - 1
        // Number of MCUs
        let single = scomps.count == 1
        var restartsLeft = restartInterval
        var firstLineAfterRestart = true
        // For each component, track sample positions in MCU order.
        let mcuCols: Int, mcuRows: Int
        if single {
            mcuCols = components[scomps[0]].width
            mcuRows = components[scomps[0]].height
        } else {
            mcuCols = (width + hMax - 1) / hMax
            mcuRows = (height + vMax - 1) / vMax
        }
        // Work on local planes for speed
        var planes = scomps.map { components[$0].plane }
        let widths = scomps.map { components[$0].width }
        let heights = scomps.map { components[$0].height }
        let hs = scomps.map { single ? 1 : components[$0].h }
        let vs = scomps.map { single ? 1 : components[$0].v }
        var dc = scomps.map { dcTables[components[$0].dcTable] }
        var restartRowStart = 0

        for my in 0..<mcuRows {
            for mx in 0..<mcuCols {
                if restartInterval > 0 {
                    if restartsLeft == 0 {
                        r.restart()
                        restartsLeft = restartInterval
                        firstLineAfterRestart = true
                        restartRowStart = my
                    }
                    restartsLeft -= 1
                }
                for (si, _) in scomps.enumerated() {
                    let w = widths[si]
                    for v in 0..<vs[si] {
                        for h in 0..<hs[si] {
                            let y = my * vs[si] + v, x = mx * hs[si] + h
                            let t = decodeHuffman(&r, &dc[si])
                            let diff: Int
                            if t == 0 { diff = 0 } else if t == 16 { diff = 32768 } else { diff = extend(r.bits(t), t) }
                            guard y < heights[si], x < w else { continue }
                            let idx = y * w + x
                            var pred: Int
                            let atRestartTop = firstLineAfterRestart && (y - restartRowStart * vs[si]) < vs[si]
                            if (y == 0 || atRestartTop) && x == 0 {
                                pred = initial
                            } else if y == 0 || atRestartTop {
                                pred = Int(planes[si][idx - 1])
                            } else if x == 0 {
                                pred = Int(planes[si][idx - w])
                            } else {
                                let ra = Int(planes[si][idx - 1]), rb = Int(planes[si][idx - w]), rc = Int(planes[si][idx - w - 1])
                                switch predictor {
                                case 1: pred = ra
                                case 2: pred = rb
                                case 3: pred = rc
                                case 4: pred = ra + rb - rc
                                case 5: pred = ra + ((rb - rc) >> 1)
                                case 6: pred = rb + ((ra - rc) >> 1)
                                case 7: pred = (ra + rb) >> 1
                                default: pred = ra
                                }
                            }
                            planes[si][idx] = UInt16((pred + diff) & mask)
                        }
                    }
                }
            }
            firstLineAfterRestart = false
        }
        for (si, ci) in scomps.enumerated() {
            if pt > 0 { planes[si] = planes[si].map { $0 << UInt16(pt) } }
            components[ci].plane = planes[si]
        }
    }

    // MARK: - IDCT and output

    private func idctComponent(_ ci: Int) {
        var c = components[ci]
        var q = qt[c.tq]
        for i in 0..<8 { for j in 0..<8 { q[i * 8 + j] *= JPEGDecoder.aan[i] * JPEGDecoder.aan[j] / 8 } }
        let maxv = Float((1 << precision) - 1)
        let center = Float(1 << (precision - 1))
        let w = c.width, h = c.height
        var plane = [UInt16](repeating: 0, count: w * h)
        var ws = [Float](repeating: 0, count: 64)
        var outBlock = [Float](repeating: 0, count: 64)
        c.coefficients.withUnsafeBufferPointer { coefs in
            q.withUnsafeBufferPointer { qp in
                plane.withUnsafeMutableBufferPointer { out in
                    ws.withUnsafeMutableBufferPointer { wsp in
                        outBlock.withUnsafeMutableBufferPointer { ob in
                            for by in 0..<c.blocksPerColumn {
                                let y0 = by * 8
                                if y0 >= h { break }
                                for bx in 0..<c.blocksPerLine {
                                    let x0 = bx * 8
                                    if x0 >= w { break }
                                    let off = (by * c.blocksPerLine + bx) * 64
                                    JPEGDecoder.idct(coefs.baseAddress! + off, qp.baseAddress!, wsp.baseAddress!, ob.baseAddress!)
                                    let ymax = min(8, h - y0), xmax = min(8, w - x0)
                                    for yy in 0..<ymax {
                                        let row = (y0 + yy) * w + x0
                                        for xx in 0..<xmax {
                                            var v = ob[yy * 8 + xx] + center
                                            v = v < 0 ? 0 : (v > maxv ? maxv : v)
                                            out[row + xx] = UInt16(v + 0.5 > maxv ? maxv : v + 0.5)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        c.plane = plane
        c.coefficients = []
        components[ci] = c
    }

    /// AAN floating point IDCT (dequantisation and 1/8 scaling folded into q).
    @inline(__always) private static func idct(_ inp: UnsafePointer<Int16>, _ q: UnsafePointer<Float>, _ ws: UnsafeMutablePointer<Float>, _ out: UnsafeMutablePointer<Float>) {
        for col in 0..<8 {
            if inp[col + 8] == 0 && inp[col + 16] == 0 && inp[col + 24] == 0 && inp[col + 32] == 0 && inp[col + 40] == 0 && inp[col + 48] == 0 && inp[col + 56] == 0 {
                let dc = Float(inp[col]) * q[col]
                for r in 0..<8 { ws[r * 8 + col] = dc }
                continue
            }
            var tmp0 = Float(inp[col]) * q[col]
            var tmp1 = Float(inp[col + 16]) * q[col + 16]
            var tmp2 = Float(inp[col + 32]) * q[col + 32]
            var tmp3 = Float(inp[col + 48]) * q[col + 48]
            var tmp10 = tmp0 + tmp2
            var tmp11 = tmp0 - tmp2
            var tmp13 = tmp1 + tmp3
            var tmp12 = (tmp1 - tmp3) * 1.414213562 - tmp13
            tmp0 = tmp10 + tmp13
            tmp3 = tmp10 - tmp13
            tmp1 = tmp11 + tmp12
            tmp2 = tmp11 - tmp12
            var tmp4 = Float(inp[col + 8]) * q[col + 8]
            var tmp5 = Float(inp[col + 24]) * q[col + 24]
            var tmp6 = Float(inp[col + 40]) * q[col + 40]
            var tmp7 = Float(inp[col + 56]) * q[col + 56]
            let z13 = tmp6 + tmp5, z10 = tmp6 - tmp5, z11 = tmp4 + tmp7, z12 = tmp4 - tmp7
            tmp7 = z11 + z13
            tmp11 = (z11 - z13) * 1.414213562
            let z5 = (z10 + z12) * 1.847759065
            tmp10 = 1.082392200 * z12 - z5
            tmp12 = -2.613125930 * z10 + z5
            tmp6 = tmp12 - tmp7
            tmp5 = tmp11 - tmp6
            tmp4 = tmp10 + tmp5
            ws[col] = tmp0 + tmp7
            ws[col + 56] = tmp0 - tmp7
            ws[col + 8] = tmp1 + tmp6
            ws[col + 48] = tmp1 - tmp6
            ws[col + 16] = tmp2 + tmp5
            ws[col + 40] = tmp2 - tmp5
            ws[col + 32] = tmp3 + tmp4
            ws[col + 24] = tmp3 - tmp4
        }
        for row in 0..<8 {
            let w = ws + row * 8
            var tmp10 = w[0] + w[4]
            var tmp11 = w[0] - w[4]
            var tmp13 = w[2] + w[6]
            var tmp12 = (w[2] - w[6]) * 1.414213562 - tmp13
            let tmp0 = tmp10 + tmp13
            let tmp3 = tmp10 - tmp13
            let tmp1 = tmp11 + tmp12
            let tmp2 = tmp11 - tmp12
            let z13 = w[5] + w[3], z10 = w[5] - w[3], z11 = w[1] + w[7], z12 = w[1] - w[7]
            let tmp7 = z11 + z13
            tmp11 = (z11 - z13) * 1.414213562
            let z5 = (z10 + z12) * 1.847759065
            tmp10 = 1.082392200 * z12 - z5
            tmp12 = -2.613125930 * z10 + z5
            let tmp6 = tmp12 - tmp7
            let tmp5 = tmp11 - tmp6
            let tmp4 = tmp10 + tmp5
            let o = out + row * 8
            o[0] = tmp0 + tmp7
            o[7] = tmp0 - tmp7
            o[1] = tmp1 + tmp6
            o[6] = tmp1 - tmp6
            o[2] = tmp2 + tmp5
            o[5] = tmp2 - tmp5
            o[4] = tmp3 + tmp4
            o[3] = tmp3 - tmp4
            _ = tmp13
        }
    }

    private func output(rawComponents: Bool) -> DecodedImage {
        if frameType != 3 {
            for i in components.indices { idctComponent(i) }
        }
        let nc = components.count
        var samples = [UInt16](repeating: 0, count: width * height * nc)
        samples.withUnsafeMutableBufferPointer { out in
            for (ci, c) in components.enumerated() {
                let sx = hMax / c.h, sy = vMax / c.v
                c.plane.withUnsafeBufferPointer { pl in
                    if sx == 1 && sy == 1 {
                        for y in 0..<height {
                            let src = y * c.width
                            let dst = y * width * nc + ci
                            for x in 0..<width { out[dst + x * nc] = pl[src + x] }
                        }
                    } else {
                        // Triangle ("fancy") upsampling with centred sample positions, as libjpeg does.
                        let cw = c.width, ch = c.height
                        let fx = Float(sx), fy = Float(sy)
                        var x0 = [Int](repeating: 0, count: width), x1 = [Int](repeating: 0, count: width), wx = [Float](repeating: 0, count: width)
                        for x in 0..<width {
                            let p = (Float(x) + 0.5) / fx - 0.5
                            let a = Int(p.rounded(.down))
                            wx[x] = p - Float(a)
                            x0[x] = max(0, min(cw - 1, a)); x1[x] = max(0, min(cw - 1, a + 1))
                        }
                        for y in 0..<height {
                            let p = (Float(y) + 0.5) / fy - 0.5
                            let a = Int(p.rounded(.down))
                            let wy = p - Float(a)
                            let r0 = max(0, min(ch - 1, a)) * cw, r1 = max(0, min(ch - 1, a + 1)) * cw
                            let dst = y * width * nc + ci
                            for x in 0..<width {
                                let top = Float(pl[r0 + x0[x]]) * (1 - wx[x]) + Float(pl[r0 + x1[x]]) * wx[x]
                                let bot = Float(pl[r1 + x0[x]]) * (1 - wx[x]) + Float(pl[r1 + x1[x]]) * wx[x]
                                out[dst + x * nc] = UInt16(top * (1 - wy) + bot * wy + 0.5)
                            }
                        }
                    }
                }
            }
        }
        var isRGB = false
        if nc == 3 && frameType != 3 && !rawComponents {
            var transform = true
            if let a = adobeTransform { transform = a != 0 }
            else if jfif { transform = true }
            else if components[0].id == 0x52 && components[1].id == 0x47 && components[2].id == 0x42 { transform = false }
            else if assumeRGB { transform = false }
            if transform {
                let center = Float(1 << (precision - 1))
                let maxv = Float((1 << precision) - 1)
                samples.withUnsafeMutableBufferPointer { s in
                    var i = 0
                    while i + 2 < s.count {
                        let y = Float(s[i]), cb = Float(s[i + 1]) - center, cr = Float(s[i + 2]) - center
                        let r = y + 1.402 * cr
                        let g = y - 0.344136 * cb - 0.714136 * cr
                        let b = y + 1.772 * cb
                        s[i] = UInt16(min(max(r + 0.5, 0), maxv))
                        s[i + 1] = UInt16(min(max(g + 0.5, 0), maxv))
                        s[i + 2] = UInt16(min(max(b + 0.5, 0), maxv))
                        i += 3
                    }
                }
            }
            isRGB = true
        }
        return DecodedImage(width: width, height: height, components: nc, precision: precision, samples: samples, isRGB: isRGB)
    }
}
