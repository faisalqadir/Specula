import Foundation

/// DICOM upper layer PDUs (PS3.8 section 9.3).
public enum PDUType: UInt8 {
    case associateRQ = 0x01, associateAC = 0x02, associateRJ = 0x03, dataTF = 0x04
    case releaseRQ = 0x05, releaseRP = 0x06, abort = 0x07
}

public let applicationContextUID = "1.2.840.10008.3.1.1.1"

public struct PresentationContextProposal: Sendable {
    public var id: UInt8
    public var abstractSyntax: String
    public var transferSyntaxes: [String]
    public init(id: UInt8, abstractSyntax: String, transferSyntaxes: [String]) {
        self.id = id; self.abstractSyntax = abstractSyntax; self.transferSyntaxes = transferSyntaxes
    }
}

public struct PresentationContextResult: Sendable {
    public var id: UInt8
    /// 0 acceptance, 1 user rejection, 2 no reason, 3 abstract syntax not supported, 4 transfer syntaxes not supported
    public var result: UInt8
    public var transferSyntax: String
    public var accepted: Bool { result == 0 }
}

public struct RoleSelection: Sendable {
    public var sopClass: String
    public var scu: Bool
    public var scp: Bool
}

public struct AssociateRequest: Sendable {
    public var calledAE: String
    public var callingAE: String
    public var contexts: [PresentationContextProposal]
    public var maxPDULength: UInt32 = 16384
    public var implementationClassUID = "1.2.826.0.1.3680043.10.1351.1"
    public var implementationVersion = "SPECULA_10"
    public var roles: [RoleSelection] = []
    public init(calledAE: String, callingAE: String, contexts: [PresentationContextProposal]) {
        self.calledAE = calledAE; self.callingAE = callingAE; self.contexts = contexts
    }
}

public struct AssociateAccept: Sendable {
    public var calledAE: String
    public var callingAE: String
    public var results: [PresentationContextResult]
    public var maxPDULength: UInt32
    public var implementationClassUID: String
    public var implementationVersion: String
    public var roles: [RoleSelection]
}

/// A presentation data value: one fragment of a command or data set.
public struct PDV {
    public var contextID: UInt8
    public var isCommand: Bool
    public var isLast: Bool
    public var data: Data
}

public enum PDU {
    case associateRQ(AssociateRequest)
    case associateAC(AssociateAccept)
    case associateRJ(result: Int, source: Int, reason: Int)
    case data([PDV])
    case releaseRQ
    case releaseRP
    case abort(source: Int, reason: Int)
}

// MARK: - Encoding

struct ByteWriter {
    var d = Data()
    mutating func u8(_ v: UInt8) { d.append(v) }
    mutating func u16(_ v: UInt16) { d.append(UInt8(v >> 8)); d.append(UInt8(v & 0xFF)) }
    mutating func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xFFFF)) }
    mutating func bytes(_ b: Data) { d.append(b) }
    mutating func ae(_ s: String) {
        var b = Array(s.utf8.prefix(16))
        while b.count < 16 { b.append(0x20) }
        d.append(contentsOf: b)
    }
    mutating func item(_ type: UInt8, _ body: Data) {
        u8(type); u8(0); u16(UInt16(body.count)); bytes(body)
    }
    mutating func uidItem(_ type: UInt8, _ uid: String) { item(type, Data(uid.utf8)) }
}

extension PDU {
    public func encode() -> Data {
        var w = ByteWriter()
        switch self {
        case .associateRQ(let rq):
            var b = ByteWriter()
            b.u16(1); b.u16(0); b.ae(rq.calledAE); b.ae(rq.callingAE); b.bytes(Data(count: 32))
            b.uidItem(0x10, applicationContextUID)
            for pc in rq.contexts {
                var p = ByteWriter()
                p.u8(pc.id); p.u8(0); p.u8(0); p.u8(0)
                p.uidItem(0x30, pc.abstractSyntax)
                for ts in pc.transferSyntaxes { p.uidItem(0x40, ts) }
                b.item(0x20, p.d)
            }
            b.item(0x50, Self.userInfo(maxPDU: rq.maxPDULength, impl: rq.implementationClassUID, version: rq.implementationVersion, roles: rq.roles))
            w.u8(PDUType.associateRQ.rawValue); w.u8(0); w.u32(UInt32(b.d.count)); w.bytes(b.d)
        case .associateAC(let ac):
            var b = ByteWriter()
            b.u16(1); b.u16(0); b.ae(ac.calledAE); b.ae(ac.callingAE); b.bytes(Data(count: 32))
            b.uidItem(0x10, applicationContextUID)
            for r in ac.results {
                var p = ByteWriter()
                p.u8(r.id); p.u8(0); p.u8(r.result); p.u8(0)
                p.uidItem(0x40, r.accepted ? r.transferSyntax : TransferSyntaxUID.implicitLE)
                b.item(0x21, p.d)
            }
            b.item(0x50, Self.userInfo(maxPDU: ac.maxPDULength, impl: ac.implementationClassUID, version: ac.implementationVersion, roles: ac.roles))
            w.u8(PDUType.associateAC.rawValue); w.u8(0); w.u32(UInt32(b.d.count)); w.bytes(b.d)
        case .associateRJ(let result, let source, let reason):
            w.u8(PDUType.associateRJ.rawValue); w.u8(0); w.u32(4)
            w.u8(0); w.u8(UInt8(result)); w.u8(UInt8(source)); w.u8(UInt8(reason))
        case .data(let pdvs):
            var b = ByteWriter()
            for v in pdvs {
                b.u32(UInt32(v.data.count + 2))
                b.u8(v.contextID)
                b.u8((v.isCommand ? 1 : 0) | (v.isLast ? 2 : 0))
                b.bytes(v.data)
            }
            w.u8(PDUType.dataTF.rawValue); w.u8(0); w.u32(UInt32(b.d.count)); w.bytes(b.d)
        case .releaseRQ:
            w.u8(PDUType.releaseRQ.rawValue); w.u8(0); w.u32(4); w.u32(0)
        case .releaseRP:
            w.u8(PDUType.releaseRP.rawValue); w.u8(0); w.u32(4); w.u32(0)
        case .abort(let source, let reason):
            w.u8(PDUType.abort.rawValue); w.u8(0); w.u32(4)
            w.u8(0); w.u8(0); w.u8(UInt8(source)); w.u8(UInt8(reason))
        }
        return w.d
    }

    static func userInfo(maxPDU: UInt32, impl: String, version: String, roles: [RoleSelection]) -> Data {
        var u = ByteWriter()
        var m = ByteWriter(); m.u32(maxPDU)
        u.item(0x51, m.d)
        u.uidItem(0x52, impl)
        for r in roles {
            var b = ByteWriter()
            let uid = Data(r.sopClass.utf8)
            b.u16(UInt16(uid.count)); b.bytes(uid); b.u8(r.scu ? 1 : 0); b.u8(r.scp ? 1 : 0)
            u.item(0x54, b.d)
        }
        u.uidItem(0x55, String(version.prefix(16)))
        return u.d
    }
}

// MARK: - Decoding

struct ByteReader {
    let d: Data
    var pos: Int
    init(_ d: Data) { self.d = d; pos = d.startIndex }
    var remaining: Int { d.endIndex - pos }
    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw NetError.protocolError("truncated PDU") }
        defer { pos += 1 }
        return d[pos]
    }
    mutating func u16() throws -> UInt16 { (UInt16(try u8()) << 8) | UInt16(try u8()) }
    mutating func u32() throws -> UInt32 { (UInt32(try u16()) << 16) | UInt32(try u16()) }
    mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw NetError.protocolError("truncated PDU") }
        defer { pos += n }
        return d.subdata(in: pos..<(pos + n))
    }
    mutating func skip(_ n: Int) throws { _ = try take(n) }
}

func uidString(_ d: Data) -> String {
    String(decoding: d, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
}

extension PDU {
    /// Reads one complete PDU from the socket.
    static func read(from s: TCPSocket, maxLength: Int = 64 << 20) throws -> PDU {
        let head = try s.read(exactly: 6)
        let type = head[head.startIndex]
        let len = Int(head[head.startIndex + 2]) << 24 | Int(head[head.startIndex + 3]) << 16 | Int(head[head.startIndex + 4]) << 8 | Int(head[head.startIndex + 5])
        guard len <= maxLength else { throw NetError.protocolError("PDU too large (\(len) bytes)") }
        let body = try s.read(exactly: len)
        return try decode(type: type, body: body)
    }

    static func decode(type: UInt8, body: Data) throws -> PDU {
        var r = ByteReader(body)
        switch PDUType(rawValue: type) {
        case .associateRQ, .associateAC:
            _ = try r.u16(); try r.skip(2)
            let called = String(decoding: try r.take(16), as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let calling = String(decoding: try r.take(16), as: UTF8.self).trimmingCharacters(in: .whitespaces)
            try r.skip(32)
            var proposals: [PresentationContextProposal] = []
            var results: [PresentationContextResult] = []
            var maxPDU: UInt32 = 0
            var impl = "", version = ""
            var roles: [RoleSelection] = []
            while r.remaining >= 4 {
                let it = try r.u8(); try r.skip(1)
                let n = Int(try r.u16())
                var sub = ByteReader(try r.take(n))
                switch it {
                case 0x20, 0x21:
                    let id = try sub.u8(); try sub.skip(1); let res = try sub.u8(); try sub.skip(1)
                    var abstract = ""; var tss: [String] = []
                    while sub.remaining >= 4 {
                        let st = try sub.u8(); try sub.skip(1)
                        let sn = Int(try sub.u16())
                        let v = uidString(try sub.take(sn))
                        if st == 0x30 { abstract = v } else if st == 0x40 { tss.append(v) }
                    }
                    if it == 0x20 { proposals.append(PresentationContextProposal(id: id, abstractSyntax: abstract, transferSyntaxes: tss)) }
                    else { results.append(PresentationContextResult(id: id, result: res, transferSyntax: tss.first ?? "")) }
                case 0x50:
                    while sub.remaining >= 4 {
                        let st = try sub.u8(); try sub.skip(1)
                        let sn = Int(try sub.u16())
                        var v = ByteReader(try sub.take(sn))
                        switch st {
                        case 0x51: maxPDU = (try? v.u32()) ?? 0
                        case 0x52: impl = uidString(v.d)
                        case 0x55: version = uidString(v.d)
                        case 0x54:
                            let ul = Int(try v.u16())
                            let uid = uidString(try v.take(ul))
                            let scu = try v.u8(), scp = try v.u8()
                            roles.append(RoleSelection(sopClass: uid, scu: scu == 1, scp: scp == 1))
                        default: break
                        }
                    }
                default: break
                }
            }
            if type == PDUType.associateRQ.rawValue {
                var rq = AssociateRequest(calledAE: called, callingAE: calling, contexts: proposals)
                rq.maxPDULength = maxPDU; rq.implementationClassUID = impl; rq.implementationVersion = version; rq.roles = roles
                return .associateRQ(rq)
            }
            return .associateAC(AssociateAccept(calledAE: called, callingAE: calling, results: results, maxPDULength: maxPDU, implementationClassUID: impl, implementationVersion: version, roles: roles))
        case .associateRJ:
            try r.skip(1)
            return .associateRJ(result: Int(try r.u8()), source: Int(try r.u8()), reason: Int(try r.u8()))
        case .dataTF:
            var pdvs: [PDV] = []
            while r.remaining >= 6 {
                let n = Int(try r.u32())
                guard n >= 2 else { throw NetError.protocolError("bad PDV length") }
                let id = try r.u8(), hdr = try r.u8()
                pdvs.append(PDV(contextID: id, isCommand: hdr & 1 == 1, isLast: hdr & 2 == 2, data: try r.take(n - 2)))
            }
            return .data(pdvs)
        case .releaseRQ: return .releaseRQ
        case .releaseRP: return .releaseRP
        case .abort:
            try r.skip(2)
            return .abort(source: Int(try r.u8()), reason: Int(try r.u8()))
        case nil:
            throw NetError.protocolError(String(format: "unknown PDU type 0x%02X", type))
        }
    }
}
