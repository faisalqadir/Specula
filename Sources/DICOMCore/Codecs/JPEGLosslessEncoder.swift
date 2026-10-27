import Foundation

/// Minimal JPEG lossless (process 14, selection value 1..7) encoder for single-component images.
public enum JPEGLosslessEncoder {
    public static func encode(samples: [UInt16], width: Int, height: Int, precision: Int, predictor: Int = 1, restartInterval: Int = 0) -> Data {
        let mask = (1 << 16) - 1
        // Compute differences and category histogram
        var cats = [Int](repeating: 0, count: 17)
        var diffs = [Int](repeating: 0, count: width * height)
        let initial = 1 << (precision - 1)
        var mcu = 0
        var restartRow = -1
        for y in 0..<height {
            for x in 0..<width {
                if restartInterval > 0 && mcu % restartInterval == 0 && mcu > 0 && x == 0 { restartRow = y }
                let i = y * width + x
                let pred: Int
                let top = y == 0 || y == restartRow
                if top && x == 0 { pred = initial }
                else if top { pred = Int(samples[i - 1]) }
                else if x == 0 { pred = Int(samples[i - width]) }
                else {
                    let ra = Int(samples[i - 1]), rb = Int(samples[i - width]), rc = Int(samples[i - width - 1])
                    switch predictor {
                    case 2: pred = rb
                    case 3: pred = rc
                    case 4: pred = ra + rb - rc
                    case 5: pred = ra + ((rb - rc) >> 1)
                    case 6: pred = rb + ((ra - rc) >> 1)
                    case 7: pred = (ra + rb) >> 1
                    default: pred = ra
                    }
                }
                var d = (Int(samples[i]) - pred) & mask
                if d >= 32768 { d -= 65536 }
                diffs[i] = d
                cats[category(d)] += 1
                mcu += 1
            }
        }
        let (codes, lengths, bits, vals) = huffman(cats)
        var out = Data([0xFF, 0xD8])
        // SOF3
        out.append(contentsOf: [0xFF, 0xC3, 0, 11, UInt8(precision), UInt8(height >> 8), UInt8(height & 255), UInt8(width >> 8), UInt8(width & 255), 1, 1, 0x11, 0])
        // DHT
        var dht: [UInt8] = [0x00]
        dht += bits
        dht += vals
        out.append(contentsOf: [0xFF, 0xC4, UInt8((dht.count + 2) >> 8), UInt8((dht.count + 2) & 255)])
        out.append(contentsOf: dht)
        if restartInterval > 0 {
            out.append(contentsOf: [0xFF, 0xDD, 0, 4, UInt8(restartInterval >> 8), UInt8(restartInterval & 255)])
        }
        // SOS
        out.append(contentsOf: [0xFF, 0xDA, 0, 8, 1, 1, 0x00, UInt8(predictor), 0, 0])
        var acc: UInt64 = 0
        var nbits = 0
        func put(_ v: Int, _ n: Int) {
            guard n > 0 else { return }
            acc = (acc << UInt64(n)) | UInt64(v & ((1 << n) - 1))
            nbits += n
            while nbits >= 8 {
                let b = UInt8((acc >> UInt64(nbits - 8)) & 0xFF)
                out.append(b)
                if b == 0xFF { out.append(0) }
                nbits -= 8
            }
        }
        func flushBits() {
            if nbits > 0 { put((1 << (8 - nbits)) - 1, 8 - nbits) }
            acc = 0
        }
        var rst = 0
        for i in 0..<diffs.count {
            if restartInterval > 0 && i > 0 && i % restartInterval == 0 {
                flushBits()
                out.append(contentsOf: [0xFF, UInt8(0xD0 + (rst & 7))])
                rst += 1
            }
            let d = diffs[i]
            let c = category(d)
            put(codes[c], lengths[c])
            if c > 0 && c < 16 {
                put(d < 0 ? d + (1 << c) - 1 : d, c)
            }
        }
        flushBits()
        out.append(contentsOf: [0xFF, 0xD9])
        return out
    }

    static func category(_ d: Int) -> Int {
        if d == 0 { return 0 }
        if d == -32768 { return 16 }
        var a = abs(d), c = 0
        while a > 0 { a >>= 1; c += 1 }
        return c
    }

    /// Builds a length-limited Huffman code (max 16 bits) from category frequencies.
    static func huffman(_ freq: [Int]) -> (codes: [Int], lengths: [Int], bits: [UInt8], vals: [UInt8]) {
        var symbols = (0..<17).filter { freq[$0] > 0 }
        if symbols.isEmpty { symbols = [0] }
        if symbols.count == 1 { symbols.append(symbols[0] == 0 ? 1 : 0) }
        // Package-merge free approach: compute lengths via sorting & simple heuristic (Kraft-limited)
        var nodes: [(w: Int, syms: [Int])] = symbols.map { (max(1, freq[$0]), [$0]) }
        var depth = [Int](repeating: 0, count: 17)
        while nodes.count > 1 {
            nodes.sort { $0.w < $1.w }
            let a = nodes.removeFirst(), b = nodes.removeFirst()
            for s in a.syms + b.syms { depth[s] += 1 }
            nodes.append((a.w + b.w, a.syms + b.syms))
        }
        // Limit to 15 bits (reserve all-ones code)
        for s in symbols where depth[s] > 15 { depth[s] = 15 }
        // Fix Kraft inequality if violated
        func kraft() -> Double { symbols.reduce(0) { $0 + pow(2.0, -Double(depth[$1])) } }
        while kraft() > 1.0 - pow(2.0, -15) {
            if let s = symbols.filter({ depth[$0] < 15 }).max(by: { depth[$0] < depth[$1] }) { depth[s] += 1 } else { break }
        }
        let ordered = symbols.sorted { depth[$0] != depth[$1] ? depth[$0] < depth[$1] : $0 < $1 }
        var bits = [UInt8](repeating: 0, count: 16)
        for s in ordered { bits[depth[s] - 1] += 1 }
        var codes = [Int](repeating: 0, count: 17), lengths = [Int](repeating: 0, count: 17)
        var code = 0
        var k = 0
        for len in 1...16 {
            for _ in 0..<Int(bits[len - 1]) {
                let s = ordered[k]
                codes[s] = code
                lengths[s] = len
                code += 1
                k += 1
            }
            code <<= 1
        }
        return (codes, lengths, bits, ordered.map { UInt8($0) })
    }
}
