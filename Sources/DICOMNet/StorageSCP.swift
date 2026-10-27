import Foundation
import DICOMCore

/// The PACS listener: a Storage and Verification SCP that receives C-MOVE sub-operations and pushed studies.
public final class StorageSCP: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var aeTitle: String
        public var port: Int
        public var storageRoot: URL
        /// Accept any proposed abstract syntax (RadiAnt "Accept all Presentation Contexts").
        public var acceptAllContexts = false
        /// Transfer syntax chosen when the peer proposes it (RadiAnt "Preferred transfer syntax").
        public var preferredTransferSyntax: String?
        public var timeout: TimeInterval = 60
        public var loopbackOnly = false
        public init(aeTitle: String, port: Int, storageRoot: URL) {
            self.aeTitle = aeTitle; self.port = port; self.storageRoot = storageRoot
        }
    }

    public let configuration: Configuration
    /// Decides whether a peer (IP address, calling AE) may connect.
    public var admit: (@Sendable (String, String) -> Bool)?
    public var onReceive: (@Sendable (ReceivedObject) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    private var listener: TCPListener?
    private let lock = NSLock()
    private var active: [ObjectIdentifier: Association] = [:]
    public private(set) var isRunning = false

    public init(configuration: Configuration) { self.configuration = configuration }

    public func start() throws {
        let l = try TCPListener(port: configuration.port, loopbackOnly: configuration.loopbackOnly)
        listener = l
        isRunning = true
        let t = Thread { [weak self] in self?.acceptLoop(l) }
        t.name = "DICOM listener :\(configuration.port)"
        t.start()
    }

    public func stop() {
        isRunning = false
        listener?.stop()
        listener = nil
        lock.lock(); let open = Array(active.values); active.removeAll(); lock.unlock()
        open.forEach { $0.abort() }
    }

    private func acceptLoop(_ l: TCPListener) {
        while let s = l.accept(timeout: configuration.timeout) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve(s) }
        }
    }

    // MARK: Negotiation

    static let acceptableTransferSyntaxes: Set<String> = {
        var s = Set<String>()
        let all: [TransferSyntax] = [.implicitVRLittleEndian, .explicitVRLittleEndian, .deflatedExplicitVRLittleEndian, .explicitVRBigEndian,
                                     .rleLossless, .jpegBaseline, .jpegExtended, .jpegLosslessP14, .jpegLosslessSV1, .jpegLSLossless,
                                     .jpegLSNearLossless, .jpeg2000Lossless, .jpeg2000, .jpeg2000MCLossless, .jpeg2000MC,
                                     .mpeg2MPML, .mpeg2MPHL, .mpeg4HP41, .mpeg4HP41BD, .mpeg4HP42_2D, .mpeg4HP42_3D, .mpeg4StereoHP42, .hevcMP51]
        for t in all { s.insert(t.uid) }
        return s
    }()

    static let storageSet = Set(SOPClass.storage)
    static let queryRetrieve: Set<String> = [SOPClass.patientRootFind, SOPClass.patientRootMove, SOPClass.patientRootGet,
                                             SOPClass.studyRootFind, SOPClass.studyRootMove, SOPClass.studyRootGet]

    func negotiate(_ rq: AssociateRequest) -> [PresentationContextResult] {
        rq.contexts.map { pc in
            let abstract = pc.abstractSyntax
            let supported = abstract == SOPClass.verification || Self.storageSet.contains(abstract)
                || (configuration.acceptAllContexts && !Self.queryRetrieve.contains(abstract))
            guard supported else { return PresentationContextResult(id: pc.id, result: 3, transferSyntax: "") }
            if let p = configuration.preferredTransferSyntax, pc.transferSyntaxes.contains(p) {
                return PresentationContextResult(id: pc.id, result: 0, transferSyntax: p)
            }
            if let t = pc.transferSyntaxes.first(where: { Self.acceptableTransferSyntaxes.contains($0) }) {
                return PresentationContextResult(id: pc.id, result: 0, transferSyntax: t)
            }
            return PresentationContextResult(id: pc.id, result: 4, transferSyntax: "")
        }
    }

    // MARK: Serving

    private func serve(_ s: TCPSocket) {
        let peer = s.peerAddress
        let a: Association
        do {
            a = try Association.accept(socket: s) { rq in
                if let admit = self.admit, !admit(peer, rq.callingAE) {
                    self.onLog?("Rejected \(rq.callingAE) from \(peer)")
                    return .reject(result: 1, source: 1, reason: 3)
                }
                return .accept(self.negotiate(rq), roles: [])
            }
        } catch {
            onLog?("Association from \(peer) failed: \(error.localizedDescription)")
            return
        }
        lock.lock(); active[ObjectIdentifier(a)] = a; lock.unlock()
        defer { lock.lock(); active[ObjectIdentifier(a)] = nil; lock.unlock() }
        onLog?("Association from \(a.callingAE) (\(peer))")
        while true {
            let m: DIMSEMessage
            do { m = try a.receive() } catch {
                if case NetError.closed = error {} else { onLog?("Association ended: \(error.localizedDescription)") }
                a.close()
                return
            }
            do {
                switch CommandField(rawValue: m.command.field) {
                case .cEchoRQ:
                    try a.send(.response(to: m.command, field: .cEchoRSP, status: DIMSEStatus.success), context: m.contextID)
                case .cStoreRQ:
                    var status = DIMSEStatus.success
                    var comment: String?
                    if let d = m.dataSet {
                        do {
                            var obj = try ReceivedObjectWriter.write(d, sopClass: m.command.affectedSOPClass ?? "", sopInstance: m.command.affectedSOPInstance ?? UIDGenerator.make(),
                                                                   transferSyntax: a.transferSyntax(of: m.contextID), callingAE: a.callingAE, under: configuration.storageRoot)
                            obj.moveOriginatorMessageID = m.command.u16(0x1031)
                            onReceive?(obj)
                        } catch {
                            status = 0xA700; comment = error.localizedDescription
                        }
                    } else { status = 0xA900 }
                    try a.send(.response(to: m.command, field: .cStoreRSP, status: status, comment: comment), context: m.contextID)
                default:
                    var rsp = DIMSECommand.response(to: m.command, field: .cEchoRSP, status: 0x0211)
                    rsp.field = m.command.field | 0x8000
                    try a.send(rsp, context: m.contextID)
                }
            } catch {
                a.abort()
                return
            }
        }
    }
}
