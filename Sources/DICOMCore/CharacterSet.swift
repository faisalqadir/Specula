import Foundation
import CoreFoundation

/// Decodes DICOM string values according to Specific Character Set (0008,0005),
/// including ISO 2022 code extensions used for Japanese, Korean and Chinese.
public struct DICOMStringDecoder: Sendable {
    public let terms: [String]
    private let defaultEncoding: String.Encoding
    private let usesCodeExtensions: Bool

    public static let `default` = DICOMStringDecoder(specificCharacterSet: [])

    /// Optional override used by the app's "force character set" setting.
    nonisolated(unsafe) public static var forcedCharacterSet: String?

    public init(specificCharacterSet raw: [String]) {
        var t = raw.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        if let forced = DICOMStringDecoder.forcedCharacterSet, !forced.isEmpty { t = [forced.uppercased()] }
        terms = t
        usesCodeExtensions = t.contains { $0.hasPrefix("ISO 2022") } || t.count > 1
        let first = t.first ?? ""
        defaultEncoding = DICOMStringDecoder.encoding(forTerm: first) ?? .isoLatin1
    }

    static func cf(_ e: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
    }

    static func encoding(forTerm term: String) -> String.Encoding? {
        switch term.replacingOccurrences(of: "ISO 2022 ", with: "ISO_").replacingOccurrences(of: "ISO_IR ", with: "ISO_") {
        case "", "ISO_6", "ISO_IR 6", "ISO_100": return .isoLatin1
        case "ISO_101": return .isoLatin2
        case "ISO_109": return cf(.isoLatin3)
        case "ISO_110": return cf(.isoLatin4)
        case "ISO_144": return cf(.isoLatinCyrillic)
        case "ISO_127": return cf(.isoLatinArabic)
        case "ISO_126": return cf(.isoLatinGreek)
        case "ISO_138": return cf(.isoLatinHebrew)
        case "ISO_148": return cf(.isoLatin5)
        case "ISO_203": return cf(.isoLatin9)
        case "ISO_13": return .shiftJIS
        case "ISO_166": return cf(.isoLatinThai)
        case "ISO_192": return .utf8
        case "GB18030": return cf(.GB_18030_2000)
        case "GBK", "CP936": return cf(.GBK_95)
        case "CP950": return cf(.big5)
        case "CP1251": return .windowsCP1251
        case "ISO_87", "ISO_159": return .japaneseEUC
        case "ISO_149": return cf(.EUC_KR)
        case "ISO_58": return cf(.EUC_CN)
        default: return nil
        }
    }

    public func decode(_ bytes: Data, vr: VR = .LO) -> String {
        if bytes.isEmpty { return "" }
        if !usesCodeExtensions || !bytes.contains(0x1B) {
            if let s = String(data: bytes, encoding: defaultEncoding) { return s }
            return String(decoding: bytes, as: UTF8.self)
        }
        return decodeISO2022(bytes, vr: vr)
    }

    private enum G0 { case ascii, romaji, jisx0208, jisx0212 }

    private func decodeISO2022(_ bytes: Data, vr: VR) -> String {
        let b = [UInt8](bytes)
        var out = ""
        var g0: G0 = .ascii
        var g1: String.Encoding? = terms.first.flatMap { $0.isEmpty ? nil : DICOMStringDecoder.encoding(forTerm: $0) }
        var g1IsKatakana = terms.first == "ISO 2022 IR 13" || terms.first == "ISO_IR 13"
        var run: [UInt8] = []
        var runKind: (G0, String.Encoding?, Bool) = (g0, g1, g1IsKatakana)

        func flush() {
            guard !run.isEmpty else { return }
            let (k, enc1, kata) = runKind
            switch k {
            case .jisx0208:
                let eucs = run.map { $0 | 0x80 }
                out += String(data: Data(eucs), encoding: .japaneseEUC) ?? ""
            case .jisx0212:
                var eucs: [UInt8] = []
                var i = 0
                while i + 1 < run.count { eucs += [0x8F, run[i] | 0x80, run[i + 1] | 0x80]; i += 2 }
                out += String(data: Data(eucs), encoding: .japaneseEUC) ?? ""
            case .ascii, .romaji:
                var i = 0
                while i < run.count {
                    if run[i] < 0x80 {
                        var j = i
                        while j < run.count && run[j] < 0x80 { j += 1 }
                        let s = String(decoding: run[i..<j], as: UTF8.self)
                        out += k == .romaji ? s.replacingOccurrences(of: "\\", with: "¥").replacingOccurrences(of: "~", with: "‾") : s
                        i = j
                    } else {
                        var j = i
                        while j < run.count && run[j] >= 0x80 { j += 1 }
                        let hi = Data(run[i..<j])
                        if kata { out += String(data: hi, encoding: .shiftJIS) ?? "" }
                        else if let e = enc1 { out += String(data: hi, encoding: e) ?? "" }
                        else { out += String(data: hi, encoding: .isoLatin1) ?? "" }
                        i = j
                    }
                }
            }
            run.removeAll(keepingCapacity: true)
        }

        var i = 0
        while i < b.count {
            let c = b[i]
            if c == 0x1B {
                flush()
                if i + 2 < b.count {
                    let s1 = b[i + 1], s2 = b[i + 2]
                    if s1 == 0x28 && s2 == 0x42 { g0 = .ascii; i += 3 }
                    else if s1 == 0x28 && s2 == 0x4A { g0 = .romaji; i += 3 }
                    else if s1 == 0x29 && s2 == 0x49 { g1 = .shiftJIS; g1IsKatakana = true; i += 3 }
                    else if s1 == 0x24 && (s2 == 0x42 || s2 == 0x40) { g0 = .jisx0208; i += 3 }
                    else if s1 == 0x24 && s2 == 0x28 && i + 3 < b.count && b[i + 3] == 0x44 { g0 = .jisx0212; i += 4 }
                    else if s1 == 0x24 && s2 == 0x29 && i + 3 < b.count {
                        let f = b[i + 3]
                        if f == 0x43 { g1 = DICOMStringDecoder.cf(.EUC_KR) } else if f == 0x41 { g1 = DICOMStringDecoder.cf(.EUC_CN) }
                        g1IsKatakana = false
                        i += 4
                    } else if s1 == 0x2D {
                        let map: [UInt8: String] = [0x41: "ISO_IR 100", 0x42: "ISO_IR 101", 0x43: "ISO_IR 109", 0x44: "ISO_IR 110", 0x4C: "ISO_IR 144", 0x47: "ISO_IR 127", 0x46: "ISO_IR 126", 0x48: "ISO_IR 138", 0x4D: "ISO_IR 148", 0x54: "ISO_IR 166", 0x62: "ISO_IR 203"]
                        if let term = map[s2] { g1 = DICOMStringDecoder.encoding(forTerm: term) }
                        g1IsKatakana = false
                        i += 3
                    } else { i += 1 }
                } else { i += 1 }
                runKind = (g0, g1, g1IsKatakana)
                continue
            }
            // Delimiters reset G0 to ASCII
            let isDelimiter = c == 0x0D || c == 0x0A || c == 0x09 || c == 0x0C || c == 0x5C || (vr == .PN && (c == 0x5E || c == 0x3D))
            if isDelimiter && g0 != .ascii && (g0 != .jisx0208 && g0 != .jisx0212 || run.count % 2 == 0) {
                flush(); g0 = .ascii; runKind = (g0, g1, g1IsKatakana)
            }
            run.append(c)
            i += 1
        }
        flush()
        return out
    }

    /// Encodes a string for writing; returns UTF-8 bytes (callers set ISO_IR 192 when non-ASCII).
    public static func encode(_ s: String) -> Data { Data(s.utf8) }
}
