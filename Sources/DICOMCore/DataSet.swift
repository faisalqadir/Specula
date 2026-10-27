import Foundation

/// Encapsulated (compressed) pixel data: basic offset table + fragments.
public struct EncapsulatedPixelData: Sendable {
    public var basicOffsetTable: Data
    public var fragments: [Data]
    public init(basicOffsetTable: Data = Data(), fragments: [Data]) {
        self.basicOffsetTable = basicOffsetTable
        self.fragments = fragments
    }
}

public final class DataElement: @unchecked Sendable {
    public enum Value {
        case data(Data)
        case sequence([DataSet])
        case encapsulated(EncapsulatedPixelData)
    }

    public let tag: Tag
    public var vr: VR
    public var value: Value
    /// Offset of the value field in the source file (when parsed from a file).
    public var valueOffset: Int
    /// Length as it appeared in the source (0xFFFFFFFF for undefined).
    public var declaredLength: UInt32

    public init(tag: Tag, vr: VR, value: Value, valueOffset: Int = -1, declaredLength: UInt32 = 0) {
        self.tag = tag
        self.vr = vr
        self.value = value
        self.valueOffset = valueOffset
        self.declaredLength = declaredLength
    }

    public var data: Data? { if case .data(let d) = value { return d }; return nil }
    public var items: [DataSet]? { if case .sequence(let s) = value { return s }; return nil }
    public var encapsulated: EncapsulatedPixelData? { if case .encapsulated(let e) = value { return e }; return nil }

    /// Value length in bytes (sum of fragments for encapsulated data).
    public var length: Int {
        switch value {
        case .data(let d): return d.count
        case .sequence: return Int(declaredLength == 0xFFFF_FFFF ? 0 : declaredLength)
        case .encapsulated(let e): return e.fragments.reduce(e.basicOffsetTable.count) { $0 + $1.count }
        }
    }
}

/// An ordered collection of DICOM data elements.
public final class DataSet: @unchecked Sendable {
    public private(set) var elements: [Tag: DataElement] = [:]
    /// Byte order of binary values held by elements of this data set.
    public var bigEndian: Bool
    public weak var parent: DataSet?
    private var cachedDecoder: DICOMStringDecoder?
    private var sortedCache: [DataElement]?

    public init(bigEndian: Bool = false) { self.bigEndian = bigEndian }

    public var isEmpty: Bool { elements.isEmpty }
    public var count: Int { elements.count }

    public var sortedElements: [DataElement] {
        if let s = sortedCache { return s }
        let s = elements.values.sorted { $0.tag < $1.tag }
        sortedCache = s
        return s
    }

    public subscript(tag: Tag) -> DataElement? { elements[tag] }
    public func contains(_ tag: Tag) -> Bool { elements[tag] != nil }

    public func insert(_ element: DataElement) {
        elements[element.tag] = element
        sortedCache = nil
        if element.tag == .specificCharacterSet { cachedDecoder = nil }
        if case .sequence(let items) = element.value { items.forEach { $0.parent = self } }
    }

    @discardableResult
    public func remove(_ tag: Tag) -> DataElement? {
        sortedCache = nil
        if tag == .specificCharacterSet { cachedDecoder = nil }
        return elements.removeValue(forKey: tag)
    }

    public func removeAll(where predicate: (DataElement) -> Bool) {
        for (t, e) in elements where predicate(e) { elements.removeValue(forKey: t) }
        sortedCache = nil
        cachedDecoder = nil
    }

    /// Effective string decoder (inherits Specific Character Set from parent data sets).
    public var decoder: DICOMStringDecoder {
        if let d = cachedDecoder { return d }
        let d: DICOMStringDecoder
        if let e = elements[.specificCharacterSet], let raw = e.data {
            let terms = String(decoding: raw, as: UTF8.self).split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
            d = DICOMStringDecoder(specificCharacterSet: terms)
        } else if let p = parent {
            d = p.decoder
        } else {
            d = DICOMStringDecoder.default
        }
        cachedDecoder = d
        return d
    }

    // MARK: - String access

    private static let trimSet = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\0"))

    /// Full decoded string value (all values joined by backslash), trimmed.
    public func rawString(_ tag: Tag) -> String? {
        guard let e = elements[tag], let d = e.data else { return nil }
        let s: String
        if e.vr.usesCharacterSet || e.vr == .UN { s = decoder.decode(d, vr: e.vr) } else { s = String(decoding: d, as: UTF8.self) }
        return s.trimmingCharacters(in: DataSet.trimSet)
    }

    public func string(_ tag: Tag) -> String? {
        guard let e = elements[tag] else { return nil }
        if e.vr.isString || e.vr == .UN {
            guard let s = rawString(tag) else { return nil }
            if e.vr.isMultiValuedString, let first = s.split(separator: "\\", omittingEmptySubsequences: false).first {
                let v = first.trimmingCharacters(in: DataSet.trimSet)
                return v.isEmpty ? nil : v
            }
            return s.isEmpty ? nil : s
        }
        if let v = doubles(tag).first { return DataSet.format(v) }
        return nil
    }

    public func strings(_ tag: Tag) -> [String] {
        guard let s = rawString(tag), !s.isEmpty else { return [] }
        return s.split(separator: "\\", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: DataSet.trimSet) }
    }

    // MARK: - Numeric access

    public func int(_ tag: Tag) -> Int? {
        guard let e = elements[tag] else { return nil }
        if e.vr == .IS || e.vr == .DS || e.vr.isString { return string(tag).flatMap { Int($0) ?? Double($0).map { Int($0) } } }
        return doubles(tag).first.map { Int($0) }
    }

    public func double(_ tag: Tag) -> Double? { doubles(tag).first }

    public func doubles(_ tag: Tag) -> [Double] {
        guard let e = elements[tag], let d = e.data else { return [] }
        switch e.vr {
        case .DS, .IS:
            return String(decoding: d, as: UTF8.self).split(separator: "\\").compactMap { Double($0.trimmingCharacters(in: DataSet.trimSet)) }
        case .US, .OW: return uint16s(d).map(Double.init)
        case .SS: return uint16s(d).map { Double(Int16(bitPattern: $0)) }
        case .UL, .OL: return uint32s(d).map(Double.init)
        case .SL: return uint32s(d).map { Double(Int32(bitPattern: $0)) }
        case .FL, .OF: return uint32s(d).map { Double(Float(bitPattern: $0)) }
        case .FD, .OD: return uint64s(d).map { Double(bitPattern: $0) }
        case .SV: return uint64s(d).map { Double(Int64(bitPattern: $0)) }
        case .UV, .OV: return uint64s(d).map { Double($0) }
        case .UN:
            // Implicit private data, try as string
            return String(decoding: d, as: UTF8.self).split(separator: "\\").compactMap { Double($0.trimmingCharacters(in: DataSet.trimSet)) }
        default:
            if e.vr.isString { return String(decoding: d, as: UTF8.self).split(separator: "\\").compactMap { Double($0.trimmingCharacters(in: DataSet.trimSet)) } }
            return []
        }
    }

    public func uint16s(_ tag: Tag) -> [UInt16] { elements[tag]?.data.map { uint16s($0) } ?? [] }
    public func uint16(_ tag: Tag) -> UInt16? { uint16s(tag).first }
    public func tags(_ tag: Tag) -> [Tag] {
        let v = uint16s(tag)
        return stride(from: 0, to: v.count - 1, by: 2).map { Tag(v[$0], v[$0 + 1]) }
    }

    public func uint16s(_ d: Data) -> [UInt16] {
        let n = d.count / 2
        var out = [UInt16](repeating: 0, count: n)
        d.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)
                out[i] = bigEndian ? v.byteSwapped : v
            }
        }
        return out
    }

    public func uint32s(_ d: Data) -> [UInt32] {
        let n = d.count / 4
        var out = [UInt32](repeating: 0, count: n)
        d.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                out[i] = bigEndian ? v.byteSwapped : v
            }
        }
        return out
    }

    public func uint64s(_ d: Data) -> [UInt64] {
        let n = d.count / 8
        var out = [UInt64](repeating: 0, count: n)
        d.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)
                out[i] = bigEndian ? v.byteSwapped : v
            }
        }
        return out
    }

    public func data(_ tag: Tag) -> Data? { elements[tag]?.data }
    public func sequence(_ tag: Tag) -> [DataSet]? { elements[tag]?.items }
    public func firstItem(_ tag: Tag) -> DataSet? { elements[tag]?.items?.first }

    // MARK: - Mutation helpers

    public func set(_ tag: Tag, _ vr: VR, string value: String) {
        var bytes = Data(value.utf8)
        if bytes.count % 2 == 1 { bytes.append(vr.paddingByte) }
        insert(DataElement(tag: tag, vr: vr, value: .data(bytes)))
    }

    public func set(_ tag: Tag, _ vr: VR, strings values: [String]) { set(tag, vr, string: values.joined(separator: "\\")) }

    public func set(_ tag: Tag, uint16 values: [UInt16], vr: VR = .US) {
        var d = Data(capacity: values.count * 2)
        for v in values { let x = bigEndian ? v.byteSwapped : v; withUnsafeBytes(of: x) { d.append(contentsOf: $0) } }
        insert(DataElement(tag: tag, vr: vr, value: .data(d)))
    }

    public func set(_ tag: Tag, uint32 values: [UInt32], vr: VR = .UL) {
        var d = Data(capacity: values.count * 4)
        for v in values { let x = bigEndian ? v.byteSwapped : v; withUnsafeBytes(of: x) { d.append(contentsOf: $0) } }
        insert(DataElement(tag: tag, vr: vr, value: .data(d)))
    }

    public func set(_ tag: Tag, double values: [Double], vr: VR = .DS) {
        switch vr {
        case .FD:
            var d = Data()
            for v in values { let x = bigEndian ? v.bitPattern.byteSwapped : v.bitPattern; withUnsafeBytes(of: x) { d.append(contentsOf: $0) } }
            insert(DataElement(tag: tag, vr: vr, value: .data(d)))
        case .FL:
            var d = Data()
            for v in values { let b = Float(v).bitPattern; let x = bigEndian ? b.byteSwapped : b; withUnsafeBytes(of: x) { d.append(contentsOf: $0) } }
            insert(DataElement(tag: tag, vr: vr, value: .data(d)))
        default:
            set(tag, vr, string: values.map { DataSet.formatDS($0) }.joined(separator: "\\"))
        }
    }

    public func set(_ tag: Tag, sequence items: [DataSet]) {
        insert(DataElement(tag: tag, vr: .SQ, value: .sequence(items), declaredLength: 0xFFFF_FFFF))
    }

    public func set(_ tag: Tag, _ vr: VR, data: Data) {
        insert(DataElement(tag: tag, vr: vr, value: .data(data)))
    }

    /// Deep copy (data buffers are value types and shared copy-on-write).
    public func copy() -> DataSet {
        let ds = DataSet(bigEndian: bigEndian)
        for e in elements.values {
            let v: DataElement.Value
            switch e.value {
            case .sequence(let items): v = .sequence(items.map { $0.copy() })
            default: v = e.value
            }
            ds.insert(DataElement(tag: e.tag, vr: e.vr, value: v, valueOffset: e.valueOffset, declaredLength: e.declaredLength))
        }
        return ds
    }

    // MARK: - Formatting

    static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        return String(format: "%g", v)
    }

    /// Formats a value to fit the 16-byte DS limit.
    public static func formatDS(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        for p in stride(from: 10, through: 1, by: -1) {
            let s = String(format: "%.\(p)g", v)
            if s.count <= 16 { return s }
        }
        return String(format: "%.6e", v)
    }

    /// Human readable value for tag browsers.
    public func displayValue(_ e: DataElement, maxValues: Int = 64) -> String {
        switch e.value {
        case .sequence(let items): return "Sequence with \(items.count) item\(items.count == 1 ? "" : "s")"
        case .encapsulated(let enc): return "Encapsulated pixel data, \(enc.fragments.count) fragment\(enc.fragments.count == 1 ? "" : "s")"
        case .data(let d):
            if e.tag == .pixelData || e.tag == .floatPixelData || e.tag == .doubleFloatPixelData { return "Pixel data (\(d.count) bytes)" }
            if e.vr.isString { return rawString(e.tag) ?? "" }
            switch e.vr {
            case .AT:
                return tags(e.tag).map(\.description).joined(separator: "\\")
            case .OB, .UN:
                if e.vr == .UN, d.count <= 256, d.allSatisfy({ ($0 >= 0x20 && $0 < 0x7F) || $0 == 0 }) {
                    return String(decoding: d, as: UTF8.self).trimmingCharacters(in: DataSet.trimSet)
                }
                let shown = d.prefix(maxValues).map { String(format: "%02X", $0) }.joined(separator: "\\")
                return d.count > maxValues ? shown + "…" : shown
            case .OW, .OL, .OF, .OD, .OV:
                let vals = doubles(e.tag)
                let shown = vals.prefix(maxValues).map { DataSet.format($0) }.joined(separator: "\\")
                return vals.count > maxValues ? shown + "…" : shown
            default:
                let vals = doubles(e.tag)
                let shown = vals.prefix(maxValues).map { DataSet.format($0) }.joined(separator: "\\")
                return vals.count > maxValues ? shown + "…" : shown
            }
        }
    }

    /// Number of values (VM) for display.
    public func valueMultiplicity(_ e: DataElement) -> Int {
        switch e.value {
        case .sequence(let items): return items.count
        case .encapsulated: return 1
        case .data(let d):
            if d.isEmpty { return 0 }
            if e.vr.isString { return e.vr.isMultiValuedString ? strings(e.tag).count : 1 }
            if let sz = e.vr.binaryValueSize, e.vr != .OB, e.vr != .OW, e.vr != .UN { return d.count / sz }
            return 1
        }
    }
}

// MARK: - Date / time helpers

public enum DICOMDate {
    public static func parseDate(_ s: String?) -> DateComponents? {
        guard let s, s.count >= 8 else { return nil }
        let digits = s.filter(\.isNumber)
        guard digits.count >= 8 else { return nil }
        let y = Int(digits.prefix(4)), m = Int(digits.dropFirst(4).prefix(2)), d = Int(digits.dropFirst(6).prefix(2))
        guard let y, let m, let d else { return nil }
        return DateComponents(year: y, month: m, day: d)
    }

    /// Seconds since midnight for a DICOM TM value.
    public static func parseTime(_ s: String?) -> Double? {
        guard var s, !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: ":", with: "")
        let parts = s.split(separator: ".", maxSplits: 1)
        let main = String(parts[0])
        guard main.count >= 2 else { return nil }
        let h = Double(main.prefix(2)) ?? 0
        let m = main.count >= 4 ? Double(main.dropFirst(2).prefix(2)) ?? 0 : 0
        let sec = main.count >= 6 ? Double(main.dropFirst(4).prefix(2)) ?? 0 : 0
        let frac = parts.count > 1 ? Double("0." + parts[1]) ?? 0 : 0
        return h * 3600 + m * 60 + sec + frac
    }

    public static func date(da: String?, tm: String?) -> Date? {
        guard var c = parseDate(da) else { return nil }
        if let t = parseTime(tm) {
            c.hour = Int(t / 3600); c.minute = Int(t.truncatingRemainder(dividingBy: 3600) / 60)
            c.second = Int(t.truncatingRemainder(dividingBy: 60))
            c.nanosecond = Int((t - t.rounded(.down)) * 1e9)
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal.date(from: c)
    }

    /// Parses DT values (YYYYMMDDHHMMSS.FFFFFF&ZZXX).
    public static func dateTime(_ s: String?) -> Date? {
        guard let s, s.count >= 8 else { return nil }
        let core = s.split(whereSeparator: { $0 == "+" || $0 == "-" }).first.map(String.init) ?? s
        let da = String(core.prefix(8))
        let tm = core.count > 8 ? String(core.dropFirst(8)) : nil
        return date(da: da, tm: tm)
    }

    public static func formatDate(_ s: String?) -> String {
        guard let c = parseDate(s), let y = c.year, let m = c.month, let d = c.day else { return s ?? "" }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    public static func formatTime(_ s: String?) -> String {
        guard let t = parseTime(s) else { return s ?? "" }
        let h = Int(t / 3600), m = Int(t.truncatingRemainder(dividingBy: 3600) / 60), sec = Int(t.truncatingRemainder(dividingBy: 60))
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }

    public static func dicomDate(_ d: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func dicomTime(_ d: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.hour, .minute, .second], from: d)
        return String(format: "%02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

public enum PersonName {
    /// "Doe^John^^^" -> "Doe John" (alphabetic component group only unless empty).
    public static func display(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let groups = raw.split(separator: "=", omittingEmptySubsequences: false)
        let group = groups.first(where: { !$0.isEmpty }) ?? Substring(raw)
        let comps = group.split(separator: "^", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        // family, given, middle, prefix, suffix
        var parts: [String] = []
        if comps.count > 3, !comps[3].isEmpty { parts.append(comps[3]) }
        if comps.count > 0, !comps[0].isEmpty { parts.append(comps[0]) }
        if comps.count > 1, !comps[1].isEmpty { parts.append(comps[1]) }
        if comps.count > 2, !comps[2].isEmpty { parts.append(comps[2]) }
        if comps.count > 4, !comps[4].isEmpty { parts.append(comps[4]) }
        var s = parts.joined(separator: " ")
        if groups.count > 1, groups.first?.isEmpty == false {
            let ideo = groups.dropFirst().first(where: { !$0.isEmpty }).map { $0.replacingOccurrences(of: "^", with: " ").trimmingCharacters(in: .whitespaces) }
            if let ideo, !ideo.isEmpty { s += " (\(ideo))" }
        }
        return s
    }
}
