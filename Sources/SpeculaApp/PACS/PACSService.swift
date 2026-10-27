import AppKit
import DICOMCore
import DICOMNet

/// A study found on a PACS location.
struct PACSStudy: Identifiable, Hashable {
    var id: String { node.id.uuidString + "|" + studyUID }
    let node: DICOMNode
    let studyUID: String
    var patientName = ""
    var patientID = ""
    var birthDate = ""
    var sex = ""
    var studyDate = ""
    var studyTime = ""
    var modalities = ""
    var studyDescription = ""
    var accession = ""
    var studyID = ""
    var referring = ""
    var reading = ""
    var institution = ""
    var images = 0
    var seriesCount = 0

    var dateTime: Date? { DICOMDate.date(da: studyDate, tm: studyTime) }
    var dateDisplay: String {
        let d = DICOMDate.formatDate(studyDate)
        let t = DICOMDate.formatTime(studyTime)
        return t.isEmpty ? d : d + " " + t
    }
    var imagesDisplay: String { images > 0 ? String(images) : "" }
    var source: String { node.description }

    static func == (a: PACSStudy, b: PACSStudy) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct PACSSeries: Identifiable, Hashable {
    var id: String { seriesUID }
    let seriesUID: String
    var number = ""
    var modality = ""
    var seriesDescription = ""
    var images = 0
    var bodyPart = ""
}

/// Filters of the PACS search window.
struct PACSQuery {
    var patientName = ""
    var patientID = ""
    var accession = ""
    var studyDescription = ""
    var referring = ""
    var performing = ""
    var reading = ""
    var institution = ""
    var datePreset = DatePreset.all
    var customFrom = Date()
    var customTo = Date()
    var modalities: Set<String> = []

    var isEmpty: Bool {
        [patientName, patientID, accession, studyDescription, referring, performing, reading, institution].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            && datePreset == .all && modalities.isEmpty
    }
}

enum DownloadTarget: Equatable {
    case libraryOnly
    case window(ObjectIdentifier?)
    case newWindow(UUID)
    case separateWindow
}

/// One retrieve job shown in "PACS downloads".
final class PACSDownload: ObservableObject, Identifiable {
    enum State: String {
        case queued = "Queued", waiting = "Waiting", connecting = "Connecting", downloading = "Downloading"
        case finished = "Finished", warning = "Warning", error = "Error", cancelled = "Cancelled"
        var isActive: Bool { self == .queued || self == .waiting || self == .connecting || self == .downloading }
    }

    let id = UUID()
    let study: PACSStudy
    let series: [PACSSeries]
    let target: DownloadTarget
    let pushed: Bool
    let cancelToken = CancelToken()
    @Published var state = State.queued
    @Published var received = 0
    @Published var expected = 0
    @Published var bytes: Int64 = 0
    @Published var started: Date?
    @Published var ended: Date?
    @Published var error = ""
    @Published var currentSpeed = 0.0
    var files: [URL] = []
    var unopened: [URL] = []
    var lastBytes: Int64 = 0
    var lastActivity = Date()

    init(study: PACSStudy, series: [PACSSeries], target: DownloadTarget, pushed: Bool = false) {
        self.study = study; self.series = series; self.target = target; self.pushed = pushed
    }

    var title: String {
        let name = study.patientName.isEmpty ? "Unknown patient" : study.patientName
        let date = DICOMDate.formatDate(study.studyDate)
        return date.isEmpty ? name : "\(name) (\(date))"
    }
    var progress: Double { expected > 0 ? min(1, Double(received) / Double(expected)) : (state == .finished ? 1 : 0) }
    var elapsed: TimeInterval { started.map { (ended ?? Date()).timeIntervalSince($0) } ?? 0 }
    var averageSpeed: Double { elapsed > 0 ? Double(bytes) / elapsed : 0 }
}

/// Owns the PACS configuration, the listener (Storage SCP) and the download queue.
final class PACSService: ObservableObject {
    static let shared = PACSService()

    @Published var configuration = PACSConfiguration.load() {
        didSet {
            guard configuration != oldValue else { return }
            configuration.save()
            queue.maxConcurrentOperationCount = max(1, configuration.maxActiveDownloads)
            let l = { (c: PACSConfiguration) in [String(c.listenerPort), c.aeTitle, String(c.acceptAllContexts), c.preferredTransferSyntax, String(c.acceptConnections.rawValue), c.nodes.map(\.host).joined()] }
            if l(configuration) != l(oldValue) { restartListener() }
        }
    }
    @Published private(set) var downloads: [PACSDownload] = []
    @Published private(set) var listenerStatus = "Listener stopped"
    @Published private(set) var listenerError: String?

    private var scp: StorageSCP?
    private let queue = OperationQueue()
    private var allowedIPs: Set<String> = []
    private var lockedPause = false
    private var timer: Timer?
    private var windows: [UUID: WeakViewer] = [:]
    private var pushedByStudy: [String: PACSDownload] = [:]

    struct WeakViewer { weak var wc: ViewerWindowController? }

    static let storageRoot: URL = DICOMLoader.tempRoot.appendingPathComponent("PACS", isDirectory: true)

    private init() {
        queue.maxConcurrentOperationCount = max(1, configuration.maxActiveDownloads)
        queue.qualityOfService = .userInitiated
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self, self.configuration.pauseListenerOnLock, self.scp != nil else { return }
            self.lockedPause = true
            self.stopListener()
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self, self.lockedPause else { return }
            self.lockedPause = false
            self.startListenerIfConfigured()
        }
    }

    func client(for node: DICOMNode) -> DICOMClient {
        let c = DICOMClient(node: node, callingAE: configuration.aeTitle, timeout: configuration.timeout, queryTimeout: configuration.queryTimeout)
        c.proposed = configuration.proposedTransferSyntaxes
        return c
    }

    // MARK: - Listener

    func startListenerIfConfigured() {
        guard !configuration.nodes.isEmpty else { listenerStatus = "Listener stopped (no PACS locations)"; return }
        startListener()
    }

    func startListener() {
        stopListener()
        let c = configuration
        var cfg = StorageSCP.Configuration(aeTitle: c.aeTitle, port: c.listenerPort, storageRoot: Self.storageRoot)
        cfg.acceptAllContexts = c.acceptAllContexts
        cfg.preferredTransferSyntax = c.preferredTransferSyntax.isEmpty ? nil : c.preferredTransferSyntax
        cfg.timeout = max(30, c.timeout)
        cfg.loopbackOnly = c.acceptConnections == .thisComputer
        let s = StorageSCP(configuration: cfg)
        resolveAllowedHosts()
        let mode = c.acceptConnections
        s.admit = { [weak self] ip, _ in
            switch mode {
            case .all, .thisComputer: return true
            case .localNetwork: return PeerAddress.isLocalNetwork(ip)
            case .definedHostsOnly:
                if ip == "127.0.0.1" || ip == "::1" { return true }
                return self?.isAllowed(ip) ?? false
            }
        }
        s.onReceive = { [weak self] obj in DispatchQueue.main.async { self?.received(obj) } }
        do {
            try s.start()
            scp = s
            listenerError = nil
            listenerStatus = "Listening as \(c.aeTitle) on port \(c.listenerPort)"
        } catch {
            listenerError = "PACS listener could not be started on port \(c.listenerPort)"
            listenerStatus = listenerError! + " (\(error.localizedDescription))"
        }
    }

    func stopListener() {
        scp?.stop()
        scp = nil
        listenerStatus = lockedPause ? "Listener paused (session locked)" : "Listener stopped"
    }

    func restartListener() {
        if scp != nil || !configuration.nodes.isEmpty { startListener() }
    }

    var isListening: Bool { scp != nil }

    private let ipLock = NSLock()
    private func isAllowed(_ ip: String) -> Bool { ipLock.lock(); defer { ipLock.unlock() }; return allowedIPs.contains(ip) }

    /// Resolves PACS host names so "Defined PACS hosts only" can compare peer IP addresses.
    private func resolveAllowedHosts() {
        let hosts = configuration.nodes.map(\.host)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var ips = Set<String>()
            for h in hosts {
                ips.insert(h)
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(h, nil, nil, &res) == 0, let first = res else { continue }
                var p: UnsafeMutablePointer<addrinfo>? = first
                while let a = p {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(a.pointee.ai_addr, a.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 { ips.insert(String(cString: buf)) }
                    p = a.pointee.ai_next
                }
                freeaddrinfo(first)
            }
            guard let self else { return }
            self.ipLock.lock(); self.allowedIPs = ips; self.ipLock.unlock()
        }
    }

    // MARK: - Search

    /// Matching value with the configured wildcard / caret / non-ASCII rules.
    func matchValue(_ raw: String, personName: Bool = false) -> String {
        var v = raw.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return "" }
        let c = configuration
        if personName && c.spacesToCarets {
            v = v.split(separator: " ", omittingEmptySubsequences: true).joined(separator: "^")
        }
        if c.nonASCIIToWildcards { v = String(v.map { $0.isASCII ? $0 : "?" }) }
        if !v.contains("*") && !v.contains("?") {
            switch c.wildcards {
            case .none: break
            case .leading: v = "*" + v
            case .trailing: v += "*"
            case .both: v = "*" + v + "*"
            }
        }
        return v
    }

    private func encode(_ s: String, vr: VR, charset: QueryCharacterSet) -> Data {
        var d = s.data(using: charset.encoding, allowLossyConversion: true) ?? Data(s.utf8)
        if d.count % 2 == 1 { d.append(vr.paddingByte) }
        return d
    }

    /// Builds the study-level identifier for one modality (or none).
    func studyKeys(_ q: PACSQuery, modality: String?) -> (DataSet, (Date, Date)?) {
        let ds = DataSet()
        var values: [(Tag, VR, String)] = [
            (.patientName, .PN, matchValue(q.patientName, personName: true)),
            (.patientID, .LO, matchValue(q.patientID)),
            (.patientBirthDate, .DA, ""),
            (Tag(0x0010, 0x0040), .CS, ""),
            (.studyDate, .DA, ""),
            (.studyTime, .TM, ""),
            (.accessionNumber, .SH, matchValue(q.accession)),
            (.studyID, .SH, ""),
            (.studyDescription, .LO, matchValue(q.studyDescription)),
            (.modalitiesInStudy, .CS, modality ?? ""),
            (.referringPhysicianName, .PN, matchValue(q.referring, personName: true)),
            (Tag(0x0008, 0x1060), .PN, matchValue(q.reading, personName: true)),
            (Tag(0x0020, 0x1206), .IS, ""),
            (Tag(0x0020, 0x1208), .IS, ""),
            (.studyInstanceUID, .UI, ""),
        ]
        if !q.performing.trimmingCharacters(in: .whitespaces).isEmpty { values.append((Tag(0x0008, 0x1050), .PN, matchValue(q.performing, personName: true))) }
        if !q.institution.trimmingCharacters(in: .whitespaces).isEmpty { values.append((.institutionName, .LO, matchValue(q.institution))) }

        let interval = q.datePreset.interval(custom: (q.customFrom, q.customTo))
        if let (from, to) = interval {
            let cal = Calendar.current
            let d1 = DICOMDate.dicomDate(from), d2 = DICOMDate.dicomDate(to)
            if cal.isDate(from, inSameDayAs: to) {
                values[4].2 = d1
                let fullDay = from == cal.startOfDay(for: from) && to >= cal.startOfDay(for: from).addingTimeInterval(86399)
                if !fullDay { values[5].2 = DICOMDate.dicomTime(from) + "-" + DICOMDate.dicomTime(to) }
            } else {
                values[4].2 = d1 + "-" + d2
            }
        }

        let nonASCII = values.contains { !$0.2.allSatisfy(\.isASCII) }
        let charset: QueryCharacterSet = configuration.characterSet != .automatic ? configuration.characterSet : (nonASCII ? .utf8 : .automatic)
        if charset != .automatic { ds.set(.specificCharacterSet, .CS, string: charset.rawValue) }
        for (tag, vr, v) in values { ds.set(tag, vr, data: encode(v, vr: vr, charset: charset)) }
        return (ds, interval)
    }

    private func study(from ds: DataSet, node: DICOMNode) -> PACSStudy? {
        if configuration.forceCharacterSet && configuration.characterSet != .automatic {
            ds.set(.specificCharacterSet, .CS, string: configuration.characterSet.rawValue)
        }
        guard let uid = ds.string(.studyInstanceUID), !uid.isEmpty else { return nil }
        var s = PACSStudy(node: node, studyUID: uid)
        s.patientName = PersonName.display(ds.string(.patientName))
        s.patientID = ds.string(.patientID) ?? ""
        s.birthDate = ds.string(.patientBirthDate) ?? ""
        s.sex = ds.string(Tag(0x0010, 0x0040)) ?? ""
        s.studyDate = ds.string(.studyDate) ?? ""
        s.studyTime = ds.string(.studyTime) ?? ""
        s.modalities = ds.strings(.modalitiesInStudy).joined(separator: ", ")
        s.studyDescription = ds.string(.studyDescription) ?? ""
        s.accession = ds.string(.accessionNumber) ?? ""
        s.studyID = ds.string(.studyID) ?? ""
        s.referring = PersonName.display(ds.string(.referringPhysicianName))
        s.reading = PersonName.display(ds.string(Tag(0x0008, 0x1060)))
        s.institution = ds.string(.institutionName) ?? ""
        s.images = ds.int(Tag(0x0020, 0x1208)) ?? 0
        s.seriesCount = ds.int(Tag(0x0020, 0x1206)) ?? 0
        return s
    }

    /// Queries the nodes in parallel. `update` delivers the merged result list on the main thread.
    func search(_ q: PACSQuery, nodes: [DICOMNode], cancel: CancelToken,
                update: @escaping ([PACSStudy]) -> Void, completion: @escaping ([String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var byID: [String: PACSStudy] = [:]
        var order: [String] = []
        var errors: [String] = []
        let modalities: [String?] = q.modalities.isEmpty ? [nil] : q.modalities.sorted().map { Optional($0) }
        for node in nodes {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let client = self.client(for: node)
                for m in modalities {
                    if cancel.isCancelled { return }
                    let (keys, interval) = self.studyKeys(q, modality: m)
                    do {
                        try client.find(level: .study, keys: keys, cancel: cancel) { ds in
                            guard var s = self.study(from: ds, node: node) else { return }
                            if let (from, to) = interval, let dt = s.dateTime, !s.studyTime.isEmpty, dt < from || dt > to { return }
                            lock.lock()
                            if let old = byID[s.id] {
                                // Some archives answer once per series or instance; merge
                                if s.modalities.isEmpty { s.modalities = old.modalities }
                                else if !old.modalities.isEmpty && !old.modalities.contains(s.modalities) { s.modalities = old.modalities + ", " + s.modalities }
                                s.images = max(s.images, old.images)
                            } else { order.append(s.id) }
                            byID[s.id] = s
                            let snapshot = order.compactMap { byID[$0] }
                            lock.unlock()
                            DispatchQueue.main.async { update(snapshot) }
                        }
                    } catch {
                        lock.lock(); errors.append("\(node.description): \(error.localizedDescription)"); lock.unlock()
                        return
                    }
                }
            }
        }
        group.notify(queue: .main) { completion(errors) }
    }

    func series(of study: PACSStudy, completion: @escaping (Result<[PACSSeries], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let keys = DataSet()
            keys.set(.studyInstanceUID, .UI, string: study.studyUID)
            for (t, vr) in [(Tag.seriesInstanceUID, VR.UI), (.seriesNumber, .IS), (.modality, .CS), (.seriesDescription, .LO), (Tag(0x0020, 0x1209), .IS), (Tag(0x0018, 0x0015), .CS)] {
                keys.set(t, vr, string: "")
            }
            var list: [PACSSeries] = []
            var seen = Set<String>()
            do {
                try self.client(for: study.node).find(level: .series, keys: keys) { ds in
                    guard let uid = ds.string(.seriesInstanceUID), seen.insert(uid).inserted else { return }
                    var s = PACSSeries(seriesUID: uid)
                    s.number = ds.string(.seriesNumber) ?? ""
                    s.modality = ds.string(.modality) ?? ""
                    s.seriesDescription = ds.string(.seriesDescription) ?? ""
                    s.images = ds.int(Tag(0x0020, 0x1209)) ?? 0
                    s.bodyPart = ds.string(Tag(0x0018, 0x0015)) ?? ""
                    list.append(s)
                }
                list.sort { (Int($0.number) ?? 0) < (Int($1.number) ?? 0) }
                DispatchQueue.main.async { completion(.success(list)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Downloads

    func download(_ studies: [PACSStudy], series: [PACSSeries] = [], target: DownloadTarget) {
        for s in studies {
            let job = PACSDownload(study: s, series: series, target: target)
            downloads.insert(job, at: 0)
            enqueue(job)
        }
        startTimer()
    }

    private func enqueue(_ job: PACSDownload) {
        let useGet = configuration.retrieveProtocol == .cGet
        if !useGet && scp == nil { startListener() }
        let destination = configuration.aeTitle
        let client = client(for: job.study.node)
        queue.addOperation { [weak self] in
            guard let self else { return }
            if job.cancelToken.isCancelled { return }
            DispatchQueue.main.async { job.state = .connecting; job.started = Date() }
            let keys = DataSet()
            keys.set(.studyInstanceUID, .UI, string: job.study.studyUID)
            if !job.study.patientID.isEmpty { keys.set(.patientID, .LO, string: job.study.patientID) }
            let level: QueryLevel = job.series.isEmpty ? .study : .series
            if !job.series.isEmpty { keys.set(.seriesInstanceUID, .UI, strings: job.series.map(\.seriesUID)) }
            let onProgress: (RetrieveProgress) -> Void = { p in
                DispatchQueue.main.async {
                    if job.state == .connecting { job.state = .downloading }
                    job.expected = max(job.expected, p.expected)
                    if useGet { job.bytes = p.bytes }
                }
            }
            do {
                let result: RetrieveProgress
                if useGet {
                    result = try client.get(level: level, keys: keys, cancel: job.cancelToken, store: { data, cmd, ts, ae in
                        let obj = try ReceivedObjectWriter.write(data, sopClass: cmd.affectedSOPClass ?? "", sopInstance: cmd.affectedSOPInstance ?? UIDGenerator.make(),
                                                                 transferSyntax: ts, callingAE: ae, under: Self.storageRoot)
                        DispatchQueue.main.async { self.attach(obj, to: job) }
                    }, progress: onProgress)
                } else {
                    result = try client.move(level: level, keys: keys, destination: destination, cancel: job.cancelToken, progress: onProgress)
                }
                DispatchQueue.main.async {
                    job.expected = max(job.expected, result.expected, job.received)
                    if job.cancelToken.isCancelled || result.status == DIMSEStatus.cancel { job.state = .cancelled }
                    else if result.failed > 0 || result.warnings > 0 {
                        job.state = .warning
                        job.error = result.failed > 0 ? "\(result.failed) failed" : "One or more failures"
                    } else { job.state = .finished }
                    if job.received == 0 && job.state == .finished && !useGet {
                        job.state = .warning
                        job.error = "No files received. The PACS device you are trying to download images from has to be configured with your IP, port and AE title so that it knows where to send the images."
                    }
                    self.complete(job)
                }
            } catch {
                DispatchQueue.main.async {
                    job.state = job.cancelToken.isCancelled ? .cancelled : .error
                    job.error = error.localizedDescription
                    self.complete(job)
                }
            }
        }
    }

    private func attach(_ obj: ReceivedObject, to job: PACSDownload) {
        job.files.append(obj.url)
        job.unopened.append(obj.url)
        job.received += 1
        job.bytes += Int64(obj.byteCount)
        job.lastActivity = Date()
        if job.state == .connecting { job.state = .downloading }
    }

    /// Routes a file from the listener to the C-MOVE job waiting for it, or to a "pushed" entry.
    private func received(_ obj: ReceivedObject) {
        if let job = downloads.first(where: { $0.state.isActive && !$0.pushed && $0.study.studyUID == obj.studyUID
            && ($0.series.isEmpty || $0.series.contains { $0.seriesUID == obj.seriesUID }) }) {
            attach(obj, to: job)
            return
        }
        let job: PACSDownload
        if let j = pushedByStudy[obj.studyUID], j.state.isActive { job = j } else {
            var s = PACSStudy(node: DICOMNode(description: obj.callingAE, host: "", port: 0, aeTitle: obj.callingAE), studyUID: obj.studyUID)
            if let f = try? DICOMFile.read(url: obj.url, options: .header) {
                s.patientName = PersonName.display(f.dataSet.string(.patientName))
                s.patientID = f.dataSet.string(.patientID) ?? ""
                s.studyDate = f.dataSet.string(.studyDate) ?? ""
                s.studyDescription = f.dataSet.string(.studyDescription) ?? ""
            }
            job = PACSDownload(study: s, series: [], target: configuration.importToLibrary ? .libraryOnly : .newWindow(UUID()), pushed: true)
            job.state = .downloading
            job.started = Date()
            downloads.insert(job, at: 0)
            pushedByStudy[obj.studyUID] = job
            startTimer()
        }
        attach(obj, to: job)
    }

    private func complete(_ job: PACSDownload) {
        job.ended = Date()
        job.currentSpeed = 0
        flushOpen(job)
        if configuration.importToLibrary && !job.files.isEmpty {
            LibraryWindowController.shared.model.importURLs(job.files, copy: true)
        }
        if job.pushed { pushedByStudy[job.study.studyUID] = nil }
    }

    private func viewer(for job: PACSDownload) -> ViewerWindowController? {
        switch job.target {
        case .libraryOnly: return nil
        case .window(let id):
            if let wc = ViewerWindowController.all.first(where: { ObjectIdentifier($0) == id }) { return wc }
            return makeViewer()
        case .newWindow(let group):
            if let wc = windows[group]?.wc { return wc }
            let wc = makeViewer()
            windows[group] = WeakViewer(wc: wc)
            return wc
        case .separateWindow:
            if let wc = windows[job.id]?.wc { return wc }
            let wc = makeViewer()
            windows[job.id] = WeakViewer(wc: wc)
            return wc
        }
    }

    private func makeViewer() -> ViewerWindowController {
        if let empty = ViewerWindowController.all.first(where: { $0.session.collection.isEmpty && $0.window?.isVisible == true }) { return empty }
        let wc = ViewerWindowController()
        wc.showWindow(nil)
        return wc
    }

    private func flushOpen(_ job: PACSDownload) {
        guard !job.unopened.isEmpty else { return }
        let urls = job.unopened
        job.unopened = []
        viewer(for: job)?.session.open(urls: urls, recordRecent: false)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        var anyActive = false
        for j in downloads where j.state.isActive {
            anyActive = true
            j.currentSpeed = Double(j.bytes - j.lastBytes)
            j.lastBytes = j.bytes
            if j.unopened.count > 0 { flushOpen(j) }
            // Pushed studies have no final response; close them after a quiet period
            if j.pushed && Date().timeIntervalSince(j.lastActivity) > 5 {
                j.state = .finished
                j.expected = j.received
                complete(j)
            }
            j.objectWillChange.send()
        }
        if !anyActive { timer?.invalidate(); timer = nil }
    }

    func cancel(_ job: PACSDownload) {
        guard job.state.isActive else { return }
        job.cancelToken.cancel()
        if job.state == .queued || job.pushed { job.state = .cancelled; complete(job) }
    }

    func cancelAll() { downloads.forEach(cancel) }

    func clearFinished() { downloads.removeAll { !$0.state.isActive } }

    func retry(_ job: PACSDownload) {
        guard !job.state.isActive, !job.pushed else { return }
        let j = PACSDownload(study: job.study, series: job.series, target: job.target)
        if let i = downloads.firstIndex(where: { $0 === job }) { downloads[i] = j } else { downloads.insert(j, at: 0) }
        enqueue(j)
        startTimer()
    }
}
