import Foundation
import Compression

public enum DICOMError: Error, LocalizedError {
    case notDICOM
    case truncated
    case unsupported(String)
    case decode(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notDICOM: return "Not a DICOM file"
        case .truncated: return "The file is truncated"
        case .unsupported(let s): return "Unsupported: \(s)"
        case .decode(let s): return "Decoding failed: \(s)"
        case .io(let s): return s
        }
    }
}

public struct ParseOptions: Sendable {
    /// Stop before Pixel Data (fast header scan).
    public var headerOnly = false
    public init(headerOnly: Bool = false) { self.headerOnly = headerOnly }
    public static let full = ParseOptions()
    public static let header = ParseOptions(headerOnly: true)
}

/// A parsed DICOM Part 10 file (or raw data set).
public final class DICOMFile: @unchecked Sendable {
    public let url: URL?
    public let fileMeta: DataSet
    public let dataSet: DataSet
    public let transferSyntax: TransferSyntax
    public let hasPreamble: Bool
    public let byteCount: Int

    init(url: URL?, fileMeta: DataSet, dataSet: DataSet, transferSyntax: TransferSyntax, hasPreamble: Bool, byteCount: Int) {
        self.url = url
        self.fileMeta = fileMeta
        self.dataSet = dataSet
        self.transferSyntax = transferSyntax
        self.hasPreamble = hasPreamble
        self.byteCount = byteCount
    }

    public static func read(url: URL, options: ParseOptions = .full) throws -> DICOMFile {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.alwaysMapped])
        } catch {
            throw DICOMError.io(error.localizedDescription)
        }
        return try parse(data, url: url, options: options)
    }

    /// Quick check for the DICM magic or a plausible raw data set start.
    public static func looksLikeDICOM(url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 132), head.count >= 8 else { return false }
        if head.count >= 132, head[head.startIndex + 128] == 0x44, head[head.startIndex + 129] == 0x49,
           head[head.startIndex + 130] == 0x43, head[head.startIndex + 131] == 0x4D { return true }
        return rawDataSetGuess(head) != nil
    }

    /// Returns (explicit, bigEndian) if the bytes look like the start of a raw data set.
    static func rawDataSetGuess(_ d: Data) -> (Bool, Bool)? {
        guard d.count >= 8 else { return nil }
        let b = [UInt8](d.prefix(8))
        let gLE = UInt16(b[0]) | UInt16(b[1]) << 8
        let gBE = UInt16(b[1]) | UInt16(b[0]) << 8
        let explicit = VR(bytes: b[4], b[5]) != nil
        if gLE == 0x0002 || gLE == 0x0008 || gLE == 0x0010 || gLE == 0x0018 || gLE == 0x0020 || gLE == 0x0028 { return (explicit, false) }
        if gBE == 0x0008 || gBE == 0x0010 { return (explicit, true) }
        return nil
    }

    public static func parse(_ data: Data, url: URL? = nil, options: ParseOptions = .full) throws -> DICOMFile {
        guard data.count >= 8 else { throw DICOMError.notDICOM }
        var hasPreamble = false
        var start = 0
        let magic = data.count >= 132 ? data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 128, as: UInt32.self) } : 0
        if magic == 0x4D43_4944 { // "DICM"
            hasPreamble = true
            start = 132
        } else if data.count >= 4, data.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }) == 0x4D43_4944 {
            start = 4 // "DICM" without preamble
        } else if rawDataSetGuess(data) == nil {
            throw DICOMError.notDICOM
        }

        // File meta information (always explicit VR little endian)
        let meta: DataSet
        var pos = start
        var p = ElementParser(data: data, explicit: true, bigEndian: false)
        meta = p.parseMeta(from: &pos)

        var ts: TransferSyntax
        if let uid = meta.string(.transferSyntaxUID) {
            ts = TransferSyntax.resolve(uid)
        } else {
            let rest = data.subdata(in: data.startIndex + pos ..< data.startIndex + min(data.count, pos + 8))
            if let (explicit, be) = rawDataSetGuess(rest) {
                ts = be ? .explicitVRBigEndian : (explicit ? .explicitVRLittleEndian : .implicitVRLittleEndian)
            } else {
                ts = .implicitVRLittleEndian
            }
        }

        var body = data
        var bodyStart = pos
        if ts.deflated {
            let compressed = data.subdata(in: data.startIndex + pos ..< data.endIndex)
            guard let inflated = Inflate.raw(compressed) ?? Inflate.zlib(compressed) else { throw DICOMError.decode("deflate") }
            body = inflated
            bodyStart = 0
        }

        // Some files declare an explicit syntax but are implicit (or vice versa): sniff the first element.
        var explicit = ts.explicitVR
        if body.count >= bodyStart + 8 {
            let b4 = body[body.startIndex + bodyStart + 4], b5 = body[body.startIndex + bodyStart + 5]
            let looksExplicit = VR(bytes: b4, b5) != nil
            if !ts.bigEndian && looksExplicit != explicit {
                // Only override when the declared encoding would yield an implausible first length
                explicit = looksExplicit
            }
        }

        var bp = ElementParser(data: body, explicit: explicit, bigEndian: ts.bigEndian)
        bp.headerOnly = options.headerOnly
        var bpos = bodyStart
        let ds = bp.parseDataSet(pos: &bpos, end: body.count, untilItemDelimiter: false, depth: 0)
        ds.bigEndian = ts.bigEndian
        if bp.truncated && ds.isEmpty { throw DICOMError.truncated }
        return DICOMFile(url: url, fileMeta: meta, dataSet: ds, transferSyntax: ts, hasPreamble: hasPreamble, byteCount: data.count)
    }

    /// Parses a bare data set (e.g. received over the network) in the given transfer syntax.
    public static func parseDataSet(_ data: Data, transferSyntax ts: TransferSyntax) throws -> DataSet {
        var body = data
        if ts.deflated {
            guard let inflated = Inflate.raw(data) else { throw DICOMError.decode("deflate") }
            body = inflated
        }
        var bp = ElementParser(data: body, explicit: ts.explicitVR, bigEndian: ts.bigEndian)
        var pos = 0
        let ds = bp.parseDataSet(pos: &pos, end: body.count, untilItemDelimiter: false, depth: 0)
        ds.bigEndian = ts.bigEndian
        return ds
    }
}

/// Low-level element parser.
struct ElementParser {
    let data: Data
    var explicit: Bool
    var bigEndian: Bool
    var headerOnly = false
    var truncated = false

    init(data: Data, explicit: Bool, bigEndian: Bool) {
        self.data = data
        self.explicit = explicit
        self.bigEndian = bigEndian
    }

    @inline(__always) func u16(_ pos: Int, _ be: Bool) -> UInt16 {
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt16.self) }
        return be ? v.byteSwapped : v
    }

    @inline(__always) func u32(_ pos: Int, _ be: Bool) -> UInt32 {
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt32.self) }
        return be ? v.byteSwapped : v
    }

    @inline(__always) func byte(_ pos: Int) -> UInt8 { data[data.startIndex + pos] }

    /// Value bytes; small values are rebased copies, large ones share the source buffer.
    func slice(_ pos: Int, _ len: Int) -> Data {
        let a = data.startIndex + pos, b = data.startIndex + pos + len
        if len > 1 << 20 { return data[a..<b] }
        return Data(data[a..<b])
    }

    mutating func parseMeta(from pos: inout Int) -> DataSet {
        let ds = DataSet(bigEndian: false)
        while pos + 8 <= data.count {
            let group = u16(pos, false)
            if group != 0x0002 { break }
            let save = pos
            guard let e = readElement(pos: &pos, end: data.count, explicitVR: true, be: false, depth: 0) else { pos = save; break }
            ds.insert(e)
        }
        return ds
    }

    mutating func parseDataSet(pos: inout Int, end: Int, untilItemDelimiter: Bool, depth: Int) -> DataSet {
        let ds = DataSet(bigEndian: bigEndian)
        while pos + 4 <= end {
            let g = u16(pos, bigEndian), el = u16(pos + 2, bigEndian)
            let tag = Tag(g, el)
            if tag == .itemDelimitation {
                pos += 8
                if untilItemDelimiter { return ds }
                continue
            }
            if tag == .sequenceDelimitation {
                if untilItemDelimiter { return ds } // malformed, let caller handle
                pos += 8
                continue
            }
            if headerOnly && depth == 0 && (tag == .pixelData || tag == .floatPixelData || tag == .doubleFloatPixelData) { pos = end; break }
            if pos + 8 > end { truncated = true; pos = end; break }
            guard let e = readElement(pos: &pos, end: end, explicitVR: explicit, be: bigEndian, depth: depth) else { break }
            ds.insert(e)
        }
        return ds
    }

    mutating func readElement(pos: inout Int, end: Int, explicitVR: Bool, be: Bool, depth: Int) -> DataElement? {
        let start = pos
        let tag = Tag(u16(pos, be), u16(pos + 2, be))
        pos += 4
        var vr: VR
        var length: UInt32
        if tag.group == 0xFFFE {
            vr = .UN
            length = u32(pos, be)
            pos += 4
        } else if explicitVR, let v = VR(bytes: byte(pos), byte(pos + 1)) {
            vr = v
            if v.hasLongExplicitLength {
                guard pos + 8 <= end else { truncated = true; pos = end; return nil }
                length = u32(pos + 4, be)
                pos += 8
            } else {
                length = UInt32(u16(pos + 2, be))
                pos += 4
            }
        } else {
            vr = DataDictionary.vr(for: tag)
            length = u32(pos, be)
            pos += 4
        }
        if tag.isPrivate && vr == .UN && !explicitVR && tag.isPrivateCreator { vr = .LO }

        let undefined = length == 0xFFFF_FFFF
        if undefined {
            if tag == .pixelData || (vr == .OB || vr == .OW) && tag.group == 0x7FE0 {
                let enc = parseFragments(pos: &pos, end: end)
                return DataElement(tag: tag, vr: vr == .OW ? .OB : vr, value: .encapsulated(enc), valueOffset: start, declaredLength: length)
            }
            // SQ, or UN / private with undefined length -> sequence (UN is implicit LE)
            let saveExplicit = explicit, saveBE = bigEndian
            if vr == .UN { explicit = false; bigEndian = false }
            let items = parseSequence(pos: &pos, end: end, definedEnd: nil, depth: depth + 1)
            explicit = saveExplicit; bigEndian = saveBE
            return DataElement(tag: tag, vr: .SQ, value: .sequence(items), valueOffset: start, declaredLength: length)
        }

        var len = Int(length)
        if pos + len > end {
            truncated = true
            len = max(0, end - pos)
        }
        if vr == .SQ {
            let items = parseSequence(pos: &pos, end: end, definedEnd: pos + len, depth: depth + 1)
            return DataElement(tag: tag, vr: .SQ, value: .sequence(items), valueOffset: start, declaredLength: length)
        }
        let value = slice(pos, len)
        let valueOffset = pos
        pos += len
        return DataElement(tag: tag, vr: vr, value: .data(value), valueOffset: valueOffset, declaredLength: length)
    }

    mutating func parseSequence(pos: inout Int, end: Int, definedEnd: Int?, depth: Int) -> [DataSet] {
        var items: [DataSet] = []
        let limit = min(definedEnd ?? end, end)
        guard depth < 64 else { pos = limit; return items }
        while pos + 8 <= limit {
            let tag = Tag(u16(pos, bigEndian), u16(pos + 2, bigEndian))
            let len = u32(pos + 4, bigEndian)
            if tag == .sequenceDelimitation { pos += 8; break }
            guard tag == .item else {
                // Malformed: skip to end of defined sequence or stop
                if let d = definedEnd { pos = d }
                break
            }
            pos += 8
            if len == 0xFFFF_FFFF {
                let ds = parseDataSet(pos: &pos, end: limit, untilItemDelimiter: true, depth: depth)
                items.append(ds)
            } else {
                let itemEnd = min(pos + Int(len), limit)
                let ds = parseDataSet(pos: &pos, end: itemEnd, untilItemDelimiter: false, depth: depth)
                pos = itemEnd
                items.append(ds)
            }
        }
        if let d = definedEnd, pos < d { pos = min(d, end) }
        return items
    }

    mutating func parseFragments(pos: inout Int, end: Int) -> EncapsulatedPixelData {
        var bot = Data()
        var frags: [Data] = []
        var first = true
        while pos + 8 <= end {
            let tag = Tag(u16(pos, bigEndian), u16(pos + 2, bigEndian))
            let len = Int(u32(pos + 4, bigEndian))
            pos += 8
            if tag == .sequenceDelimitation { break }
            guard tag == .item else { truncated = true; break }
            let l = min(len, end - pos)
            if l < len { truncated = true }
            let d = data[data.startIndex + pos ..< data.startIndex + pos + l]
            if first { bot = Data(d); first = false } else { frags.append(d) }
            pos += l
        }
        return EncapsulatedPixelData(basicOffsetTable: bot, fragments: frags)
    }
}

/// Raw DEFLATE / zlib inflation via the Compression framework.
public enum Inflate {
    public static func raw(_ input: Data, expectedSize: Int? = nil) -> Data? {
        if input.isEmpty { return Data() }
        return input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
            defer { compression_stream_destroy(stream) }
            let chunk = 1 << 20
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            defer { dst.deallocate() }
            var out = Data()
            if let e = expectedSize { out.reserveCapacity(e) }
            stream.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = src.count
            while true {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                if produced > 0 { out.append(dst, count: produced) }
                if status == COMPRESSION_STATUS_END { return out }
                if status == COMPRESSION_STATUS_ERROR { return out.isEmpty ? nil : out }
                if produced == 0 && stream.pointee.src_size == 0 { return out }
            }
        }
    }

    /// zlib-wrapped stream (2-byte header, adler32 trailer).
    public static func zlib(_ input: Data) -> Data? {
        guard input.count > 6 else { return nil }
        return raw(input.subdata(in: input.startIndex + 2 ..< input.endIndex - 4))
    }

    public static func deflate(_ input: Data) -> Data? {
        if input.isEmpty { return Data() }
        return input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }
            guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
            defer { compression_stream_destroy(stream) }
            let chunk = 1 << 20
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            defer { dst.deallocate() }
            var out = Data()
            stream.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = src.count
            while true {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                if produced > 0 { out.append(dst, count: produced) }
                if status == COMPRESSION_STATUS_END { return out }
                if status == COMPRESSION_STATUS_ERROR { return nil }
            }
        }
    }
}
