import Foundation
import DICOMCore

public enum TransferSyntaxUID {
    public static let implicitLE = "1.2.840.10008.1.2"
    public static let explicitLE = "1.2.840.10008.1.2.1"
    public static let explicitBE = "1.2.840.10008.1.2.2"
    public static let deflated = "1.2.840.10008.1.2.1.99"
}

public enum SOPClass {
    public static let verification = "1.2.840.10008.1.1"
    public static let patientRootFind = "1.2.840.10008.5.1.4.1.2.1.1"
    public static let patientRootMove = "1.2.840.10008.5.1.4.1.2.1.2"
    public static let patientRootGet = "1.2.840.10008.5.1.4.1.2.1.3"
    public static let studyRootFind = "1.2.840.10008.5.1.4.1.2.2.1"
    public static let studyRootMove = "1.2.840.10008.5.1.4.1.2.2.2"
    public static let studyRootGet = "1.2.840.10008.5.1.4.1.2.2.3"

    /// Storage SOP classes proposed for C-GET and accepted by the listener (PS3.4 Annex B).
    public static let storage: [String] = [
        "1.2.840.10008.5.1.4.1.1.1", "1.2.840.10008.5.1.4.1.1.1.1", "1.2.840.10008.5.1.4.1.1.1.1.1",
        "1.2.840.10008.5.1.4.1.1.1.2", "1.2.840.10008.5.1.4.1.1.1.2.1", "1.2.840.10008.5.1.4.1.1.1.3",
        "1.2.840.10008.5.1.4.1.1.1.3.1", "1.2.840.10008.5.1.4.1.1.2", "1.2.840.10008.5.1.4.1.1.2.1",
        "1.2.840.10008.5.1.4.1.1.2.2", "1.2.840.10008.5.1.4.1.1.3", "1.2.840.10008.5.1.4.1.1.3.1",
        "1.2.840.10008.5.1.4.1.1.4", "1.2.840.10008.5.1.4.1.1.4.1", "1.2.840.10008.5.1.4.1.1.4.2",
        "1.2.840.10008.5.1.4.1.1.4.3", "1.2.840.10008.5.1.4.1.1.4.4", "1.2.840.10008.5.1.4.1.1.5",
        "1.2.840.10008.5.1.4.1.1.6", "1.2.840.10008.5.1.4.1.1.6.1", "1.2.840.10008.5.1.4.1.1.6.2",
        "1.2.840.10008.5.1.4.1.1.7", "1.2.840.10008.5.1.4.1.1.7.1", "1.2.840.10008.5.1.4.1.1.7.2",
        "1.2.840.10008.5.1.4.1.1.7.3", "1.2.840.10008.5.1.4.1.1.7.4", "1.2.840.10008.5.1.4.1.1.9.1.1",
        "1.2.840.10008.5.1.4.1.1.9.1.2", "1.2.840.10008.5.1.4.1.1.9.1.3", "1.2.840.10008.5.1.4.1.1.9.2.1",
        "1.2.840.10008.5.1.4.1.1.9.3.1", "1.2.840.10008.5.1.4.1.1.9.4.1", "1.2.840.10008.5.1.4.1.1.11.1",
        "1.2.840.10008.5.1.4.1.1.11.2", "1.2.840.10008.5.1.4.1.1.11.3", "1.2.840.10008.5.1.4.1.1.11.4",
        "1.2.840.10008.5.1.4.1.1.12.1", "1.2.840.10008.5.1.4.1.1.12.1.1", "1.2.840.10008.5.1.4.1.1.12.2",
        "1.2.840.10008.5.1.4.1.1.12.2.1", "1.2.840.10008.5.1.4.1.1.12.3", "1.2.840.10008.5.1.4.1.1.13.1.1",
        "1.2.840.10008.5.1.4.1.1.13.1.2", "1.2.840.10008.5.1.4.1.1.13.1.3", "1.2.840.10008.5.1.4.1.1.14.1",
        "1.2.840.10008.5.1.4.1.1.20", "1.2.840.10008.5.1.4.1.1.30", "1.2.840.10008.5.1.4.1.1.66",
        "1.2.840.10008.5.1.4.1.1.66.1", "1.2.840.10008.5.1.4.1.1.66.2", "1.2.840.10008.5.1.4.1.1.66.3",
        "1.2.840.10008.5.1.4.1.1.66.4", "1.2.840.10008.5.1.4.1.1.66.5", "1.2.840.10008.5.1.4.1.1.67",
        "1.2.840.10008.5.1.4.1.1.77.1.1", "1.2.840.10008.5.1.4.1.1.77.1.1.1", "1.2.840.10008.5.1.4.1.1.77.1.2",
        "1.2.840.10008.5.1.4.1.1.77.1.2.1", "1.2.840.10008.5.1.4.1.1.77.1.3", "1.2.840.10008.5.1.4.1.1.77.1.4",
        "1.2.840.10008.5.1.4.1.1.77.1.4.1", "1.2.840.10008.5.1.4.1.1.77.1.5.1", "1.2.840.10008.5.1.4.1.1.77.1.5.2",
        "1.2.840.10008.5.1.4.1.1.77.1.5.4", "1.2.840.10008.5.1.4.1.1.77.1.6", "1.2.840.10008.5.1.4.1.1.88.11",
        "1.2.840.10008.5.1.4.1.1.88.22", "1.2.840.10008.5.1.4.1.1.88.33", "1.2.840.10008.5.1.4.1.1.88.34",
        "1.2.840.10008.5.1.4.1.1.88.50", "1.2.840.10008.5.1.4.1.1.88.59", "1.2.840.10008.5.1.4.1.1.88.67",
        "1.2.840.10008.5.1.4.1.1.88.68", "1.2.840.10008.5.1.4.1.1.104.1", "1.2.840.10008.5.1.4.1.1.104.2",
        "1.2.840.10008.5.1.4.1.1.104.3", "1.2.840.10008.5.1.4.1.1.128", "1.2.840.10008.5.1.4.1.1.128.1",
        "1.2.840.10008.5.1.4.1.1.130", "1.2.840.10008.5.1.4.1.1.481.1", "1.2.840.10008.5.1.4.1.1.481.2",
        "1.2.840.10008.5.1.4.1.1.481.3", "1.2.840.10008.5.1.4.1.1.481.4", "1.2.840.10008.5.1.4.1.1.481.5",
        "1.2.840.10008.5.1.4.1.1.481.8", "1.2.840.10008.5.1.4.1.1.481.9",
    ]

    static let videoStorage: Set<String> = ["1.2.840.10008.5.1.4.1.1.77.1.1.1", "1.2.840.10008.5.1.4.1.1.77.1.2.1", "1.2.840.10008.5.1.4.1.1.77.1.4.1"]
}

/// Which transfer syntaxes Specula proposes for storage contexts (RadiAnt "Proposed transfer syntaxes").
public enum ProposedTransferSyntaxes: Int, Codable, CaseIterable, Sendable {
    case all = 0, broadlySupported = 1, implicitOnly = 2

    public var title: String {
        switch self {
        case .all: return "All"
        case .broadlySupported: return "Broadly supported"
        case .implicitOnly: return "Implicit VR LE only"
        }
    }

    public func uids(forSOPClass sop: String) -> [String] {
        switch self {
        case .implicitOnly: return [TransferSyntaxUID.implicitLE]
        case .broadlySupported: return [TransferSyntaxUID.explicitLE, TransferSyntaxUID.implicitLE]
        case .all:
            var list = [TransferSyntaxUID.explicitLE, TransferSyntaxUID.implicitLE,
                        TransferSyntax.jpegLosslessSV1.uid, TransferSyntax.jpegLosslessP14.uid,
                        TransferSyntax.jpegLSLossless.uid, TransferSyntax.jpeg2000Lossless.uid,
                        TransferSyntax.rleLossless.uid, TransferSyntax.jpegBaseline.uid,
                        TransferSyntax.jpegExtended.uid, TransferSyntax.jpegLSNearLossless.uid,
                        TransferSyntax.jpeg2000.uid, TransferSyntaxUID.deflated, TransferSyntaxUID.explicitBE]
            if SOPClass.videoStorage.contains(sop) {
                list += [TransferSyntax.mpeg2MPML.uid, TransferSyntax.mpeg2MPHL.uid, TransferSyntax.mpeg4HP41.uid,
                         TransferSyntax.mpeg4HP41BD.uid, TransferSyntax.mpeg4HP42_2D.uid, TransferSyntax.hevcMP51.uid]
            }
            return list
        }
    }
}

public enum CommandField: UInt16 {
    case cStoreRQ = 0x0001, cStoreRSP = 0x8001
    case cGetRQ = 0x0010, cGetRSP = 0x8010
    case cFindRQ = 0x0020, cFindRSP = 0x8020
    case cMoveRQ = 0x0021, cMoveRSP = 0x8021
    case cEchoRQ = 0x0030, cEchoRSP = 0x8030
    case cCancelRQ = 0x0FFF
}

public enum DIMSEStatus {
    public static let success: UInt16 = 0x0000
    public static let pending: UInt16 = 0xFF00
    public static let pendingWarning: UInt16 = 0xFF01
    public static let cancel: UInt16 = 0xFE00
    public static let subOperationsWarning: UInt16 = 0xB000

    public static func isPending(_ s: UInt16) -> Bool { s == pending || s == pendingWarning }
    public static func isWarning(_ s: UInt16) -> Bool { s == 0x0001 || (s & 0xF000) == 0xB000 }
    public static func isFailure(_ s: UInt16) -> Bool { !isPending(s) && !isWarning(s) && s != success && s != cancel }

    /// Text that matches RadiAnt's download status strings (22026-22032).
    public static func describe(_ s: UInt16) -> String {
        switch s {
        case success: return "Success"
        case cancel: return "Terminated due to cancel indication"
        case 0xA701, 0xA702, 0xA700: return "Refused: out of resources"
        case 0xA801: return "Move destination unknown"
        case 0xA900: return "Identifier does not match SOP class"
        case 0x0122: return "SOP class not supported"
        case 0xB000: return "One or more failures"
        default:
            if (s & 0xF000) == 0xC000 { return String(format: "Unable to process (0x%04X)", s) }
            return String(format: "Status 0x%04X", s)
        }
    }
}

/// A DIMSE command set (group 0000), always encoded Implicit VR Little Endian.
public struct DIMSECommand: Sendable {
    public var elements: [UInt16: Data] = [:]

    public init() {}

    public static let noDataSet: UInt16 = 0x0101

    public var field: UInt16 { get { u16(0x0100) ?? 0 } set { set(0x0100, u16: newValue) } }
    public var messageID: UInt16 { get { u16(0x0110) ?? 0 } set { set(0x0110, u16: newValue) } }
    public var respondingTo: UInt16 { get { u16(0x0120) ?? 0 } set { set(0x0120, u16: newValue) } }
    public var hasDataSet: Bool { (u16(0x0800) ?? Self.noDataSet) != Self.noDataSet }
    public var status: UInt16 { u16(0x0900) ?? 0 }
    public var affectedSOPClass: String? { str(0x0002) }
    public var affectedSOPInstance: String? { str(0x1000) }
    public var moveDestination: String? { str(0x0600) }
    public var errorComment: String? { str(0x0902) }
    public var remaining: Int? { u16(0x1020).map(Int.init) }
    public var completed: Int? { u16(0x1021).map(Int.init) }
    public var failed: Int? { u16(0x1022).map(Int.init) }
    public var warnings: Int? { u16(0x1023).map(Int.init) }
    public var moveOriginatorAE: String? { str(0x1030) }

    public func u16(_ e: UInt16) -> UInt16? {
        guard let d = elements[e], d.count >= 2 else { return nil }
        return UInt16(d[d.startIndex]) | UInt16(d[d.startIndex + 1]) << 8
    }
    public func str(_ e: UInt16) -> String? {
        elements[e].map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) }
    }
    public mutating func set(_ e: UInt16, u16 v: UInt16) { elements[e] = Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    /// UI values pad with NUL, AE/LO with space.
    public mutating func set(_ e: UInt16, uid: String) {
        var b = Data(uid.utf8); if b.count % 2 == 1 { b.append(0) }
        elements[e] = b
    }
    public mutating func set(_ e: UInt16, text: String) {
        var b = Data(text.utf8); if b.count % 2 == 1 { b.append(0x20) }
        elements[e] = b
    }

    public func encode() -> Data {
        var body = Data()
        for e in elements.keys.sorted() where e != 0 {
            let v = elements[e]!
            appendLE(&body, UInt16(0)); appendLE(&body, e); appendLE32(&body, UInt32(v.count)); body.append(v)
        }
        var out = Data()
        appendLE(&out, UInt16(0)); appendLE(&out, UInt16(0)); appendLE32(&out, 4); appendLE32(&out, UInt32(body.count))
        out.append(body)
        return out
    }

    public static func decode(_ d: Data) throws -> DIMSECommand {
        var c = DIMSECommand()
        var i = d.startIndex
        while i + 8 <= d.endIndex {
            let group = UInt16(d[i]) | UInt16(d[i + 1]) << 8
            let elem = UInt16(d[i + 2]) | UInt16(d[i + 3]) << 8
            let len = Int(d[i + 4]) | Int(d[i + 5]) << 8 | Int(d[i + 6]) << 16 | Int(d[i + 7]) << 24
            i += 8
            guard i + len <= d.endIndex else { throw NetError.protocolError("truncated command set") }
            if group == 0 { c.elements[elem] = d.subdata(in: i..<(i + len)) }
            i += len
        }
        return c
    }

    // MARK: Builders

    public static func echoRQ(id: UInt16) -> DIMSECommand {
        var c = DIMSECommand()
        c.set(0x0002, uid: SOPClass.verification); c.field = CommandField.cEchoRQ.rawValue
        c.messageID = id; c.set(0x0800, u16: noDataSet)
        return c
    }

    public static func findRQ(id: UInt16, sopClass: String) -> DIMSECommand {
        var c = DIMSECommand()
        c.set(0x0002, uid: sopClass); c.field = CommandField.cFindRQ.rawValue
        c.messageID = id; c.set(0x0700, u16: 0); c.set(0x0800, u16: 0)
        return c
    }

    public static func moveRQ(id: UInt16, sopClass: String, destination: String) -> DIMSECommand {
        var c = DIMSECommand()
        c.set(0x0002, uid: sopClass); c.field = CommandField.cMoveRQ.rawValue
        c.messageID = id; c.set(0x0600, text: destination); c.set(0x0700, u16: 0); c.set(0x0800, u16: 0)
        return c
    }

    public static func getRQ(id: UInt16, sopClass: String) -> DIMSECommand {
        var c = DIMSECommand()
        c.set(0x0002, uid: sopClass); c.field = CommandField.cGetRQ.rawValue
        c.messageID = id; c.set(0x0700, u16: 0); c.set(0x0800, u16: 0)
        return c
    }

    public static func cancelRQ(respondingTo id: UInt16) -> DIMSECommand {
        var c = DIMSECommand()
        c.field = CommandField.cCancelRQ.rawValue; c.respondingTo = id; c.set(0x0800, u16: noDataSet)
        return c
    }

    public static func storeRQ(id: UInt16, sopClass: String, sopInstance: String, moveOriginator: (ae: String, id: UInt16)? = nil) -> DIMSECommand {
        var c = DIMSECommand()
        c.set(0x0002, uid: sopClass); c.field = CommandField.cStoreRQ.rawValue
        c.messageID = id; c.set(0x0700, u16: 0); c.set(0x0800, u16: 0)
        c.set(0x1000, uid: sopInstance)
        if let m = moveOriginator { c.set(0x1030, text: m.ae); c.set(0x1031, u16: m.id) }
        return c
    }

    public static func response(to rq: DIMSECommand, field: CommandField, status: UInt16, comment: String? = nil) -> DIMSECommand {
        var c = DIMSECommand()
        if let s = rq.affectedSOPClass { c.set(0x0002, uid: s) }
        c.field = field.rawValue
        c.respondingTo = rq.messageID
        c.set(0x0800, u16: noDataSet)
        c.set(0x0900, u16: status)
        if let i = rq.affectedSOPInstance { c.set(0x1000, uid: i) }
        if let comment { c.set(0x0902, text: String(comment.prefix(64))) }
        return c
    }
}

@inline(__always) func appendLE(_ d: inout Data, _ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
@inline(__always) func appendLE32(_ d: inout Data, _ v: UInt32) { appendLE(&d, UInt16(v & 0xFFFF)); appendLE(&d, UInt16(v >> 16)) }
