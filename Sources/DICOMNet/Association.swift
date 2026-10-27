import Foundation
import DICOMCore

/// A received DIMSE message: command set plus optional data set (still encoded in the context's transfer syntax).
public struct DIMSEMessage {
    public var command: DIMSECommand
    public var contextID: UInt8
    public var dataSet: Data?
}

/// One DICOM association over TCP, used by both the SCU and the listener.
public final class Association: @unchecked Sendable {
    public struct Context: Sendable {
        public var abstractSyntax: String
        public var transferSyntax: String
    }

    let socket: TCPSocket
    public let callingAE: String
    public let calledAE: String
    public private(set) var contexts: [UInt8: Context] = [:]
    public private(set) var peerMaxPDU: Int = 0
    public private(set) var peerImplementation = ""
    public private(set) var acceptedRoles: [RoleSelection] = []
    public static let ourMaxPDU: UInt32 = 262_144
    public private(set) var bytesReceived: Int64 = 0
    public private(set) var bytesSent: Int64 = 0
    public var peerAddress: String { socket.peerAddress }
    private var pending: [PDV] = []
    private var nextID: UInt16 = 1
    private var isOpen = true

    init(socket: TCPSocket, callingAE: String, calledAE: String) {
        self.socket = socket
        self.callingAE = callingAE
        self.calledAE = calledAE
    }

    public func makeMessageID() -> UInt16 {
        defer { nextID = nextID &+ 1; if nextID == 0 { nextID = 1 } }
        return nextID
    }

    // MARK: Establishment

    /// Opens a connection and negotiates an association as SCU.
    public static func request(host: String, port: Int, calledAE: String, callingAE: String,
                               contexts: [PresentationContextProposal], roles: [RoleSelection] = [],
                               timeout: TimeInterval) throws -> Association {
        let s = try TCPSocket.connect(host: host, port: port, timeout: timeout)
        let a = Association(socket: s, callingAE: callingAE, calledAE: calledAE)
        var rq = AssociateRequest(calledAE: calledAE, callingAE: callingAE, contexts: contexts)
        rq.maxPDULength = ourMaxPDU
        rq.roles = roles
        do {
            try a.write(.associateRQ(rq))
            switch try PDU.read(from: s) {
            case .associateAC(let ac):
                a.peerMaxPDU = Int(ac.maxPDULength)
                a.peerImplementation = ac.implementationVersion
                a.acceptedRoles = ac.roles
                let byID = Dictionary(uniqueKeysWithValues: contexts.map { ($0.id, $0) })
                for r in ac.results where r.accepted {
                    if let p = byID[r.id] { a.contexts[r.id] = Context(abstractSyntax: p.abstractSyntax, transferSyntax: r.transferSyntax) }
                }
                return a
            case .associateRJ(let r, let src, let why):
                s.close()
                throw NetError.rejected(result: r, source: src, reason: why)
            case .abort(let src, let why):
                s.close()
                throw NetError.aborted(source: src, reason: why)
            default:
                s.close()
                throw NetError.protocolError("unexpected reply to A-ASSOCIATE-RQ")
            }
        } catch {
            s.close()
            throw error
        }
    }

    public enum AcceptDecision {
        case accept([PresentationContextResult], roles: [RoleSelection])
        case reject(result: Int, source: Int, reason: Int)
    }

    /// Reads an A-ASSOCIATE-RQ on an incoming socket and answers it.
    public static func accept(socket s: TCPSocket, decide: (AssociateRequest) -> AcceptDecision) throws -> Association {
        guard case .associateRQ(let rq) = try PDU.read(from: s) else {
            try? s.write(PDU.abort(source: 2, reason: 2).encode())
            s.close()
            throw NetError.protocolError("expected A-ASSOCIATE-RQ")
        }
        switch decide(rq) {
        case .reject(let r, let src, let why):
            try? s.write(PDU.associateRJ(result: r, source: src, reason: why).encode())
            s.close()
            throw NetError.rejected(result: r, source: src, reason: why)
        case .accept(let results, let roles):
            let a = Association(socket: s, callingAE: rq.callingAE, calledAE: rq.calledAE)
            a.peerMaxPDU = Int(rq.maxPDULength)
            a.peerImplementation = rq.implementationVersion
            a.acceptedRoles = roles
            let byID = Dictionary(uniqueKeysWithValues: rq.contexts.map { ($0.id, $0) })
            for r in results where r.accepted {
                if let p = byID[r.id] { a.contexts[r.id] = Context(abstractSyntax: p.abstractSyntax, transferSyntax: r.transferSyntax) }
            }
            let ac = AssociateAccept(calledAE: rq.calledAE, callingAE: rq.callingAE, results: results, maxPDULength: ourMaxPDU,
                                     implementationClassUID: UIDGenerator.implementationClassUID,
                                     implementationVersion: UIDGenerator.implementationVersionName, roles: roles)
            try a.write(.associateAC(ac))
            return a
        }
    }

    // MARK: Contexts

    /// First accepted context for an abstract syntax, preferring the given transfer syntaxes in order.
    public func contextID(for abstractSyntax: String, preferring ts: [String] = []) -> UInt8? {
        let matching = contexts.filter { $0.value.abstractSyntax == abstractSyntax }.sorted { $0.key < $1.key }
        for t in ts { if let m = matching.first(where: { $0.value.transferSyntax == t }) { return m.key } }
        return matching.first?.key
    }

    public func transferSyntax(of id: UInt8) -> TransferSyntax {
        TransferSyntax.resolve(contexts[id]?.transferSyntax ?? TransferSyntaxUID.implicitLE)
    }

    // MARK: Messages

    public func send(_ command: DIMSECommand, dataSet: Data? = nil, context id: UInt8) throws {
        var cmd = command
        cmd.set(0x0800, u16: dataSet == nil ? DIMSECommand.noDataSet : 0)
        let chunk = peerMaxPDU > 12 ? min(peerMaxPDU - 6, 4 << 20) : (1 << 20)
        try sendFragments(cmd.encode(), isCommand: true, context: id, chunk: chunk)
        if let d = dataSet { try sendFragments(d, isCommand: false, context: id, chunk: chunk) }
    }

    private func sendFragments(_ d: Data, isCommand: Bool, context id: UInt8, chunk: Int) throws {
        var offset = d.startIndex
        repeat {
            let end = min(offset + chunk, d.endIndex)
            let pdv = PDV(contextID: id, isCommand: isCommand, isLast: end == d.endIndex, data: d.subdata(in: offset..<end))
            try write(.data([pdv]))
            offset = end
        } while offset < d.endIndex
    }

    /// Receives the next complete DIMSE message. Answers A-RELEASE-RQ and throws `.closed`.
    public func receive() throws -> DIMSEMessage {
        var command = Data()
        var dataSet = Data()
        var cmd: DIMSECommand?
        var ctx: UInt8 = 0
        while true {
            let pdv = try nextPDV()
            ctx = pdv.contextID
            if pdv.isCommand {
                command.append(pdv.data)
                if pdv.isLast {
                    let c = try DIMSECommand.decode(command)
                    if !c.hasDataSet { return DIMSEMessage(command: c, contextID: ctx, dataSet: nil) }
                    cmd = c
                }
            } else {
                guard cmd != nil else { throw NetError.protocolError("data set before command") }
                dataSet.append(pdv.data)
                if pdv.isLast { return DIMSEMessage(command: cmd!, contextID: ctx, dataSet: dataSet) }
            }
        }
    }

    private func nextPDV() throws -> PDV {
        while pending.isEmpty {
            let pdu = try readPDU()
            switch pdu {
            case .data(let pdvs): pending = pdvs
            case .releaseRQ:
                try? write(.releaseRP)
                close()
                throw NetError.closed
            case .abort(let s, let r):
                close()
                throw NetError.aborted(source: s, reason: r)
            default:
                throw NetError.protocolError("unexpected PDU during data transfer")
            }
        }
        return pending.removeFirst()
    }

    // MARK: Teardown

    public func release() {
        guard isOpen else { return }
        do {
            try write(.releaseRQ)
            socket.timeout = min(socket.timeout, 10)
            // Peers may still send late data; wait for the RP.
            for _ in 0..<64 {
                if case .releaseRP = try readPDU() { break }
            }
        } catch {}
        close()
    }

    public func abort() {
        guard isOpen else { return }
        try? write(.abort(source: 0, reason: 0))
        close()
    }

    public func close() {
        isOpen = false
        socket.close()
    }

    /// Used by a server loop that handles A-RELEASE itself.
    public var isClosed: Bool { !isOpen }

    // MARK: Raw I/O

    private func write(_ p: PDU) throws {
        let d = p.encode()
        try socket.write(d)
        bytesSent += Int64(d.count)
    }

    private func readPDU() throws -> PDU {
        let p = try PDU.read(from: socket)
        if case .data(let pdvs) = p { bytesReceived += Int64(pdvs.reduce(0) { $0 + $1.data.count }) }
        return p
    }
}
