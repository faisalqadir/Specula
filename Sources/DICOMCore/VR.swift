import Foundation

/// DICOM value representations.
public enum VR: String, CaseIterable, Sendable {
    case AE, AS, AT, CS, DA, DS, DT, FD, FL, IS, LO, LT, OB, OD, OF, OL, OV, OW, PN, SH, SL, SQ, SS, ST, SV, TM, UC, UI, UL, UN, UR, US, UT, UV

    public init?(bytes b0: UInt8, _ b1: UInt8) {
        guard b0 >= 0x41, b0 <= 0x5A, b1 >= 0x41, b1 <= 0x5A else { return nil }
        let s = String(decoding: [b0, b1], as: UTF8.self)
        self.init(rawValue: s)
    }

    /// Explicit-VR encodings that use a 2-byte reserved field and 4-byte length.
    public var hasLongExplicitLength: Bool {
        switch self {
        case .OB, .OD, .OF, .OL, .OV, .OW, .SQ, .UC, .UR, .UT, .UN, .SV, .UV: return true
        default: return false
        }
    }

    public var isString: Bool {
        switch self {
        case .AE, .AS, .CS, .DA, .DS, .DT, .IS, .LO, .LT, .PN, .SH, .ST, .TM, .UC, .UI, .UR, .UT: return true
        default: return false
        }
    }

    /// String VRs whose values may be affected by Specific Character Set.
    public var usesCharacterSet: Bool {
        switch self {
        case .LO, .LT, .PN, .SH, .ST, .UC, .UT: return true
        default: return false
        }
    }

    /// String VRs that allow multiple values separated by backslash.
    public var isMultiValuedString: Bool {
        switch self {
        case .LT, .ST, .UT, .UR: return false
        default: return isString
        }
    }

    public var paddingByte: UInt8 {
        switch self {
        case .UI, .OB, .UN: return 0
        default: return isString ? 0x20 : 0
        }
    }

    /// Size in bytes of one binary value, or nil for strings / sequences.
    public var binaryValueSize: Int? {
        switch self {
        case .AT, .FL, .SL, .UL, .OF, .OL: return 4
        case .FD, .OD, .SV, .UV, .OV: return 8
        case .SS, .US, .OW: return 2
        case .OB, .UN: return 1
        default: return nil
        }
    }

    public var isBinaryNumeric: Bool {
        switch self {
        case .AT, .FL, .FD, .SL, .SS, .UL, .US, .SV, .UV, .OF, .OD, .OL, .OV, .OW: return true
        default: return false
        }
    }

    /// Maps DCMTK pseudo-VR codes from the dictionary to a concrete VR.
    static func fromDictionary(_ s: Substring) -> VR {
        if let v = VR(rawValue: String(s)) { return v }
        switch s {
        case "xs": return .US
        case "ox", "px", "lt": return .OW
        case "up": return .UL
        default: return .UN
        }
    }
}
