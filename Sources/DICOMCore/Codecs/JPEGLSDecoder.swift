import Foundation

/// ITU-T T.87 (JPEG-LS) decoder supporting lossless and near-lossless coding and
/// interleave modes none / line / sample.
public final class JPEGLSDecoder {
    private struct Context {
        var A: Int32
        var B: Int32 = 0
        var C: Int32 = 0
        var N: Int32 = 1
    }

    private struct RunContext {
        var A: Int32
        var N: Int32 = 1
        var Nn: Int32 = 0
        let riType: Int32
    }

    private struct Reader {
        let base: UnsafePointer<UInt8>
        let end: Int
        var pos: Int
        var buf: UInt64 = 0
        var count = 0
        var lastFF = false
        var marker = false

        @inline(__always) mutating func fill() {
            while count <= 56 {
                if marker || pos >= end {
                    // pad with zeros
                    count += 8
                    continue
                }
                let b = base[pos]
                if lastFF {
                    if b & 0x80 != 0 { marker = true; pos -= 1; continue } // 0xFF + marker byte
                    buf |= UInt64(b & 0x7F) << UInt64(57 - count)
                    count += 7
                    pos += 1
                    lastFF = false
                } else {
                    buf |= UInt64(b) << UInt64(56 - count)
                    count += 8
                    pos += 1
                    lastFF = b == 0xFF
                }
            }
        }

        @inline(__always) mutating func bits(_ n: Int) -> Int32 {
            if n == 0 { return 0 }
            if count < n { fill() }
            let v = Int32(truncatingIfNeeded: buf >> UInt64(64 - n))
            buf <<= UInt64(n)
            count -= n
            return v
        }

        @inline(__always) mutating func bit() -> Bool { bits(1) != 0 }

        /// Number of zero bits before the next 1 bit (the 1 is consumed).
        @inline(__always) mutating func highBits() -> Int32 {
            var zeros: Int32 = 0
            while true {
                if count < 32 { fill() }
                if buf == 0 {
                    zeros += Int32(count)
                    buf = 0; count = 0
                    if marker && pos >= end { return zeros }
                    if zeros > 65536 { return zeros }
                    continue
                }
                let lz = buf.leadingZeroBitCount
                if lz < count {
                    zeros += Int32(lz)
                    buf <<= UInt64(lz + 1)
                    count -= lz + 1
                    return zeros
                }
                zeros += Int32(count)
                buf = 0; count = 0
            }
        }
    }

    private var precision = 8
    private var width = 0
    private var height = 0
    private var nComponents = 1
    private var componentIDs: [UInt8] = []
    private var maxval: Int32 = 0
    private var t1: Int32 = 0, t2: Int32 = 0, t3: Int32 = 0, reset: Int32 = 64
    private var presetMaxval: Int32 = 0, presetT1: Int32 = 0, presetT2: Int32 = 0, presetT3: Int32 = 0, presetReset: Int32 = 0
    private var near: Int32 = 0
    private var range: Int32 = 0
    private var qbpp = 0
    private var limit = 0
    private var contexts: [Context] = []
    private var runContexts: [RunContext] = []
    private var runIndex = 0
    private var planes: [[UInt16]] = []

    static let J: [Int] = [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15]

    public init() {}

    public static func decode(_ data: Data) throws -> DecodedImage {
        try JPEGLSDecoder().run(data)
    }

    private func setupParameters() {
        maxval = presetMaxval > 0 ? presetMaxval : Int32((1 << precision) - 1)
        range = (maxval + 2 * near) / (2 * near + 1) + 1
        qbpp = Int(ceil(log2(Double(range))))
        let bpp = max(2, Int(ceil(log2(Double(maxval) + 1))))
        limit = 2 * (bpp + max(8, bpp))
        func clamp(_ i: Int32, _ j: Int32) -> Int32 { (i > maxval || i < j) ? j : i }
        let basicT1: Int32 = 3, basicT2: Int32 = 7, basicT3: Int32 = 21
        var dt1: Int32, dt2: Int32, dt3: Int32
        if maxval >= 128 {
            let factor = (min(maxval, 4095) + 128) / 256
            dt1 = clamp(factor * (basicT1 - 2) + 2 + 3 * near, near + 1)
            dt2 = clamp(factor * (basicT2 - 3) + 3 + 5 * near, dt1)
            dt3 = clamp(factor * (basicT3 - 4) + 4 + 7 * near, dt2)
        } else {
            let factor = 256 / (maxval + 1)
            dt1 = clamp(max(2, basicT1 / factor + 3 * near), near + 1)
            dt2 = clamp(max(3, basicT2 / factor + 5 * near), dt1)
            dt3 = clamp(max(4, basicT3 / factor + 7 * near), dt2)
        }
        t1 = presetT1 > 0 ? presetT1 : dt1
        t2 = presetT2 > 0 ? presetT2 : dt2
        t3 = presetT3 > 0 ? presetT3 : dt3
        reset = presetReset > 0 ? presetReset : 64
        let a0 = max(2, (range + 32) / 64)
        contexts = [Context](repeating: Context(A: a0), count: 365)
        runContexts = [RunContext(A: a0, riType: 0), RunContext(A: a0, riType: 1)]
        runIndex = 0
    }

    private func run(_ data: Data) throws -> DecodedImage {
        try data.withUnsafeBytes { raw -> DecodedImage in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress, raw.count > 4 else { throw DICOMError.decode("empty JPEG-LS") }
            let n = raw.count
            var pos = 0
            while pos + 1 < n && !(base[pos] == 0xFF && base[pos + 1] == 0xD8) { pos += 1 }
            guard pos + 1 < n else { throw DICOMError.decode("JPEG-LS SOI not found") }
            pos += 2
            var frame = false
            func u16(_ p: Int) -> Int { Int(base[p]) << 8 | Int(base[p + 1]) }
            loop: while pos + 3 < n {
                guard base[pos] == 0xFF else { pos += 1; continue }
                let marker = base[pos + 1]
                pos += 2
                if marker == 0xD9 { break }
                if marker == 0xFF { pos -= 1; continue }
                if marker >= 0xD0 && marker <= 0xD7 { continue }
                let len = u16(pos)
                let seg = pos + 2
                switch marker {
                case 0xF7: // SOF55
                    precision = Int(base[seg])
                    height = u16(seg + 1)
                    width = u16(seg + 3)
                    nComponents = Int(base[seg + 5])
                    componentIDs = (0..<nComponents).map { base[seg + 6 + 3 * $0] }
                    planes = [[UInt16]](repeating: [UInt16](repeating: 0, count: width * height), count: nComponents)
                    frame = true
                case 0xF8: // LSE
                    let id = base[seg]
                    if id == 1 && len >= 13 {
                        presetMaxval = Int32(u16(seg + 1)); presetT1 = Int32(u16(seg + 3)); presetT2 = Int32(u16(seg + 5))
                        presetT3 = Int32(u16(seg + 7)); presetReset = Int32(u16(seg + 9))
                    } else if id == 4 && len >= 6 {
                        // oversize image dimensions
                        let wxy = Int(base[seg + 1])
                        if wxy == 2 { height = u16(seg + 2); width = u16(seg + 4) }
                        else if wxy == 3 { height = Int(base[seg + 2]) << 16 | u16(seg + 3); width = Int(base[seg + 5]) << 16 | u16(seg + 6) }
                        else if wxy == 4 { height = Int(base[seg + 2]) << 24 | Int(base[seg + 3]) << 16 | u16(seg + 4); width = Int(base[seg + 6]) << 24 | Int(base[seg + 7]) << 16 | u16(seg + 8) }
                        planes = [[UInt16]](repeating: [UInt16](repeating: 0, count: width * height), count: nComponents)
                    } else if id == 2 || id == 3 {
                        throw DICOMError.unsupported("JPEG-LS mapping tables")
                    }
                case 0xDA:
                    guard frame else { throw DICOMError.decode("JPEG-LS SOS before SOF") }
                    let ns = Int(base[seg])
                    var comps: [Int] = []
                    for i in 0..<ns {
                        let cid = base[seg + 1 + 2 * i]
                        comps.append(componentIDs.firstIndex(of: cid) ?? i)
                    }
                    let p = seg + 1 + 2 * ns
                    near = Int32(base[p])
                    let ilv = Int(base[p + 1])
                    setupParameters()
                    var reader = Reader(base: base, end: n, pos: seg + len - 2)
                    if ns == 1 {
                        decodePlanar(&reader, component: comps[0])
                    } else if ilv == 1 {
                        decodeLineInterleaved(&reader, comps: comps)
                    } else {
                        decodeSampleInterleaved(&reader, comps: comps)
                    }
                    pos = reader.pos
                    while pos + 1 < n && !(base[pos] == 0xFF && base[pos + 1] >= 0x80 && base[pos + 1] != 0xFF) { pos += 1 }
                    continue loop
                default:
                    break
                }
                pos = seg - 2 + len
            }
            guard frame else { throw DICOMError.decode("no JPEG-LS frame") }
            var samples = [UInt16](repeating: 0, count: width * height * nComponents)
            for c in 0..<nComponents {
                let pl = planes[c]
                var i = c
                for v in pl { samples[i] = v; i += nComponents }
            }
            return DecodedImage(width: width, height: height, components: nComponents, precision: precision, samples: samples, isRGB: false)
        }
    }

    // MARK: - Shared sample coding

    @inline(__always) private func quantize(_ d: Int32) -> Int32 {
        if d <= -t3 { return -4 }
        if d <= -t2 { return -3 }
        if d <= -t1 { return -2 }
        if d < -near { return -1 }
        if d <= near { return 0 }
        if d < t1 { return 1 }
        if d < t2 { return 2 }
        if d < t3 { return 3 }
        return 4
    }

    @inline(__always) private func fix(_ v: Int32) -> Int32 {
        var val = v
        if val < -near { val += range * (2 * near + 1) }
        else if val > maxval + near { val -= range * (2 * near + 1) }
        return val < 0 ? 0 : (val > maxval ? maxval : val)
    }

    @inline(__always) private func decodeValue(_ r: inout Reader, k: Int, limit lim: Int) -> Int32 {
        let high = r.highBits()
        if Int(high) >= lim - (qbpp + 1) { return r.bits(qbpp) + 1 }
        if k == 0 { return high }
        return (high << Int32(k)) + r.bits(k)
    }

    @inline(__always) private func regular(_ r: inout Reader, qs: Int32, pred: Int32) -> Int32 {
        let sign: Int32 = qs < 0 ? -1 : 0
        let q = Int((sign ^ qs) - sign)
        var ctx = contexts[q]
        var k = 0
        while (ctx.N << Int32(k)) < ctx.A { k += 1 }
        let cs = sign == 0 ? ctx.C : -ctx.C
        var px = pred + cs
        px = px < 0 ? 0 : (px > maxval ? maxval : px)
        let m = decodeValue(&r, k: k, limit: limit)
        var err = ((m << 31) >> 31) ^ (m >> 1)
        if k == 0 && near == 0 && 2 * ctx.B + ctx.N - 1 < 0 { err ^= -1 }
        // update
        ctx.B += err * (2 * near + 1)
        ctx.A += abs(err)
        if ctx.N == reset { ctx.A >>= 1; ctx.B >>= 1; ctx.N >>= 1 }
        ctx.N += 1
        if ctx.B + ctx.N <= 0 {
            ctx.B += ctx.N
            if ctx.B <= -ctx.N { ctx.B = -ctx.N + 1 }
            if ctx.C > -128 { ctx.C -= 1 }
        } else if ctx.B > 0 {
            ctx.B -= ctx.N
            if ctx.B > 0 { ctx.B = 0 }
            if ctx.C < 127 { ctx.C += 1 }
        }
        contexts[q] = ctx
        if sign != 0 { err = -err }
        return fix(px + err * (2 * near + 1))
    }

    @inline(__always) private func decodeRIError(_ r: inout Reader, _ ci: Int) -> Int32 {
        var ctx = runContexts[ci]
        let temp = ctx.A + (ctx.N >> 1) * ctx.riType
        var nt = ctx.N
        var k = 0
        while nt < temp { nt <<= 1; k += 1 }
        let em = decodeValue(&r, k: k, limit: limit - JPEGLSDecoder.J[runIndex] - 1)
        let t = em + ctx.riType
        let map = t & 1
        let errAbs = (t + map) / 2
        let err: Int32 = ((k != 0 || 2 * ctx.Nn >= ctx.N) == (map == 1)) ? -errAbs : errAbs
        if err < 0 { ctx.Nn += 1 }
        ctx.A += (em + 1 - ctx.riType) >> 1
        if ctx.N == reset { ctx.A >>= 1; ctx.N >>= 1; ctx.Nn >>= 1 }
        ctx.N += 1
        runContexts[ci] = ctx
        return err
    }

    /// Decodes run length; returns number of samples equal to Ra.
    @inline(__always) private func decodeRunLength(_ r: inout Reader, remaining: Int) -> Int {
        var index = 0
        while r.bit() {
            let count = min(1 << JPEGLSDecoder.J[runIndex], remaining - index)
            index += count
            if count == (1 << JPEGLSDecoder.J[runIndex]) { runIndex = min(31, runIndex + 1) }
            if index == remaining { break }
        }
        if index != remaining {
            index += JPEGLSDecoder.J[runIndex] > 0 ? Int(r.bits(JPEGLSDecoder.J[runIndex])) : 0
        }
        return min(index, remaining)
    }

    @inline(__always) private func sgn(_ v: Int32) -> Int32 { (v >> 31) | 1 }

    // MARK: - Scan decoders

    /// Line buffers have one guard sample on each side: index x maps to buffer[x + 1].
    private func decodeLine(_ r: inout Reader, prev: UnsafeMutablePointer<Int32>, cur: UnsafeMutablePointer<Int32>) {
        prev[width + 1] = prev[width]
        cur[0] = prev[1]
        var x = 0
        while x < width {
            let ra = cur[x], rb = prev[x + 1], rc = prev[x], rd = prev[x + 2]
            let qs = quantize(rd - rb) * 81 + quantize(rb - rc) * 9 + quantize(rc - ra)
            if qs != 0 {
                let px: Int32
                if rc >= max(ra, rb) { px = min(ra, rb) } else if rc <= min(ra, rb) { px = max(ra, rb) } else { px = ra + rb - rc }
                cur[x + 1] = regular(&r, qs: qs, pred: px)
                x += 1
            } else {
                let runLen = decodeRunLength(&r, remaining: width - x)
                for i in 0..<runLen { cur[x + 1 + i] = ra }
                x += runLen
                if x == width { break }
                // interruption sample
                let rbI = prev[x + 1]
                let v: Int32
                if abs(ra - rbI) <= near {
                    let e = decodeRIError(&r, 1)
                    v = fix(ra + e * (2 * near + 1))
                } else {
                    let e = decodeRIError(&r, 0)
                    v = fix(rbI + e * sgn(rbI - ra) * (2 * near + 1))
                }
                cur[x + 1] = v
                runIndex = max(0, runIndex - 1)
                x += 1
            }
        }
    }

    private func decodePlanar(_ r: inout Reader, component c: Int) {
        var a = [Int32](repeating: 0, count: width + 2)
        var b = [Int32](repeating: 0, count: width + 2)
        a.withUnsafeMutableBufferPointer { pa in
            b.withUnsafeMutableBufferPointer { pb in
                var prev = pa.baseAddress!, cur = pb.baseAddress!
                for y in 0..<height {
                    decodeLine(&r, prev: prev, cur: cur)
                    let row = y * width
                    for x in 0..<width { planes[c][row + x] = UInt16(truncatingIfNeeded: cur[x + 1]) }
                    swap(&prev, &cur)
                }
            }
        }
    }

    private func decodeLineInterleaved(_ r: inout Reader, comps: [Int]) {
        let nc = comps.count
        var bufs = [[Int32]](repeating: [Int32](repeating: 0, count: width + 2), count: nc * 2)
        var runIdx = [Int](repeating: 0, count: nc)
        for y in 0..<height {
            for (i, c) in comps.enumerated() {
                let pi = i * 2 + (y & 1), ci = i * 2 + 1 - (y & 1)
                runIndex = runIdx[i]
                var prevBuf = bufs[pi]
                var curBuf = bufs[ci]
                prevBuf.withUnsafeMutableBufferPointer { pp in
                    curBuf.withUnsafeMutableBufferPointer { cp in
                        decodeLine(&r, prev: pp.baseAddress!, cur: cp.baseAddress!)
                    }
                }
                runIdx[i] = runIndex
                let row = y * width
                for x in 0..<width { planes[c][row + x] = UInt16(truncatingIfNeeded: curBuf[x + 1]) }
                bufs[pi] = prevBuf
                bufs[ci] = curBuf
            }
        }
    }

    private func decodeSampleInterleaved(_ r: inout Reader, comps: [Int]) {
        let nc = comps.count
        var prev = [[Int32]](repeating: [Int32](repeating: 0, count: width + 2), count: nc)
        var cur = [[Int32]](repeating: [Int32](repeating: 0, count: width + 2), count: nc)
        for y in 0..<height {
            for c in 0..<nc {
                prev[c][width + 1] = prev[c][width]
                cur[c][0] = prev[c][1]
            }
            var x = 0
            while x < width {
                var qs = [Int32](repeating: 0, count: nc)
                var allZero = true
                for c in 0..<nc {
                    let ra = cur[c][x], rb = prev[c][x + 1], rc = prev[c][x], rd = prev[c][x + 2]
                    qs[c] = quantize(rd - rb) * 81 + quantize(rb - rc) * 9 + quantize(rc - ra)
                    if qs[c] != 0 { allZero = false }
                }
                if !allZero {
                    for c in 0..<nc {
                        let ra = cur[c][x], rb = prev[c][x + 1], rc = prev[c][x]
                        let px: Int32
                        if rc >= max(ra, rb) { px = min(ra, rb) } else if rc <= min(ra, rb) { px = max(ra, rb) } else { px = ra + rb - rc }
                        cur[c][x + 1] = regular(&r, qs: qs[c], pred: px)
                    }
                    x += 1
                } else {
                    let runLen = decodeRunLength(&r, remaining: width - x)
                    for c in 0..<nc { let ra = cur[c][x]; for i in 0..<runLen { cur[c][x + 1 + i] = ra } }
                    x += runLen
                    if x == width { break }
                    for c in 0..<nc {
                        let ra = cur[c][x], rb = prev[c][x + 1]
                        let e = decodeRIError(&r, 0)
                        cur[c][x + 1] = fix(rb + e * sgn(rb - ra) * (2 * near + 1))
                    }
                    runIndex = max(0, runIndex - 1)
                    x += 1
                }
            }
            let row = y * width
            for (c, comp) in comps.enumerated() {
                for xx in 0..<width { planes[comp][row + xx] = UInt16(truncatingIfNeeded: cur[c][xx + 1]) }
            }
            swap(&prev, &cur)
        }
    }
}
