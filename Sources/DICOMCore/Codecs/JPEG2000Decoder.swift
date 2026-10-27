import Foundation

/// Native JPEG 2000 (ITU-T T.800) decoder: codestream or JP2, tiles, all progression orders,
/// POC/PPM/PPT, code-block styles, ROI maxshift, 5/3 and 9/7 wavelets, RCT/ICT.
public final class JPEG2000Decoder {

    // MARK: - Parameters

    struct ComponentSiz { var precision: Int; var signed: Bool; var dx: Int; var dy: Int }

    struct CodingStyle {
        var scod = 0
        var progression = 0
        var layers = 1
        var mct = 0
        var levels = 5
        var xcb = 6
        var ycb = 6
        var cbStyle = 0
        var reversible = true
        var precincts: [(Int, Int)] = []
        func precinct(_ r: Int) -> (Int, Int) { (scod & 1) != 0 && r < precincts.count ? precincts[r] : (15, 15) }
    }

    struct Quantization {
        var style = 0
        var guardBits = 2
        var steps: [(eps: Int, mu: Int)] = []

        func step(band index: Int, level nb: Int, levels: Int) -> (eps: Int, mu: Int) {
            if style == 1 {
                let s = steps.first ?? (8, 0)
                return (s.eps - levels + nb, s.mu)
            }
            return index < steps.count ? steps[index] : (steps.last ?? (8, 0))
        }
    }

    struct ProgressionChange { var rs: Int; var cs: Int; var lye: Int; var re: Int; var ce: Int; var order: Int }

    struct HeaderSet {
        var cod: CodingStyle?
        var coc: [Int: CodingStyle] = [:]
        var qcd: Quantization?
        var qcc: [Int: Quantization] = [:]
        var rgn: [Int: Int] = [:]
        var poc: [ProgressionChange] = []
    }

    // MARK: - Geometry objects

    final class CodeBlock {
        let x0: Int, y0: Int, x1: Int, y1: Int
        var included = false
        var zeroBitplanes = 0
        var lblock = 3
        var segments: [Segment] = []
        var passes = 0
        init(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
    }

    struct Segment { var data = Data(); var passes = 0; var maxPasses = 109 }

    final class Band {
        let orientation: Int        // 0 LL, 1 HL, 2 LH, 3 HH
        let x0: Int, y0: Int, x1: Int, y1: Int
        let xcb: Int, ycb: Int
        var bitplanes = 0
        var stepSize: Float = 1
        var cbX0 = 0, cbY0 = 0, cbW = 0, cbH = 0
        var blocks: [CodeBlock] = []
        var coefficients: [Int32] = []
        var floats: [Float] = []
        var width: Int { x1 - x0 }
        var height: Int { y1 - y0 }
        init(orientation: Int, x0: Int, y0: Int, x1: Int, y1: Int, xcb: Int, ycb: Int) {
            self.orientation = orientation; self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1; self.xcb = xcb; self.ycb = ycb
        }
    }

    final class PrecinctBand {
        let cbx0: Int, cby0: Int, w: Int, h: Int
        let inclusion: TagTree
        let zeroBits: TagTree
        init(cbx0: Int, cby0: Int, w: Int, h: Int) {
            self.cbx0 = cbx0; self.cby0 = cby0; self.w = w; self.h = h
            inclusion = TagTree(w: w, h: h)
            zeroBits = TagTree(w: w, h: h)
        }
    }

    final class Resolution {
        let r: Int
        let x0: Int, y0: Int, x1: Int, y1: Int
        let ppx: Int, ppy: Int
        var precX0 = 0, precY0 = 0, precW = 0, precH = 0
        var bands: [Band] = []
        var precincts: [[PrecinctBand?]] = []     // [precinct][band]
        init(r: Int, x0: Int, y0: Int, x1: Int, y1: Int, ppx: Int, ppy: Int) {
            self.r = r; self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1; self.ppx = ppx; self.ppy = ppy
        }
    }

    final class TileComponent {
        let c: Int
        let x0: Int, y0: Int, x1: Int, y1: Int
        let style: CodingStyle
        let quant: Quantization
        let roiShift: Int
        var resolutions: [Resolution] = []
        var output: [Float] = []
        var outX0 = 0, outY0 = 0, outX1 = 0, outY1 = 0
        init(c: Int, x0: Int, y0: Int, x1: Int, y1: Int, style: CodingStyle, quant: Quantization, roiShift: Int) {
            self.c = c; self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1; self.style = style; self.quant = quant; self.roiShift = roiShift
        }
    }

    /// Tag tree (B.10.2).
    final class TagTree {
        var levels: [(w: Int, h: Int, base: Int)] = []
        var value: [Int]
        var low: [Int]
        init(w: Int, h: Int) {
            var lw = max(1, w), lh = max(1, h), base = 0
            repeat {
                levels.append((lw, lh, base))
                base += lw * lh
                if lw == 1 && lh == 1 { break }
                lw = (lw + 1) / 2; lh = (lh + 1) / 2
            } while true
            value = [Int](repeating: Int.max, count: base)
            low = [Int](repeating: 0, count: base)
        }

        /// Returns true when the leaf value is below the threshold.
        func decode(x: Int, y: Int, threshold: Int, _ bits: inout PacketBitReader) -> Bool {
            var path: [Int] = []
            var lx = x, ly = y
            for l in levels { path.append(l.base + ly * l.w + lx); lx >>= 1; ly >>= 1 }
            var lo = 0
            for node in path.reversed() {
                if lo > low[node] { low[node] = lo } else { lo = low[node] }
                while lo < threshold && lo < value[node] {
                    if bits.bit() != 0 { value[node] = lo } else { lo += 1 }
                }
                low[node] = lo
            }
            return value[path[0]] < threshold
        }

        func leafValue(x: Int, y: Int) -> Int { value[y * levels[0].w + x] }
    }

    /// Packet header bit reader with 0xFF bit stuffing.
    struct PacketBitReader {
        let data: Data
        var pos: Int
        var last: UInt8 = 0
        var left = 0

        init(data: Data, pos: Int) { self.data = data; self.pos = pos }

        mutating func bit() -> Int {
            if left == 0 {
                let stuffed = last == 0xFF
                last = pos < data.count ? data[data.startIndex + pos] : 0
                pos += 1
                left = stuffed ? 7 : 8
            }
            left -= 1
            return Int(last >> UInt8(left)) & 1
        }

        mutating func bits(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n { v = (v << 1) | bit() }
            return v
        }

        mutating func align() {
            if left > 0 || last == 0xFF {
                if last == 0xFF { pos += 1 }
            }
            left = 0
            last = 0
        }
    }

    // MARK: - State

    var width = 0, height = 0, x0 = 0, y0 = 0
    var tileW = 0, tileH = 0, tileX0 = 0, tileY0 = 0
    var comps: [ComponentSiz] = []
    var main = HeaderSet()
    var ppm: [Data] = []        // per tile-part, in codestream order
    var htj2k = false

    public static func decode(_ data: Data, reduce: Int = 0) throws -> DecodedImage {
        let d = JPEG2000Decoder()
        d.reduce = max(0, reduce)
        return try d.run(data)
    }

    /// Number of resolution levels to discard (0 = full resolution).
    var reduce = 0

    /// Human readable summary of the main header (diagnostics).
    public static func describe(_ data: Data) -> String {
        let dec = JPEG2000Decoder()
        let d = dec.codestream(data)
        var p = 2
        var lines: [String] = []
        while p + 4 <= d.count {
            let marker = d.u16be(p)
            if marker == 0xFF90 { break }
            let len = Int(d.u16be(p + 2))
            if marker == 0xFF51 {
                let n = Int(d.u16be(p + 4 + 34))
                dec.comps = (0..<n).map { i in
                    let ss = d[d.startIndex + p + 40 + 3 * i]
                    return ComponentSiz(precision: Int(ss & 0x7F) + 1, signed: ss & 0x80 != 0, dx: 1, dy: 1)
                }
                lines.append("SIZ \(d.u32be(p + 6))x\(d.u32be(p + 10)) tiles \(d.u32be(p + 22))x\(d.u32be(p + 26)) comps \(dec.comps.map { "\($0.precision)\($0.signed ? "s" : "u")" })")
            } else {
                var h = HeaderSet()
                dec.parseHeaderMarker(marker, d, p + 4, len - 2, into: &h)
                if let c = h.cod { lines.append("COD scod=\(c.scod) prog=\(c.progression) layers=\(c.layers) mct=\(c.mct) levels=\(c.levels) cb=\(c.xcb)x\(c.ycb) style=0x\(String(c.cbStyle, radix: 16)) rev=\(c.reversible) prec=\(c.precincts)") }
                if let q = h.qcd { lines.append("QCD style=\(q.style) guard=\(q.guardBits) steps=\(q.steps.prefix(6))…") }
                if !h.coc.isEmpty { lines.append("COC \(h.coc.keys.sorted())") }
                if !h.qcc.isEmpty { lines.append("QCC \(h.qcc.keys.sorted())") }
                if !h.rgn.isEmpty { lines.append("RGN \(h.rgn)") }
                if !h.poc.isEmpty { lines.append("POC \(h.poc.count)") }
                if marker == 0xFF60 { lines.append("PPM") }
            }
            p += 2 + len
        }
        var tiles = 0
        while p + 12 <= d.count, d.u16be(p) == 0xFF90 { tiles += 1; let psot = Int(d.u32be(p + 6)); if psot == 0 { break }; p += psot }
        lines.append("tile-parts \(tiles)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Codestream parsing

    fileprivate func codestream(_ data: Data) -> Data {
        // JP2 container: locate the jp2c box
        guard data.count > 12, data[data.startIndex + 4] == 0x6A, data[data.startIndex + 5] == 0x50 else { return data }
        var p = 0
        while p + 8 <= data.count {
            var len = Int(data.u32be(p))
            let type = data.u32be(p + 4)
            var hdr = 8
            if len == 1 { len = Int(data.u64be(p + 8)); hdr = 16 }
            if len == 0 { len = data.count - p }
            if type == 0x6A70_3263 { return data.subdata(in: (data.startIndex + p + hdr)..<(data.startIndex + min(data.count, p + len))) }
            p += max(len, 8)
        }
        return data
    }

    private func parseCOD(_ d: Data, _ p: Int, _ len: Int) -> CodingStyle {
        var s = CodingStyle()
        s.scod = Int(d[d.startIndex + p])
        s.progression = Int(d[d.startIndex + p + 1])
        s.layers = Int(d.u16be(p + 2))
        s.mct = Int(d[d.startIndex + p + 4])
        parseSP(d, p + 5, len - 5, &s)
        return s
    }

    private func parseSP(_ d: Data, _ p: Int, _ len: Int, _ s: inout CodingStyle) {
        s.levels = Int(d[d.startIndex + p])
        s.xcb = Int(d[d.startIndex + p + 1] & 0x0F) + 2
        s.ycb = Int(d[d.startIndex + p + 2] & 0x0F) + 2
        s.cbStyle = Int(d[d.startIndex + p + 3])
        s.reversible = d[d.startIndex + p + 4] == 1
        s.precincts = []
        if s.scod & 1 != 0 {
            for r in 0...s.levels where 5 + r < len {
                let b = d[d.startIndex + p + 5 + r]
                s.precincts.append((Int(b & 0x0F), Int(b >> 4)))
            }
        }
    }

    private func parseQCD(_ d: Data, _ p: Int, _ len: Int) -> Quantization {
        var q = Quantization()
        let sq = Int(d[d.startIndex + p])
        q.style = sq & 0x1F
        q.guardBits = sq >> 5
        var i = p + 1
        let end = p + len
        if q.style == 0 {
            while i < end { q.steps.append((Int(d[d.startIndex + i] >> 3), 0)); i += 1 }
        } else {
            while i + 1 < end { let v = Int(d.u16be(i)); q.steps.append((v >> 11, v & 0x7FF)); i += 2 }
        }
        return q
    }

    fileprivate func parseHeaderMarker(_ marker: UInt16, _ d: Data, _ p: Int, _ len: Int, into h: inout HeaderSet) {
        let cbytes = comps.count < 257 ? 1 : 2
        switch marker {
        case 0xFF52: h.cod = parseCOD(d, p, len)
        case 0xFF53:
            let c = cbytes == 1 ? Int(d[d.startIndex + p]) : Int(d.u16be(p))
            var s = h.cod ?? main.cod ?? CodingStyle()
            let scoc = Int(d[d.startIndex + p + cbytes])
            s.scod = (s.scod & ~1) | (scoc & 1)
            parseSP(d, p + cbytes + 1, len - cbytes - 1, &s)
            h.coc[c] = s
        case 0xFF5C: h.qcd = parseQCD(d, p, len)
        case 0xFF5D:
            let c = cbytes == 1 ? Int(d[d.startIndex + p]) : Int(d.u16be(p))
            h.qcc[c] = parseQCD(d, p + cbytes, len - cbytes)
        case 0xFF5E:
            let c = cbytes == 1 ? Int(d[d.startIndex + p]) : Int(d.u16be(p))
            h.rgn[c] = Int(d[d.startIndex + p + cbytes + 1])
        case 0xFF5F:
            var i = p
            let step = 5 + 2 * cbytes + 2
            while i + step <= p + len {
                let rs = Int(d[d.startIndex + i])
                let cs = cbytes == 1 ? Int(d[d.startIndex + i + 1]) : Int(d.u16be(i + 1))
                let lye = Int(d.u16be(i + 1 + cbytes))
                let re = Int(d[d.startIndex + i + 3 + cbytes])
                let ce = cbytes == 1 ? Int(d[d.startIndex + i + 4 + cbytes]) : Int(d.u16be(i + 4 + cbytes))
                let po = Int(d[d.startIndex + i + 4 + 2 * cbytes])
                h.poc.append(ProgressionChange(rs: rs, cs: cs, lye: lye, re: re, ce: ce == 0 ? 256 : ce, order: po))
                i += step
            }
        default: break
        }
    }

    private func run(_ input: Data) throws -> DecodedImage {
        let d = codestream(input)
        guard d.count > 4, d.u16be(0) == 0xFF4F else { throw DICOMError.decode("not a JPEG 2000 codestream") }
        var p = 2
        var tileParts: [Int: [(tp: Int, data: Data, header: HeaderSet, ppt: [(Int, Data)], ppmIndex: Int)]] = [:]
        var tilePartCounter = 0
        var ppmSegments: [(Int, Data)] = []
        // Main header
        while p + 4 <= d.count {
            let marker = d.u16be(p)
            if marker == 0xFF90 { break }
            let len = Int(d.u16be(p + 2))
            let seg = p + 4
            switch marker {
            case 0xFF51:
                width = Int(d.u32be(seg + 2)); height = Int(d.u32be(seg + 6))
                x0 = Int(d.u32be(seg + 10)); y0 = Int(d.u32be(seg + 14))
                tileW = Int(d.u32be(seg + 18)); tileH = Int(d.u32be(seg + 22))
                tileX0 = Int(d.u32be(seg + 26)); tileY0 = Int(d.u32be(seg + 30))
                let n = Int(d.u16be(seg + 34))
                comps = (0..<n).map { i in
                    let ss = d[d.startIndex + seg + 36 + 3 * i]
                    return ComponentSiz(precision: Int(ss & 0x7F) + 1, signed: ss & 0x80 != 0, dx: max(1, Int(d[d.startIndex + seg + 37 + 3 * i])), dy: max(1, Int(d[d.startIndex + seg + 38 + 3 * i])))
                }
            case 0xFF50: htj2k = true
            case 0xFF60:
                ppmSegments.append((Int(d[d.startIndex + seg]), d.subdata(in: (d.startIndex + seg + 1)..<(d.startIndex + min(d.count, p + 2 + len)))))
            case 0xFFD9:
                break
            default:
                parseHeaderMarker(marker, d, seg, len - 2, into: &main)
            }
            p += 2 + len
        }
        guard !comps.isEmpty, width > x0, height > y0 else { throw DICOMError.decode("JPEG 2000 SIZ missing") }
        if ((main.cod?.cbStyle ?? 0) & 0x40) != 0 { htj2k = true }
        if htj2k { throw DICOMError.unsupported("HTJ2K code-blocks") }
        // PPM: split into per tile-part packet header chunks
        if !ppmSegments.isEmpty {
            var all = Data()
            for (_, s) in ppmSegments.sorted(by: { $0.0 < $1.0 }) { all.append(s) }
            var i = 0
            while i + 4 <= all.count {
                let n = Int(all.u32be(i))
                ppm.append(all.subdata(in: (all.startIndex + i + 4)..<(all.startIndex + min(all.count, i + 4 + n))))
                i += 4 + n
            }
        }
        // Tile-parts
        while p + 12 <= d.count {
            let marker = d.u16be(p)
            guard marker == 0xFF90 else { break }
            let sotStart = p
            let isot = Int(d.u16be(p + 4))
            var psot = Int(d.u32be(p + 6))
            let tpsot = Int(d[d.startIndex + p + 10])
            if psot == 0 { psot = d.count - sotStart }
            let end = min(d.count, sotStart + psot)
            p += 12
            var h = HeaderSet()
            var ppt: [(Int, Data)] = []
            while p + 4 <= end {
                let m = d.u16be(p)
                if m == 0xFF93 { p += 2; break }
                let len = Int(d.u16be(p + 2))
                if m == 0xFF61 {
                    ppt.append((Int(d[d.startIndex + p + 4]), d.subdata(in: (d.startIndex + p + 5)..<(d.startIndex + min(end, p + 2 + len)))))
                } else {
                    parseHeaderMarker(m, d, p + 4, len - 2, into: &h)
                }
                p += 2 + len
            }
            let body = d.subdata(in: (d.startIndex + min(p, end))..<(d.startIndex + end))
            tileParts[isot, default: []].append((tpsot, body, h, ppt, tilePartCounter))
            tilePartCounter += 1
            p = end
            if p + 2 <= d.count, d.u16be(p) == 0xFFD9 { break }
        }

        // Output buffers
        let nc = comps.count
        let outComps = nc >= 3 ? 3 : 1
        let outW = ceilDiv(width, 1 << reduce) - ceilDiv(x0, 1 << reduce)
        let outH = ceilDiv(height, 1 << reduce) - ceilDiv(y0, 1 << reduce)
        var samples = [UInt16](repeating: 0, count: outW * outH * outComps)
        let numTilesX = max(1, (width - tileX0 + tileW - 1) / max(1, tileW))
        let numTilesY = max(1, (height - tileY0 + tileH - 1) / max(1, tileH))
        for t in 0..<(numTilesX * numTilesY) {
            guard let parts = tileParts[t]?.sorted(by: { $0.tp < $1.tp }) else { continue }
            try decodeTile(t, parts: parts, numTilesX: numTilesX, samples: &samples, outComps: outComps)
        }
        let signed = comps[0].signed
        return DecodedImage(width: outW, height: outH, components: outComps, precision: comps[0].precision, samples: samples, isRGB: outComps == 3, signed: signed)
    }

    // MARK: - Tile

    private func decodeTile(_ t: Int, parts: [(tp: Int, data: Data, header: HeaderSet, ppt: [(Int, Data)], ppmIndex: Int)], numTilesX: Int, samples: inout [UInt16], outComps: Int) throws {
        // Merge tile-part headers (the first tile-part may carry COD/QCD etc.)
        var th = HeaderSet()
        var body = Data()
        var pptAll: [(Int, Data)] = []
        var headerStream = Data()
        for part in parts {
            let h = part.header
            if let c = h.cod { th.cod = c }
            for (k, v) in h.coc { th.coc[k] = v }
            if let q = h.qcd { th.qcd = q }
            for (k, v) in h.qcc { th.qcc[k] = v }
            for (k, v) in h.rgn { th.rgn[k] = v }
            th.poc += h.poc
            body.append(part.data)
            pptAll += part.ppt
            if part.ppmIndex < ppm.count, !ppm.isEmpty { headerStream.append(ppm[part.ppmIndex]) }
        }
        if !pptAll.isEmpty { for (_, s) in pptAll.sorted(by: { $0.0 < $1.0 }) { headerStream.append(s) } }
        let usePacked = !headerStream.isEmpty

        let tx = t % numTilesX, ty = t / numTilesX
        let tx0 = max(tileX0 + tx * tileW, x0), ty0 = max(tileY0 + ty * tileH, y0)
        let tx1 = min(tileX0 + (tx + 1) * tileW, width), ty1 = min(tileY0 + (ty + 1) * tileH, height)
        let tileCod = th.cod ?? main.cod ?? CodingStyle()

        // Build tile components
        var tcs: [TileComponent] = []
        for (c, cs) in comps.enumerated() {
            let style = th.coc[c] ?? (th.cod != nil ? th.cod! : (main.coc[c] ?? main.cod ?? CodingStyle()))
            let quant = th.qcc[c] ?? (th.qcd != nil ? th.qcd! : (main.qcc[c] ?? main.qcd ?? Quantization()))
            let roi = th.rgn[c] ?? main.rgn[c] ?? 0
            let tc = TileComponent(c: c, x0: ceilDiv(tx0, cs.dx), y0: ceilDiv(ty0, cs.dy), x1: ceilDiv(tx1, cs.dx), y1: ceilDiv(ty1, cs.dy), style: style, quant: quant, roiShift: roi)
            buildResolutions(tc, precision: cs.precision)
            tcs.append(tc)
        }

        // Packet order
        let packets = packetOrder(tcs, tileCod: tileCod, pocs: th.poc.isEmpty ? main.poc : th.poc, tx0: tx0, ty0: ty0)
        var pos = 0
        var hdr = PacketBitReader(data: usePacked ? headerStream : body, pos: 0)
        for (layer, r, c, k) in packets {
            if pos >= body.count && !usePacked { break }
            let res = tcs[c].resolutions[r]
            let cod = tcs[c].style
            // SOP marker
            if tileCod.scod & 2 != 0, pos + 6 <= body.count, body.u16be(pos) == 0xFF91 { pos += 6 }
            if !usePacked { hdr = PacketBitReader(data: body, pos: pos) }
            var pending: [(CodeBlock, Int, Int)] = []   // block, segment index, length
            if hdr.bit() != 0 {
                for (bi, band) in res.bands.enumerated() {
                    guard let pb = res.precincts[k][bi] else { continue }
                    for j in 0..<pb.h {
                        for i in 0..<pb.w {
                            let cb = band.blocks[(pb.cby0 + j - band.cbY0) * band.cbW + (pb.cbx0 + i - band.cbX0)]
                            var included: Bool
                            if !cb.included {
                                included = pb.inclusion.decode(x: i, y: j, threshold: layer + 1, &hdr)
                            } else {
                                included = hdr.bit() != 0
                            }
                            guard included else { continue }
                            if !cb.included {
                                var th = 1
                                while !pb.zeroBits.decode(x: i, y: j, threshold: th, &hdr) { th += 1; if th > 80 { break } }
                                cb.zeroBitplanes = pb.zeroBits.leafValue(x: i, y: j)
                                cb.included = true
                            }
                            // number of passes
                            var np = 1
                            if hdr.bit() != 0 {
                                np = 2
                                if hdr.bit() != 0 {
                                    let v = hdr.bits(2)
                                    if v < 3 { np = 3 + v } else {
                                        let v5 = hdr.bits(5)
                                        np = v5 < 31 ? 6 + v5 : 37 + hdr.bits(7)
                                    }
                                }
                            }
                            while hdr.bit() != 0 { cb.lblock += 1 }
                            var remaining = np
                            if cb.segments.isEmpty || cb.segments[cb.segments.count - 1].passes >= cb.segments[cb.segments.count - 1].maxPasses {
                                cb.segments.append(Segment(maxPasses: maxPasses(cod.cbStyle, previous: cb.segments.last)))
                            }
                            var si = cb.segments.count - 1
                            while remaining > 0 {
                                let take = min(cb.segments[si].maxPasses - cb.segments[si].passes, remaining)
                                let len = hdr.bits(cb.lblock + floorLog2(take))
                                cb.segments[si].passes += take
                                cb.passes += take
                                pending.append((cb, si, len))
                                remaining -= take
                                if remaining > 0 {
                                    cb.segments.append(Segment(maxPasses: maxPasses(cod.cbStyle, previous: cb.segments[si])))
                                    si += 1
                                }
                            }
                        }
                    }
                }
            }
            hdr.align()
            if tileCod.scod & 4 != 0 {
                if usePacked {
                    if hdr.pos + 2 <= hdr.data.count, hdr.data.u16be(hdr.pos) == 0xFF92 { hdr.pos += 2 }
                } else if hdr.pos + 2 <= body.count, body.u16be(hdr.pos) == 0xFF92 { hdr.pos += 2 }
            }
            if !usePacked { pos = hdr.pos }
            for (cb, si, len) in pending {
                let a = min(pos, body.count), b = min(pos + len, body.count)
                if b > a { cb.segments[si].data.append(body.subdata(in: (body.startIndex + a)..<(body.startIndex + b))) }
                pos += len
            }
        }

        if ProcessInfo.processInfo.environment["SPECULA_J2K_DEBUG"] != nil {
            for tc in tcs { for res in tc.resolutions where res.r <= 2 { for band in res.bands {
                for cb in band.blocks {
                    print("r\(res.r) o\(band.orientation) Mb=\(band.bitplanes) cb(\(cb.x0),\(cb.y0))-(\(cb.x1),\(cb.y1)) zbp=\(cb.zeroBitplanes) passes=\(cb.passes) segs=\(cb.segments.map { "\($0.passes)p/\($0.data.count)B" })")
                }
            } } }
        }
        // Tier-1: decode all code-blocks in parallel
        var jobs: [(TileComponent, Band, CodeBlock)] = []
        for tc in tcs { for res in tc.resolutions { for band in res.bands {
            if tc.style.reversible { band.coefficients = [Int32](repeating: 0, count: max(0, band.width * band.height)) }
            else { band.floats = [Float](repeating: 0, count: max(0, band.width * band.height)) }
            for cb in band.blocks where cb.passes > 0 { jobs.append((tc, band, cb)) }
        } } }
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { j in
            let (tc, band, cb) = jobs[j]
            let w = cb.x1 - cb.x0, h = cb.y1 - cb.y0
            guard w > 0, h > 0 else { return }
            let decoder = CodeBlockDecoder(width: w, height: h, orientation: band.orientation, style: tc.style.cbStyle)
            let numBP = band.bitplanes + tc.roiShift - cb.zeroBitplanes
            guard numBP > 0 else { return }
            decoder.decode(segments: cb.segments, bitplanes: numBP, passes: cb.passes)
            // write into band
            let roi = tc.roiShift
            if tc.style.reversible {
                band.coefficients.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<h {
                        let row = (cb.y0 - band.y0 + y) * band.width + (cb.x0 - band.x0)
                        for x in 0..<w {
                            var m = decoder.reconstructedInt(x, y)
                            if roi > 0, m >= (1 << roi) { m >>= roi }
                            dst[row + x] = decoder.isNegative(x, y) ? -m : m
                        }
                    }
                }
            } else {
                let step = band.stepSize
                band.floats.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<h {
                        let row = (cb.y0 - band.y0 + y) * band.width + (cb.x0 - band.x0)
                        for x in 0..<w {
                            var m = decoder.reconstructedFloat(x, y)
                            if roi > 0, m >= Float(1 << roi) { m = Float(Int(m) >> roi) + (m - m.rounded(.down)) }
                            let v = m * step
                            dst[row + x] = decoder.isNegative(x, y) ? -v : v
                        }
                    }
                }
            }
            _ = lock
        }

        // Inverse DWT per component
        DispatchQueue.concurrentPerform(iterations: tcs.count) { i in
            inverseDWT(tcs[i])
        }

        // Inverse MCT
        if tileCod.mct == 1 && tcs.count >= 3 && tcs[0].output.count == tcs[1].output.count && tcs[1].output.count == tcs[2].output.count {
            let n = tcs[0].output.count
            if tcs[0].style.reversible {
                for i in 0..<n {
                    let y0 = tcs[0].output[i], y1 = tcs[1].output[i], y2 = tcs[2].output[i]
                    let g = y0 - ((y1 + y2) / 4).rounded(.down)
                    tcs[0].output[i] = y2 + g
                    tcs[1].output[i] = g
                    tcs[2].output[i] = y1 + g
                }
            } else {
                for i in 0..<n {
                    let y = tcs[0].output[i], cb = tcs[1].output[i], cr = tcs[2].output[i]
                    tcs[0].output[i] = y + 1.402 * cr
                    tcs[1].output[i] = y - 0.34413 * cb - 0.71414 * cr
                    tcs[2].output[i] = y + 1.772 * cb
                }
            }
        }

        // DC shift, clip and store
        let imgW = ceilDiv(width, 1 << reduce) - ceilDiv(x0, 1 << reduce)
        let imgH = ceilDiv(height, 1 << reduce) - ceilDiv(y0, 1 << reduce)
        for (c, tc) in tcs.enumerated() where c < outComps {
            let cs = comps[c]
            let lo: Float = cs.signed ? -Float(1 << (cs.precision - 1)) : 0
            let hi: Float = cs.signed ? Float((1 << (cs.precision - 1)) - 1) : Float((1 << cs.precision) - 1)
            let shift: Float = cs.signed ? 0 : Float(1 << (cs.precision - 1))
            let w = tc.outX1 - tc.outX0
            let compX0 = ceilDiv(x0, cs.dx << reduce), compY0 = ceilDiv(y0, cs.dy << reduce)
            guard tc.output.count >= w * (tc.outY1 - tc.outY0) else { continue }
            for y in tc.outY0..<tc.outY1 {
                for x in tc.outX0..<tc.outX1 {
                    var v = tc.output[(y - tc.outY0) * w + (x - tc.outX0)] + shift
                    v = v.rounded()
                    v = v < lo ? lo : (v > hi ? hi : v)
                    let s = UInt16(truncatingIfNeeded: Int32(v))
                    // place with subsampling (replicate)
                    let ix = (x - compX0), iy = (y - compY0)
                    if cs.dx == 1 && cs.dy == 1 {
                        let o = (iy * imgW + ix) * outComps + c
                        if o >= 0 && o < samples.count { samples[o] = s }
                    } else {
                        for yy in 0..<cs.dy { for xx in 0..<cs.dx {
                            let px = ix * cs.dx + xx, py = iy * cs.dy + yy
                            guard px < imgW, py < imgH else { continue }
                            samples[(py * imgW + px) * outComps + c] = s
                        } }
                    }
                }
            }
        }
    }

    private func maxPasses(_ style: Int, previous: Segment?) -> Int {
        if style & 0x04 != 0 { return 1 }                    // TERMALL
        if style & 0x01 != 0 {                               // BYPASS (lazy)
            guard let p = previous else { return 10 }
            return (p.maxPasses == 1 || p.maxPasses == 10) ? 2 : 1
        }
        return 109
    }

    private func buildResolutions(_ tc: TileComponent, precision: Int) {
        let s = tc.style
        let nl = s.levels
        var bandIndex = 0
        for r in 0...nl {
            let scale = 1 << (nl - r)
            let res = Resolution(r: r, x0: ceilDiv(tc.x0, scale), y0: ceilDiv(tc.y0, scale), x1: ceilDiv(tc.x1, scale), y1: ceilDiv(tc.y1, scale),
                                 ppx: s.precinct(r).0, ppy: s.precinct(r).1)
            if res.x1 > res.x0 {
                res.precX0 = res.x0 >> res.ppx
                res.precW = ((res.x1 + (1 << res.ppx) - 1) >> res.ppx) - res.precX0
            }
            if res.y1 > res.y0 {
                res.precY0 = res.y0 >> res.ppy
                res.precH = ((res.y1 + (1 << res.ppy) - 1) >> res.ppy) - res.precY0
            }
            let orients = r == 0 ? [0] : [1, 2, 3]
            let nb = r == 0 ? nl : nl - r + 1
            let xcb = r == 0 ? min(s.xcb, res.ppx) : min(s.xcb, res.ppx - 1)
            let ycb = r == 0 ? min(s.ycb, res.ppy) : min(s.ycb, res.ppy - 1)
            for o in orients {
                let xo = (o == 1 || o == 3) ? 1 : 0, yo = (o == 2 || o == 3) ? 1 : 0
                let half = nb > 0 ? 1 << (nb - 1) : 0
                let bx0 = ceilDiv(tc.x0 - half * xo, 1 << nb), by0 = ceilDiv(tc.y0 - half * yo, 1 << nb)
                let bx1 = ceilDiv(tc.x1 - half * xo, 1 << nb), by1 = ceilDiv(tc.y1 - half * yo, 1 << nb)
                let band = Band(orientation: o, x0: bx0, y0: by0, x1: max(bx0, bx1), y1: max(by0, by1), xcb: max(0, xcb), ycb: max(0, ycb))
                // Quantisation
                let gain = o == 0 ? 0 : (o == 3 ? 2 : 1)
                let (eps, mu) = tc.quant.step(band: bandIndex, level: nb, levels: nl)
                band.bitplanes = tc.quant.guardBits + eps - 1
                if !s.reversible {
                    band.stepSize = Float(pow(2.0, Double(precision + gain - eps)) * (1 + Double(mu) / 2048))
                }
                bandIndex += 1
                // Code-blocks
                if band.width > 0 && band.height > 0 {
                    band.cbX0 = band.x0 >> band.xcb
                    band.cbY0 = band.y0 >> band.ycb
                    band.cbW = ((band.x1 + (1 << band.xcb) - 1) >> band.xcb) - band.cbX0
                    band.cbH = ((band.y1 + (1 << band.ycb) - 1) >> band.ycb) - band.cbY0
                    for j in 0..<band.cbH {
                        for i in 0..<band.cbW {
                            let cx = (band.cbX0 + i) << band.xcb, cy = (band.cbY0 + j) << band.ycb
                            band.blocks.append(CodeBlock(max(cx, band.x0), max(cy, band.y0), min(cx + (1 << band.xcb), band.x1), min(cy + (1 << band.ycb), band.y1)))
                        }
                    }
                }
                res.bands.append(band)
            }
            // Precincts -> code-block ranges per band
            let pcount = res.precW * res.precH
            res.precincts = [[PrecinctBand?]](repeating: [], count: pcount)
            for k in 0..<pcount {
                let px = res.precX0 + k % max(1, res.precW), py = res.precY0 + k / max(1, res.precW)
                var list: [PrecinctBand?] = []
                for band in res.bands {
                    guard band.width > 0, band.height > 0 else { list.append(nil); continue }
                    let sx = r == 0 ? res.ppx : res.ppx - 1, sy = r == 0 ? res.ppy : res.ppy - 1
                    let pbx0 = max(px << sx, band.x0), pby0 = max(py << sy, band.y0)
                    let pbx1 = min((px + 1) << sx, band.x1), pby1 = min((py + 1) << sy, band.y1)
                    guard pbx1 > pbx0, pby1 > pby0 else { list.append(nil); continue }
                    let c0 = pbx0 >> band.xcb, c1 = (pbx1 + (1 << band.xcb) - 1) >> band.xcb
                    let r0 = pby0 >> band.ycb, r1 = (pby1 + (1 << band.ycb) - 1) >> band.ycb
                    list.append(PrecinctBand(cbx0: c0, cby0: r0, w: c1 - c0, h: r1 - r0))
                }
                res.precincts[k] = list
            }
            tc.resolutions.append(res)
        }
    }

    // MARK: - Progression

    private func packetOrder(_ tcs: [TileComponent], tileCod: CodingStyle, pocs: [ProgressionChange], tx0: Int, ty0: Int) -> [(Int, Int, Int, Int)] {
        let layers = tileCod.layers
        struct P { let l: Int, r: Int, c: Int, k: Int, py: Int, px: Int, ry: Int, rx: Int }
        var all: [P] = []
        for tc in tcs {
            let cs = comps[tc.c]
            let nl = tc.style.levels
            for res in tc.resolutions {
                for k in 0..<(res.precW * res.precH) {
                    let px = k % res.precW, py = k / res.precW
                    let rx = max(res.x0, (res.precX0 + px) << res.ppx) << (nl - res.r) * cs.dx
                    let ry = max(res.y0, (res.precY0 + py) << res.ppy) << (nl - res.r) * cs.dy
                    for l in 0..<layers { all.append(P(l: l, r: res.r, c: tc.c, k: k, py: py, px: px, ry: ry, rx: rx)) }
                }
            }
        }
        func sorted(_ list: [P], _ order: Int) -> [P] {
            switch order {
            case 1: return list.sorted { ($0.r, $0.l, $0.c, $0.py, $0.px) < ($1.r, $1.l, $1.c, $1.py, $1.px) }
            case 2: return list.sorted { ($0.r, $0.ry, $0.rx, $0.c, $0.l) < ($1.r, $1.ry, $1.rx, $1.c, $1.l) }
            case 3: return list.sorted { ($0.ry, $0.rx, $0.c, $0.r, $0.l) < ($1.ry, $1.rx, $1.c, $1.r, $1.l) }
            case 4: return list.sorted { ($0.c, $0.ry, $0.rx, $0.r, $0.l) < ($1.c, $1.ry, $1.rx, $1.r, $1.l) }
            default: return list.sorted { ($0.l, $0.r, $0.c, $0.py, $0.px) < ($1.l, $1.r, $1.c, $1.py, $1.px) }
            }
        }
        if pocs.isEmpty { return sorted(all, tileCod.progression).map { ($0.l, $0.r, $0.c, $0.k) } }
        var out: [(Int, Int, Int, Int)] = []
        var done = Set<Int>()
        func key(_ p: P) -> Int { ((p.l * 64 + p.r) * 16384 + p.c) * 65536 + p.k }
        for poc in pocs {
            let sub = all.filter { $0.r >= poc.rs && $0.r < poc.re && $0.c >= poc.cs && $0.c < poc.ce && $0.l < poc.lye && !done.contains(key($0)) }
            for p in sorted(sub, poc.order) where done.insert(key(p)).inserted { out.append((p.l, p.r, p.c, p.k)) }
        }
        for p in sorted(all, tileCod.progression) where !done.contains(key(p)) { out.append((p.l, p.r, p.c, p.k)) }
        return out
    }

    // MARK: - Inverse wavelet transform

    private func inverseDWT(_ tc: TileComponent) {
        let reversible = tc.style.reversible
        guard let r0 = tc.resolutions.first, let ll = r0.bands.first else { return }
        var cur: [Float] = reversible ? ll.coefficients.map(Float.init) : ll.floats
        var cw = r0.x1 - r0.x0, ch = r0.y1 - r0.y0
        let last = max(0, tc.resolutions.count - 1 - reduce)
        let lr = tc.resolutions[last]
        tc.outX0 = lr.x0; tc.outY0 = lr.y0; tc.outX1 = lr.x1; tc.outY1 = lr.y1
        if last == 0 { tc.output = cur; return }
        for r in 1...last {
            let res = tc.resolutions[r]
            let u0 = res.x0, u1 = res.x1, v0 = res.y0, v1 = res.y1
            let w = u1 - u0, h = v1 - v0
            guard w > 0, h > 0 else { cur = []; cw = 0; ch = 0; continue }
            var a = [Float](repeating: 0, count: w * h)
            let hl = res.bands[0], lh = res.bands[1], hh = res.bands[2]
            let lx0 = ceilDiv(u0, 2), ly0 = ceilDiv(v0, 2), hx0 = u0 >> 1, hy0 = v0 >> 1
            func val(_ b: Band, _ x: Int, _ y: Int) -> Float {
                let i = (y - b.y0) * b.width + (x - b.x0)
                if reversible { return i >= 0 && i < b.coefficients.count ? Float(b.coefficients[i]) : 0 }
                return i >= 0 && i < b.floats.count ? b.floats[i] : 0
            }
            for v in v0..<v1 {
                for u in u0..<u1 {
                    let o = (v - v0) * w + (u - u0)
                    let ue = u & 1 == 0, ve = v & 1 == 0
                    if ue && ve {
                        let x = (u >> 1) - lx0, y = (v >> 1) - ly0
                        a[o] = x < cw && y < ch && x >= 0 && y >= 0 ? cur[y * cw + x] : 0
                    } else if !ue && ve {
                        a[o] = val(hl, (u >> 1), (v >> 1))
                    } else if ue && !ve {
                        a[o] = val(lh, (u >> 1), (v >> 1))
                    } else {
                        a[o] = val(hh, (u >> 1), (v >> 1))
                    }
                }
            }
            _ = hx0; _ = hy0
            // Horizontal then vertical synthesis
            var line = [Float](repeating: 0, count: max(w, h))
            for y in 0..<h {
                for x in 0..<w { line[x] = a[y * w + x] }
                JPEG2000Decoder.synthesize(&line, count: w, start: u0, reversible: reversible)
                for x in 0..<w { a[y * w + x] = line[x] }
            }
            for x in 0..<w {
                for y in 0..<h { line[y] = a[y * w + x] }
                JPEG2000Decoder.synthesize(&line, count: h, start: v0, reversible: reversible)
                for y in 0..<h { a[y * w + x] = line[y] }
            }
            cur = a; cw = w; ch = h
        }
        tc.output = cur
    }

    /// 1D synthesis with symmetric extension. Even absolute positions hold low-pass samples.
    static func synthesize(_ x: inout [Float], count n: Int, start s: Int, reversible: Bool) {
        if n <= 0 { return }
        if n == 1 {
            if s & 1 == 1 && reversible { x[0] = (x[0] / 2).rounded(.towardZero) }
            return
        }
        let pad = 4
        var b = [Float](repeating: 0, count: n + 2 * pad)
        for i in 0..<n { b[pad + i] = x[i] }
        for k in 1...pad {
            b[pad - k] = b[pad + reflect(k, n)]
            b[pad + n - 1 + k] = b[pad + reflect(n - 1 + k, n)]
        }
        let even = s & 1   // index i is low-pass when (s + i) is even
        @inline(__always) func isLow(_ i: Int) -> Bool { ((s + i) & 1) == 0 }
        _ = even
        if reversible {
            // step 1: low samples
            var i = -1
            while i <= n {
                if isLow(i) { b[pad + i] -= ((b[pad + i - 1] + b[pad + i + 1] + 2) / 4).rounded(.down) }
                i += 1
            }
            i = 0
            while i < n {
                if !isLow(i) { b[pad + i] += ((b[pad + i - 1] + b[pad + i + 1]) / 2).rounded(.down) }
                i += 1
            }
        } else {
            let alpha: Float = -1.586134342059924, beta: Float = -0.052980118572961
            let gamma: Float = 0.882911075530934, delta: Float = 0.443506852043971
            let K: Float = 1.230174104914001
            for i in -pad..<(n + pad) { if isLow(i) { b[pad + i] *= K } else { b[pad + i] *= 1 / K } }
            for i in -3..<(n + 3) where isLow(i) { b[pad + i] -= delta * (b[pad + i - 1] + b[pad + i + 1]) }
            for i in -2..<(n + 2) where !isLow(i) { b[pad + i] -= gamma * (b[pad + i - 1] + b[pad + i + 1]) }
            for i in -1..<(n + 1) where isLow(i) { b[pad + i] -= beta * (b[pad + i - 1] + b[pad + i + 1]) }
            for i in 0..<n where !isLow(i) { b[pad + i] -= alpha * (b[pad + i - 1] + b[pad + i + 1]) }
        }
        for i in 0..<n { x[i] = b[pad + i] }
    }

    /// Whole-sample symmetric reflection of index i into 0..<n.
    @inline(__always) static func reflect(_ i: Int, _ n: Int) -> Int {
        if n == 1 { return 0 }
        let period = 2 * (n - 1)
        var k = i % period
        if k < 0 { k += period }
        return k < n ? k : period - k
    }
}

@inline(__always) func ceilDiv(_ a: Int, _ b: Int) -> Int {
    b == 0 ? 0 : (a >= 0 ? (a + b - 1) / b : -((-a) / b))
}

@inline(__always) func floorLog2(_ v: Int) -> Int {
    v <= 1 ? 0 : (Int.bitWidth - 1 - v.leadingZeroBitCount)
}

extension Data {
    @inline(__always) func u16be(_ p: Int) -> UInt16 {
        guard p + 1 < count else { return 0 }
        return UInt16(self[startIndex + p]) << 8 | UInt16(self[startIndex + p + 1])
    }

    @inline(__always) func u32be(_ p: Int) -> UInt32 {
        guard p + 3 < count else { return 0 }
        return UInt32(self[startIndex + p]) << 24 | UInt32(self[startIndex + p + 1]) << 16 | UInt32(self[startIndex + p + 2]) << 8 | UInt32(self[startIndex + p + 3])
    }

    @inline(__always) func u64be(_ p: Int) -> UInt64 { UInt64(u32be(p)) << 32 | UInt64(u32be(p + 4)) }
}

// MARK: - Tier-1 (EBCOT) code-block decoder

final class CodeBlockDecoder {
    let w: Int, h: Int
    let orientation: Int
    let style: Int
    private let W: Int       // padded width
    private var flags: [UInt8]
    private var mag: [Int32]
    private var low: [Int8]
    private var contexts = [UInt8](repeating: 0, count: 19)
    private(set) var lastBitplane = 0

    static let SIG: UInt8 = 1, VISIT: UInt8 = 2, REFINED: UInt8 = 4, NEG: UInt8 = 8

    init(width: Int, height: Int, orientation: Int, style: Int) {
        w = width; h = height
        self.orientation = orientation
        self.style = style
        W = width + 2
        flags = [UInt8](repeating: 0, count: (width + 2) * (height + 2))
        mag = [Int32](repeating: 0, count: (width + 2) * (height + 2))
        low = [Int8](repeating: 0, count: (width + 2) * (height + 2))
        resetContexts()
    }

    private func resetContexts() {
        for i in 0..<19 { contexts[i] = 0 }
        contexts[0] = 4 << 1
        contexts[17] = 3 << 1
        contexts[18] = 46 << 1
    }

    @inline(__always) func magnitude(_ x: Int, _ y: Int) -> Int32 { mag[(y + 1) * W + x + 1] }

    /// Mid-point reconstruction: half of the lowest decoded bit is added to significant coefficients
    /// (as reference decoders do), so streams whose encoder dropped zero-distortion passes stay exact.
    @inline(__always) func reconstructedInt(_ x: Int, _ y: Int) -> Int32 {
        let i = (y + 1) * W + x + 1
        let m = mag[i]
        if m == 0 { return 0 }
        let l = Int32(low[i])
        return l > 0 ? m + (1 << (l - 1)) : m
    }

    @inline(__always) func reconstructedFloat(_ x: Int, _ y: Int) -> Float {
        let i = (y + 1) * W + x + 1
        let m = mag[i]
        if m == 0 { return 0 }
        return Float(m) + Float(Int32(1) << Int32(low[i])) * 0.5
    }
    @inline(__always) func isNegative(_ x: Int, _ y: Int) -> Bool { flags[(y + 1) * W + x + 1] & CodeBlockDecoder.NEG != 0 }

    // ZC lookup [orientation][h*15 + v*5 + d]
    static let zcTable: [[UInt8]] = {
        func llLH(_ h: Int, _ v: Int, _ d: Int) -> UInt8 {
            if h == 2 { return 8 }
            if h == 1 { return v >= 1 ? 7 : (d >= 1 ? 6 : 5) }
            if v == 2 { return 4 }
            if v == 1 { return 3 }
            return d >= 2 ? 2 : (d == 1 ? 1 : 0)
        }
        func hh(_ h: Int, _ v: Int, _ d: Int) -> UInt8 {
            let hv = h + v
            if d >= 3 { return 8 }
            if d == 2 { return hv >= 1 ? 7 : 6 }
            if d == 1 { return hv >= 2 ? 5 : (hv == 1 ? 4 : 3) }
            return hv >= 2 ? 2 : (hv == 1 ? 1 : 0)
        }
        var t = [[UInt8]](repeating: [UInt8](repeating: 0, count: 45), count: 4)
        for hc in 0...2 { for vc in 0...2 { for dc in 0...4 {
            let i = hc * 15 + vc * 5 + dc
            t[0][i] = llLH(hc, vc, dc)
            t[2][i] = llLH(hc, vc, dc)
            t[1][i] = llLH(vc, hc, dc)
            t[3][i] = hh(hc, vc, dc)
        } } }
        return t
    }()

    // MARK: MQ decoder

    private struct MQ {
        var data: [UInt8]
        var bp = 0
        var end: Int
        var a: UInt32 = 0
        var chigh: UInt32 = 0
        var clow: UInt32 = 0
        var ct = 0

        init(_ bytes: [UInt8]) {
            data = bytes + [0xFF, 0xFF]
            end = bytes.count
            bp = 0
            chigh = UInt32(data[0])
            clow = 0
            byteIn()
            chigh = ((chigh << 7) & 0xFFFF) | ((clow >> 9) & 0x7F)
            clow = (clow << 7) & 0xFFFF
            ct -= 7
            a = 0x8000
        }

        @inline(__always) mutating func byteIn() {
            if data[bp] == 0xFF {
                if data[bp + 1] > 0x8F {
                    clow += 0xFF00
                    ct = 8
                } else {
                    bp += 1
                    clow += UInt32(data[bp]) << 9
                    ct = 7
                }
            } else {
                bp += 1
                clow += bp < end ? UInt32(data[bp]) << 8 : 0xFF00
                ct = 8
            }
            if clow > 0xFFFF {
                chigh += clow >> 16
                clow &= 0xFFFF
            }
        }

        @inline(__always) mutating func decode(_ cx: inout UInt8) -> Int {
            var index = Int(cx >> 1)
            var mps = Int(cx & 1)
            let qe = MQ.qe[index]
            var d: Int
            var aa = a &- qe
            if chigh < qe {
                if aa < qe {
                    aa = qe
                    d = mps
                    index = MQ.nmps[index]
                } else {
                    aa = qe
                    d = 1 ^ mps
                    if MQ.sw[index] == 1 { mps = d }
                    index = MQ.nlps[index]
                }
            } else {
                chigh -= qe
                if aa & 0x8000 != 0 {
                    a = aa
                    return mps
                }
                if aa < qe {
                    d = 1 ^ mps
                    if MQ.sw[index] == 1 { mps = d }
                    index = MQ.nlps[index]
                } else {
                    d = mps
                    index = MQ.nmps[index]
                }
            }
            repeat {
                if ct == 0 { byteIn() }
                aa <<= 1
                chigh = ((chigh << 1) & 0xFFFF) | ((clow >> 15) & 1)
                clow = (clow << 1) & 0xFFFF
                ct -= 1
            } while aa & 0x8000 == 0
            a = aa
            cx = UInt8(index << 1 | mps)
            return d
        }

        static let qe: [UInt32] = [0x5601, 0x3401, 0x1801, 0x0AC1, 0x0521, 0x0221, 0x5601, 0x5401, 0x4801, 0x3801, 0x3001, 0x2401, 0x1C01, 0x1601,
                                   0x5601, 0x5401, 0x5101, 0x4801, 0x3801, 0x3401, 0x3001, 0x2801, 0x2401, 0x2201, 0x1C01, 0x1801, 0x1601, 0x1401,
                                   0x1201, 0x1101, 0x0AC1, 0x09C1, 0x08A1, 0x0521, 0x0441, 0x02A1, 0x0221, 0x0141, 0x0111, 0x0085, 0x0049, 0x0025,
                                   0x0015, 0x0009, 0x0005, 0x0001, 0x5601]
        static let nmps: [Int] = [1, 2, 3, 4, 5, 38, 7, 8, 9, 10, 11, 12, 13, 29, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
                                  33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 45, 46]
        static let nlps: [Int] = [1, 6, 9, 12, 29, 33, 6, 14, 14, 14, 17, 18, 20, 21, 14, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
                                  29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 46]
        static let sw: [Int] = [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                0, 0, 0, 0, 0, 0]
    }

    /// Raw (bypass) bit reader with 0xFF stuffing.
    private struct Raw {
        var data: [UInt8]
        var pos = 0
        var cur: UInt8 = 0
        var ct = 0
        init(_ bytes: [UInt8]) { data = bytes }
        @inline(__always) mutating func bit() -> Int {
            if ct == 0 {
                if cur == 0xFF {
                    let b: UInt8 = pos < data.count ? data[pos] : 0xFF
                    if b > 0x8F { cur = 0xFF; ct = 8 } else { cur = b; pos += 1; ct = 7 }
                } else {
                    cur = pos < data.count ? data[pos] : 0xFF
                    pos += 1
                    ct = 8
                }
            }
            ct -= 1
            return Int(cur >> UInt8(ct)) & 1
        }
    }

    private enum Source { case mq(MQ), raw(Raw) }

    // MARK: Context helpers

    @inline(__always) private func neighbourCounts(_ i: Int, _ y: Int) -> (Int, Int, Int) {
        let f = flags
        let S = CodeBlockDecoder.SIG
        let causal = (style & 0x08) != 0 && (y & 3) == 3
        let hc = Int(f[i - 1] & S) + Int(f[i + 1] & S)
        var vc = Int(f[i - W] & S)
        var dc = Int(f[i - W - 1] & S) + Int(f[i - W + 1] & S)
        if !causal {
            vc += Int(f[i + W] & S)
            dc += Int(f[i + W - 1] & S) + Int(f[i + W + 1] & S)
        }
        return (hc, vc, dc)
    }

    @inline(__always) private func zc(_ i: Int, _ y: Int) -> Int {
        let (hc, vc, dc) = neighbourCounts(i, y)
        return Int(CodeBlockDecoder.zcTable[orientation][hc * 15 + vc * 5 + dc])
    }

    @inline(__always) private func signContext(_ i: Int, _ y: Int) -> (Int, Int) {
        let S = CodeBlockDecoder.SIG, N = CodeBlockDecoder.NEG
        func contrib(_ j: Int) -> Int { flags[j] & S == 0 ? 0 : (flags[j] & N != 0 ? -1 : 1) }
        let causal = (style & 0x08) != 0 && (y & 3) == 3
        var hcon = contrib(i - 1) + contrib(i + 1)
        var vcon = contrib(i - W) + (causal ? 0 : contrib(i + W))
        hcon = max(-1, min(1, hcon)); vcon = max(-1, min(1, vcon))
        switch (hcon, vcon) {
        case (1, 1): return (13, 0)
        case (1, 0): return (12, 0)
        case (1, -1): return (11, 0)
        case (0, 1): return (10, 0)
        case (0, 0): return (9, 0)
        case (0, -1): return (10, 1)
        case (-1, 1): return (11, 1)
        case (-1, 0): return (12, 1)
        default: return (13, 1)
        }
    }

    // MARK: Decoding

    func decode(segments: [JPEG2000Decoder.Segment], bitplanes: Int, passes: Int) {
        var passIndex = 0
        var bp = bitplanes - 1
        var passType = 2    // 0 SPP, 1 MRP, 2 cleanup (first pass is cleanup)
        let bypass = style & 0x01 != 0
        let reset = style & 0x02 != 0
        let segmark = style & 0x20 != 0
        for seg in segments {
            guard seg.passes > 0 else { continue }
            let bytes = [UInt8](seg.data)
            // A segment is raw when, in bypass mode, its first pass is SPP/MRP beyond the 10th pass
            let isRaw = bypass && passIndex >= 10 && passType != 2
            var src: Source = isRaw ? .raw(Raw(bytes)) : .mq(MQ(bytes))
            for _ in 0..<seg.passes {
                if bp < 0 || passIndex >= passes { break }
                switch passType {
                case 0: significancePass(&src, bp)
                case 1: refinementPass(&src, bp)
                default: cleanupPass(&src, bp, segmark: segmark)
                }
                lastBitplane = bp
                if reset { resetContexts() }
                passIndex += 1
                if passType == 2 { passType = 0; bp -= 1 } else { passType += 1 }
            }
        }
    }

    @inline(__always) private func decodeBit(_ src: inout Source, _ ctx: Int) -> Int {
        switch src {
        case .mq(var m):
            let b = m.decode(&contexts[ctx])
            src = .mq(m)
            return b
        case .raw(var r):
            let b = r.bit()
            src = .raw(r)
            return b
        }
    }

    private func becomeSignificant(_ src: inout Source, _ i: Int, _ y: Int, _ one: Int32) {
        var neg: Int
        if case .raw = src {
            neg = decodeBit(&src, 0)
        } else {
            let (ctx, xr) = signContext(i, y)
            neg = decodeBit(&src, ctx) ^ xr
        }
        flags[i] |= CodeBlockDecoder.SIG | (neg != 0 ? CodeBlockDecoder.NEG : 0)
        mag[i] = one
        low[i] = Int8(one.trailingZeroBitCount)
    }

    private func significancePass(_ src: inout Source, _ bp: Int) {
        let one = Int32(1) << Int32(bp)
        let S = CodeBlockDecoder.SIG, V = CodeBlockDecoder.VISIT
        var y0 = 0
        while y0 < h {
            for x in 0..<w {
                for y in y0..<min(y0 + 4, h) {
                    let i = (y + 1) * W + x + 1
                    if flags[i] & S != 0 { continue }
                    let ctx = zc(i, y)
                    if ctx == 0 { continue }
                    flags[i] |= V
                    if decodeBit(&src, ctx) != 0 { becomeSignificant(&src, i, y, one) }
                }
            }
            y0 += 4
        }
    }

    private func refinementPass(_ src: inout Source, _ bp: Int) {
        let one = Int32(1) << Int32(bp)
        let S = CodeBlockDecoder.SIG, V = CodeBlockDecoder.VISIT, R = CodeBlockDecoder.REFINED
        var y0 = 0
        while y0 < h {
            for x in 0..<w {
                for y in y0..<min(y0 + 4, h) {
                    let i = (y + 1) * W + x + 1
                    let f = flags[i]
                    guard f & S != 0, f & V == 0 else { continue }
                    var ctx = 16
                    if f & R == 0 {
                        let (hc, vc, dc) = neighbourCounts(i, y)
                        ctx = hc + vc + dc > 0 ? 15 : 14
                    }
                    if decodeBit(&src, ctx) != 0 { mag[i] |= one }
                    low[i] = Int8(bp)
                    flags[i] |= R
                }
            }
            y0 += 4
        }
    }

    private func cleanupPass(_ src: inout Source, _ bp: Int, segmark: Bool) {
        let one = Int32(1) << Int32(bp)
        let S = CodeBlockDecoder.SIG, V = CodeBlockDecoder.VISIT
        var y0 = 0
        while y0 < h {
            for x in 0..<w {
                var start = y0
                if y0 + 3 < h {
                    var runMode = true
                    for y in y0..<(y0 + 4) {
                        let i = (y + 1) * W + x + 1
                        if flags[i] & (S | V) != 0 || zc(i, y) != 0 { runMode = false; break }
                    }
                    if runMode {
                        if decodeBit(&src, 17) == 0 { continue }
                        let r = (decodeBit(&src, 18) << 1) | decodeBit(&src, 18)
                        let y = y0 + r
                        let i = (y + 1) * W + x + 1
                        becomeSignificant(&src, i, y, one)
                        start = y + 1
                    }
                }
                if start < min(y0 + 4, h) {
                    for y in start..<min(y0 + 4, h) {
                        let i = (y + 1) * W + x + 1
                        if flags[i] & (S | V) != 0 { continue }
                        if decodeBit(&src, zc(i, y)) != 0 { becomeSignificant(&src, i, y, one) }
                    }
                }
            }
            y0 += 4
        }
        // clear visited flags
        for i in 0..<flags.count { flags[i] &= ~V }
        if segmark {
            for _ in 0..<4 { _ = decodeBit(&src, 18) }
        }
    }
}
