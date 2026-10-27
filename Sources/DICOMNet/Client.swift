import Foundation
import DICOMCore

/// A remote DICOM application entity (RadiAnt "PACS location").
public struct DICOMNode: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var description: String
    public var host: String
    public var port: Int
    public var aeTitle: String

    public init(description: String, host: String, port: Int, aeTitle: String) {
        self.description = description; self.host = host; self.port = port; self.aeTitle = aeTitle
    }
}

public enum QueryLevel: String, Sendable { case patient = "PATIENT", study = "STUDY", series = "SERIES", image = "IMAGE" }

public enum RetrieveProtocol: Int, Codable, CaseIterable, Sendable {
    case cMove = 0, cGet = 1
    public var title: String { self == .cMove ? "C-MOVE" : "C-GET" }
}

public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
}

/// Sub-operation counters of C-MOVE / C-GET.
public struct RetrieveProgress: Sendable {
    public var remaining = 0
    public var completed = 0
    public var failed = 0
    public var warnings = 0
    public var status: UInt16 = DIMSEStatus.pending
    public var bytes: Int64 = 0
    public var expected: Int { remaining + completed + failed + warnings }
    public var done: Bool { !DIMSEStatus.isPending(status) }
}

public struct StoreResult: Sendable {
    public var sent = 0
    public var failed = 0
    public var warnings = 0
    public var errors: [String] = []
}

/// A file received over the network (C-STORE in a C-GET or via the listener).
public struct ReceivedObject: Sendable {
    public var url: URL
    public var sopClassUID: String
    public var sopInstanceUID: String
    public var studyUID: String
    public var seriesUID: String
    public var callingAE: String
    public var byteCount: Int
    public var moveOriginatorMessageID: UInt16?
}

/// DICOM SCU for verification, query, retrieve and storage.
public final class DICOMClient: @unchecked Sendable {
    public let node: DICOMNode
    public let callingAE: String
    public var timeout: TimeInterval
    public var queryTimeout: TimeInterval
    public var proposed: ProposedTransferSyntaxes = .all

    public init(node: DICOMNode, callingAE: String, timeout: TimeInterval = 30, queryTimeout: TimeInterval = 30) {
        self.node = node
        self.callingAE = callingAE
        self.timeout = timeout
        self.queryTimeout = queryTimeout
    }

    private func associate(_ contexts: [PresentationContextProposal], roles: [RoleSelection] = []) throws -> Association {
        try Association.request(host: node.host, port: node.port, calledAE: node.aeTitle, callingAE: callingAE,
                                contexts: contexts, roles: roles, timeout: timeout)
    }

    private static let uncompressed = [TransferSyntaxUID.explicitLE, TransferSyntaxUID.implicitLE]

    // MARK: C-ECHO

    /// Verifies the node; returns round-trip time in seconds.
    @discardableResult
    public func echo() throws -> TimeInterval {
        let t0 = Date()
        let a = try associate([PresentationContextProposal(id: 1, abstractSyntax: SOPClass.verification, transferSyntaxes: [TransferSyntaxUID.implicitLE])])
        defer { a.release() }
        guard let ctx = a.contextID(for: SOPClass.verification) else { throw NetError.noPresentationContext("Verification") }
        try a.send(.echoRQ(id: a.makeMessageID()), context: ctx)
        let rsp = try a.receive()
        guard rsp.command.field == CommandField.cEchoRSP.rawValue else { throw NetError.protocolError("unexpected C-ECHO response") }
        if rsp.command.status != DIMSEStatus.success { throw NetError.protocolError(DIMSEStatus.describe(rsp.command.status)) }
        return Date().timeIntervalSince(t0)
    }

    // MARK: C-FIND

    /// Runs a C-FIND. `onMatch` is called for each pending response; return false to cancel.
    @discardableResult
    public func find(level: QueryLevel, keys: DataSet, cancel: CancelToken? = nil, onMatch: (DataSet) -> Void) throws -> Int {
        let a = try associate([
            PresentationContextProposal(id: 1, abstractSyntax: SOPClass.studyRootFind, transferSyntaxes: Self.uncompressed),
            PresentationContextProposal(id: 3, abstractSyntax: SOPClass.patientRootFind, transferSyntaxes: Self.uncompressed),
        ])
        defer { a.release() }
        let usePatientRoot = a.contextID(for: SOPClass.studyRootFind) == nil || level == .patient
        let sop = usePatientRoot ? SOPClass.patientRootFind : SOPClass.studyRootFind
        guard let ctx = a.contextID(for: sop) else { throw NetError.noPresentationContext("Query/Retrieve Find") }
        let ts = a.transferSyntax(of: ctx)
        let ident = keys.copy()
        ident.set(.queryRetrieveLevel, .CS, string: level.rawValue)
        let msgID = a.makeMessageID()
        a.socket.timeout = queryTimeout
        try a.send(.findRQ(id: msgID, sopClass: sop), dataSet: DICOMWriter.encode(ident, transferSyntax: ts), context: ctx)
        var count = 0
        var cancelSent = false
        while true {
            if let c = cancel, c.isCancelled, !cancelSent {
                try a.send(.cancelRQ(respondingTo: msgID), context: ctx)
                cancelSent = true
            }
            let m = try a.receive()
            guard m.command.field == CommandField.cFindRSP.rawValue else { continue }
            let st = m.command.status
            if DIMSEStatus.isPending(st), let d = m.dataSet {
                if let ds = try? DICOMFile.parseDataSet(d, transferSyntax: ts) { onMatch(ds); count += 1 }
                continue
            }
            if DIMSEStatus.isFailure(st) {
                throw NetError.protocolError(m.command.errorComment.map { "\(DIMSEStatus.describe(st)): \($0)" } ?? DIMSEStatus.describe(st))
            }
            return count
        }
    }

    // MARK: C-MOVE

    public func move(level: QueryLevel, keys: DataSet, destination: String, cancel: CancelToken? = nil,
                     progress: (RetrieveProgress) -> Void) throws -> RetrieveProgress {
        let a = try associate([
            PresentationContextProposal(id: 1, abstractSyntax: SOPClass.studyRootMove, transferSyntaxes: Self.uncompressed),
            PresentationContextProposal(id: 3, abstractSyntax: SOPClass.patientRootMove, transferSyntaxes: Self.uncompressed),
        ])
        defer { a.release() }
        let sop = a.contextID(for: SOPClass.studyRootMove) != nil ? SOPClass.studyRootMove : SOPClass.patientRootMove
        guard let ctx = a.contextID(for: sop) else { throw NetError.noPresentationContext("Query/Retrieve Move") }
        let ts = a.transferSyntax(of: ctx)
        let ident = keys.copy()
        ident.set(.queryRetrieveLevel, .CS, string: level.rawValue)
        let msgID = a.makeMessageID()
        try a.send(.moveRQ(id: msgID, sopClass: sop, destination: destination), dataSet: DICOMWriter.encode(ident, transferSyntax: ts), context: ctx)
        // Sub-operations can take a long time between responses.
        a.socket.timeout = max(timeout, 600)
        var p = RetrieveProgress()
        var cancelSent = false
        while true {
            if let c = cancel, c.isCancelled, !cancelSent {
                try a.send(.cancelRQ(respondingTo: msgID), context: ctx)
                cancelSent = true
            }
            let m = try a.receive()
            guard m.command.field == CommandField.cMoveRSP.rawValue else { continue }
            apply(m.command, to: &p)
            progress(p)
            if p.done {
                if DIMSEStatus.isFailure(p.status) && p.status != 0xA702 {
                    throw NetError.protocolError(m.command.errorComment.map { "\(DIMSEStatus.describe(p.status)): \($0)" } ?? DIMSEStatus.describe(p.status))
                }
                return p
            }
        }
    }

    private func apply(_ c: DIMSECommand, to p: inout RetrieveProgress) {
        p.status = c.status
        if let v = c.remaining { p.remaining = v }
        if let v = c.completed { p.completed = v }
        if let v = c.failed { p.failed = v }
        if let v = c.warnings { p.warnings = v }
        if !DIMSEStatus.isPending(c.status) { p.remaining = 0 }
    }

    // MARK: C-GET

    /// Retrieves over the same association; each received object is written by `store`, which returns the file URL.
    public func get(level: QueryLevel, keys: DataSet, cancel: CancelToken? = nil,
                    store: (Data, DIMSECommand, TransferSyntax, String) throws -> Void,
                    progress: (RetrieveProgress) -> Void) throws -> RetrieveProgress {
        var contexts = [
            PresentationContextProposal(id: 1, abstractSyntax: SOPClass.studyRootGet, transferSyntaxes: Self.uncompressed),
            PresentationContextProposal(id: 3, abstractSyntax: SOPClass.patientRootGet, transferSyntaxes: Self.uncompressed),
        ]
        var roles: [RoleSelection] = []
        var id: UInt8 = 5
        for sop in SOPClass.storage where id < 255 {
            contexts.append(PresentationContextProposal(id: id, abstractSyntax: sop, transferSyntaxes: proposed.uids(forSOPClass: sop)))
            roles.append(RoleSelection(sopClass: sop, scu: false, scp: true))
            id += 2
        }
        let a = try associate(contexts, roles: roles)
        defer { a.release() }
        let sop = a.contextID(for: SOPClass.studyRootGet) != nil ? SOPClass.studyRootGet : SOPClass.patientRootGet
        guard let ctx = a.contextID(for: sop) else { throw NetError.noPresentationContext("Query/Retrieve Get") }
        let ts = a.transferSyntax(of: ctx)
        let ident = keys.copy()
        ident.set(.queryRetrieveLevel, .CS, string: level.rawValue)
        let msgID = a.makeMessageID()
        try a.send(.getRQ(id: msgID, sopClass: sop), dataSet: DICOMWriter.encode(ident, transferSyntax: ts), context: ctx)
        a.socket.timeout = max(timeout, 600)
        var p = RetrieveProgress()
        var cancelSent = false
        while true {
            if let c = cancel, c.isCancelled, !cancelSent {
                try a.send(.cancelRQ(respondingTo: msgID), context: ctx)
                cancelSent = true
            }
            let m = try a.receive()
            switch CommandField(rawValue: m.command.field) {
            case .cStoreRQ:
                var status = DIMSEStatus.success
                var comment: String?
                if let d = m.dataSet {
                    do { try store(d, m.command, a.transferSyntax(of: m.contextID), a.calledAE) }
                    catch { status = 0xA700; comment = error.localizedDescription }
                } else { status = 0xA900 }
                p.bytes = a.bytesReceived
                try a.send(.response(to: m.command, field: .cStoreRSP, status: status, comment: comment), context: m.contextID)
            case .cGetRSP:
                apply(m.command, to: &p)
                p.bytes = a.bytesReceived
                progress(p)
                if p.done {
                    if DIMSEStatus.isFailure(p.status) && p.status != 0xA702 {
                        throw NetError.protocolError(m.command.errorComment.map { "\(DIMSEStatus.describe(p.status)): \($0)" } ?? DIMSEStatus.describe(p.status))
                    }
                    return p
                }
            default:
                continue
            }
        }
    }

    // MARK: C-STORE

    /// Sends files; `progress(index, total)` is called after each file.
    public func store(files: [URL], cancel: CancelToken? = nil, progress: (Int, Int) -> Void) throws -> StoreResult {
        struct Item { let url: URL; let sop: String; let inst: String; let ts: String }
        var items: [Item] = []
        var result = StoreResult()
        for u in files {
            guard let f = try? DICOMFile.read(url: u, options: .header),
                  let sop = f.dataSet.string(.sopClassUID) ?? f.fileMeta.string(.mediaStorageSOPClassUID),
                  let inst = f.dataSet.string(.sopInstanceUID) ?? f.fileMeta.string(.mediaStorageSOPInstanceUID) else {
                result.failed += 1; result.errors.append("\(u.lastPathComponent): not a DICOM object"); continue
            }
            items.append(Item(url: u, sop: sop, inst: inst, ts: f.transferSyntax.uid))
        }
        guard !items.isEmpty else { return result }

        // One context per (SOP class, native TS) plus an uncompressed fallback per SOP class.
        var contexts: [PresentationContextProposal] = []
        var id: UInt8 = 1
        var seen = Set<String>()
        for it in items {
            let exact = it.sop + "|" + it.ts
            if !seen.contains(exact), id < 255 {
                seen.insert(exact)
                contexts.append(PresentationContextProposal(id: id, abstractSyntax: it.sop, transferSyntaxes: [it.ts])); id += 2
            }
            let fb = it.sop + "|fallback"
            if !seen.contains(fb), id < 255 {
                seen.insert(fb)
                contexts.append(PresentationContextProposal(id: id, abstractSyntax: it.sop, transferSyntaxes: Self.uncompressed)); id += 2
            }
        }
        let a = try associate(contexts)
        defer { a.release() }
        for (i, it) in items.enumerated() {
            if cancel?.isCancelled == true { break }
            do {
                guard let ctx = a.contextID(for: it.sop, preferring: [it.ts, TransferSyntaxUID.explicitLE, TransferSyntaxUID.implicitLE]) else {
                    throw NetError.noPresentationContext(it.sop)
                }
                let target = a.transferSyntax(of: ctx)
                let file = try DICOMFile.read(url: it.url)
                let ds: DataSet = target.uid == it.ts || !file.transferSyntax.encapsulated ? file.dataSet : try Transcoder.decompressed(file)
                let body = DataSet(bigEndian: target.bigEndian)
                for e in ds.sortedElements where e.tag.group != 0x0002 { body.insert(e) }
                try a.send(.storeRQ(id: a.makeMessageID(), sopClass: it.sop, sopInstance: it.inst),
                           dataSet: DICOMWriter.encode(body, transferSyntax: target), context: ctx)
                var rsp: DIMSEMessage
                repeat { rsp = try a.receive() } while rsp.command.field != CommandField.cStoreRSP.rawValue
                let st = rsp.command.status
                if st == DIMSEStatus.success { result.sent += 1 }
                else if DIMSEStatus.isWarning(st) { result.warnings += 1; result.sent += 1 }
                else { result.failed += 1; result.errors.append("\(it.url.lastPathComponent): \(DIMSEStatus.describe(st))") }
            } catch let e as NetError {
                if case .noPresentationContext = e { result.failed += 1; result.errors.append("\(it.url.lastPathComponent): \(e.localizedDescription)") }
                else { throw e }
            } catch {
                result.failed += 1; result.errors.append("\(it.url.lastPathComponent): \(error.localizedDescription)")
            }
            progress(i + 1, items.count)
        }
        return result
    }
}

/// Writes a received data set as a Part 10 file and reads back its identifying UIDs.
public enum ReceivedObjectWriter {
    public static func write(_ dataSet: Data, sopClass: String, sopInstance: String, transferSyntax ts: TransferSyntax,
                             callingAE: String, under root: URL) throws -> ReceivedObject {
        var file = DICOMWriter.fileHeader(sopClassUID: sopClass, sopInstanceUID: sopInstance, transferSyntaxUID: ts.uid, sourceAE: callingAE)
        file.append(dataSet)
        let parsed = try DICOMFile.parse(file, options: .header)
        let study = parsed.dataSet.string(.studyInstanceUID) ?? "unknown"
        let series = parsed.dataSet.string(.seriesInstanceUID) ?? "unknown"
        let dir = root.appendingPathComponent(safe(study), isDirectory: true).appendingPathComponent(safe(series), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe(sopInstance) + ".dcm")
        try file.write(to: url, options: .atomic)
        return ReceivedObject(url: url, sopClassUID: sopClass, sopInstanceUID: sopInstance, studyUID: study, seriesUID: series,
                              callingAE: callingAE, byteCount: file.count, moveOriginatorMessageID: nil)
    }

    static func safe(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" }.prefix(64)) }
}
