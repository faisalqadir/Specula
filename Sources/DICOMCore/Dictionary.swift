import Foundation

/// Data dictionary entry.
public struct DictionaryEntry: Sendable {
    public let tag: Tag
    public let vr: VR
    public let keyword: String
    public let vm: String
    public let retired: Bool

    /// Human readable name derived from the keyword ("SOPInstanceUID" -> "SOP Instance UID").
    public var name: String { DataDictionary.displayName(for: keyword) }
}

/// Standard DICOM data dictionary (generated from the DCMTK dictionary, see DictionaryData.swift).
public enum DataDictionary {
    private struct Tables {
        var exact: [UInt32: DictionaryEntry] = [:]
        var repeating: [(mask: UInt32, value: UInt32, entry: DictionaryEntry)] = []
        var byKeyword: [String: DictionaryEntry] = [:]
    }

    private static let tables: Tables = {
        var t = Tables()
        t.exact.reserveCapacity(5200)
        for line in dictionaryTable.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 4 else { continue }
            let tagStr = f[0]
            let vr = VR.fromDictionary(f[1])
            let keyword = String(f[2])
            let vm = String(f[3])
            let retired = f.count > 4 && f[4] == "R"
            if tagStr.contains("x") {
                var mask: UInt32 = 0, value: UInt32 = 0
                for ch in tagStr {
                    mask <<= 4; value <<= 4
                    if ch != "x" { mask |= 0xF; value |= UInt32(ch.hexDigitValue ?? 0) }
                }
                let e = DictionaryEntry(tag: Tag(raw: value), vr: vr, keyword: keyword, vm: vm, retired: retired)
                t.repeating.append((mask, value, e))
                t.byKeyword[keyword] = e
            } else if let raw = UInt32(tagStr, radix: 16) {
                let e = DictionaryEntry(tag: Tag(raw: raw), vr: vr, keyword: keyword, vm: vm, retired: retired)
                t.exact[raw] = e
                if t.byKeyword[keyword] == nil { t.byKeyword[keyword] = e }
            }
        }
        return t
    }()

    public static func entry(for tag: Tag) -> DictionaryEntry? {
        if let e = tables.exact[tag.raw] { return e }
        for r in tables.repeating where tag.raw & r.mask == r.value {
            return DictionaryEntry(tag: tag, vr: r.entry.vr, keyword: r.entry.keyword, vm: r.entry.vm, retired: r.entry.retired)
        }
        if tag.element == 0 { return DictionaryEntry(tag: tag, vr: .UL, keyword: "GroupLength", vm: "1", retired: false) }
        if tag.isPrivateCreator { return DictionaryEntry(tag: tag, vr: .LO, keyword: "PrivateCreator", vm: "1", retired: false) }
        return nil
    }

    public static func entry(keyword: String) -> DictionaryEntry? { tables.byKeyword[keyword] }

    public static var allEntries: [DictionaryEntry] {
        (Array(tables.exact.values) + tables.repeating.map { $0.entry }).sorted { $0.tag < $1.tag }
    }

    public static func vr(for tag: Tag) -> VR {
        if tag == .item || tag == .itemDelimitation || tag == .sequenceDelimitation { return .UN }
        return entry(for: tag)?.vr ?? .UN
    }

    public static func name(for tag: Tag) -> String {
        if tag.isPrivate {
            if tag.isPrivateCreator { return "Private Creator" }
            return "Private Tag"
        }
        if let e = entry(for: tag) { return e.name }
        return "Unknown"
    }

    private static let acronyms: Set<String> = ["SOP", "UID", "UIDs", "ID", "IDs", "DICOM", "AE", "CT", "MR", "PET", "VOI", "LUT", "RGB", "ICC", "XA", "RF", "US", "NM", "CTDI", "DLP", "SAR", "dB", "ECG", "HL7", "TR", "TE", "TI", "kVp", "RT", "MAC", "URL", "URI", "IOD", "SR", "CAD", "CDA", "PDF", "MIME", "UTC", "WADO", "RLE", "JPEG", "2D", "3D", "4D"]

    static func displayName(for keyword: String) -> String {
        guard !keyword.isEmpty else { return keyword }
        var words: [String] = []
        var current = ""
        let chars = Array(keyword)
        for i in 0..<chars.count {
            let c = chars[i]
            if i > 0 {
                let p = chars[i - 1]
                let n: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                let boundary =
                    (c.isUppercase && p.isLowercase) ||
                    (c.isUppercase && p.isUppercase && (n?.isLowercase ?? false) && !(c == "s" )) ||
                    (c.isNumber && !p.isNumber && !p.isUppercase) ||
                    (c.isLetter && p.isNumber && c.isUppercase)
                if boundary && !current.isEmpty { words.append(current); current = "" }
            }
            current.append(c)
        }
        if !current.isEmpty { words.append(current) }
        // Re-join pluralised acronyms such as "UI" "Ds" -> "UIDs"
        var merged: [String] = []
        for w in words {
            if let last = merged.last, last.allSatisfy({ $0.isUppercase }), w == "s" {
                merged[merged.count - 1] = last + w
            } else {
                merged.append(w)
            }
        }
        return merged.joined(separator: " ")
    }
}
