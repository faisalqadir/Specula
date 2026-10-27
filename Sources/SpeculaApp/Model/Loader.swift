import Foundation
import AppKit
import DICOMCore

/// All studies opened in a viewer window.
final class StudyCollection: ObservableObject {
    @Published private(set) var studies: [Study] = []
    private var studyByUID: [String: Study] = [:]
    private var seriesByKey: [String: Series] = [:]
    var studyOrderDescending = false

    var allSeries: [Series] { studies.flatMap { $0.seriesSorted() } }
    var isEmpty: Bool { studies.isEmpty }

    /// Adds instances (main thread). Returns series that changed.
    @discardableResult
    func add(_ instances: [Instance]) -> [Series] {
        var touched: [ObjectIdentifier: Series] = [:]
        var newStudies = false
        for inst in instances {
            let study: Study
            if let s = studyByUID[inst.studyUID] { study = s } else {
                study = Study(uid: inst.studyUID, header: inst.header)
                studyByUID[inst.studyUID] = study
                studies.append(study)
                newStudies = true
            }
            let key = inst.studyUID + "|" + inst.seriesUID
            let series: Series
            if let s = seriesByKey[key] { series = s } else {
                series = Series(uid: inst.seriesUID, study: study)
                seriesByKey[key] = series
                study.series.append(series)
            }
            if series.add(inst) { touched[ObjectIdentifier(series)] = series }
        }
        for s in touched.values {
            if s.images.isEmpty { s.chooseDefaultSort() }
            s.rebuildImages()
        }
        if newStudies { sortStudies() }
        objectWillChange.send()
        return Array(touched.values)
    }

    func sortStudies() {
        studies.sort { a, b in
            let pa = a.patientNameRaw, pb = b.patientNameRaw
            if pa != pb { return pa < pb }
            let da = a.studyDate + a.studyTime, db = b.studyDate + b.studyTime
            return studyOrderDescending ? da > db : da < db
        }
    }

    func remove(study: Study) {
        studies.removeAll { $0 === study }
        studyByUID.removeValue(forKey: study.uid)
        for s in study.series { seriesByKey.removeValue(forKey: study.uid + "|" + s.uid) }
        objectWillChange.send()
    }

    func removeAll() {
        studies.removeAll(); studyByUID.removeAll(); seriesByKey.removeAll()
        objectWillChange.send()
    }

    /// Splits a series into sub-series by orientation / size / echo / temporal position.
    func split(_ series: Series) -> [Series] {
        guard let study = series.study else { return [series] }
        var groups: [String: [Instance]] = [:]
        var order: [String] = []
        for inst in series.instances {
            let p = inst.frames.first?.plane
            let orient = p.map { String(format: "%.2f,%.2f,%.2f", $0.normal.x, $0.normal.y, $0.normal.z) } ?? "-"
            let echo = inst.header.string(Tag(0x0018, 0x0086)) ?? ""
            let temporal = inst.header.string(.temporalPositionIdentifier) ?? ""
            let k = "\(inst.rows)x\(inst.columns)|\(orient)|\(echo)|\(temporal)|\(inst.imageType.prefix(2).joined())"
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(inst)
        }
        guard order.count > 1 else { return [series] }
        study.series.removeAll { $0 === series }
        var result: [Series] = []
        for (i, k) in order.enumerated() {
            let s = Series(uid: series.uid + ".split\(i + 1)", study: study)
            s.splitLabel = "part \(i + 1)/\(order.count)"
            for inst in groups[k]! { s.add(inst) }
            s.chooseDefaultSort()
            s.rebuildImages()
            seriesByKey[study.uid + "|" + s.uid] = s
            study.series.append(s)
            result.append(s)
        }
        seriesByKey.removeValue(forKey: study.uid + "|" + series.uid)
        objectWillChange.send()
        study.objectWillChange.send()
        return result
    }
}

struct LoadProgress {
    var phase: String
    var found: Int
    var loaded: Int
    var done: Bool
}

/// Scans files, folders, ZIP archives and DICOMDIRs and parses DICOM headers in parallel.
final class DICOMLoader {
    private let queue = DispatchQueue(label: "specula.loader", qos: .userInitiated)
    private var cancelled = false
    static let tempRoot: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("Specula-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static let skippedExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "txt", "pdf", "html", "htm", "xml", "exe", "dll", "inf", "ini", "ico", "bmp", "css", "js", "json", "plist", "app", "dmg", "zip", "md", "rtf", "doc", "docx", "xls", "xlsx", "mov", "mp4", "avi", "wmv", "mp3", "tif", "tiff", "icns", "jar", "class", "sys", "cab", "msi", "bat", "sh", "log", "lnk", "url", "nfo", "db", "cfg", "inc", "dylib", "so", "a", "o", "h", "c", "cpp", "swift", "py"]

    func cancel() { cancelled = true }

    /// - Parameters:
    ///   - passwordProvider: called on the main thread for encrypted archives.
    func load(urls: [URL], passwordProvider: @escaping (URL) -> String?, batch: @escaping ([Instance]) -> Void, progress: @escaping (LoadProgress) -> Void, completion: @escaping (Int) -> Void) {
        cancelled = false
        queue.async { [self] in
            var files: [URL] = []
            var p = LoadProgress(phase: "Scanning…", found: 0, loaded: 0, done: false)
            let fm = FileManager.default
            func report() { let q = p; DispatchQueue.main.async { progress(q) } }
            var lastReport = Date()
            for url in urls {
                if cancelled { break }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    let dicomdir = ["DICOMDIR", "dicomdir", "DicomDir"].map { url.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
                    if let dd = dicomdir {
                        let refs = DICOMDIRReader.referencedFiles(dicomdir: dd)
                        if !refs.isEmpty { files += refs; p.found = files.count; continue }
                    }
                    if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                        for case let f as URL in en {
                            if cancelled { break }
                            let ext = f.pathExtension.lowercased()
                            if ext == "zip" { files += expandZip(f, passwordProvider: passwordProvider); continue }
                            if DICOMLoader.skippedExtensions.contains(ext) { continue }
                            if f.lastPathComponent.uppercased() == "DICOMDIR" { continue }
                            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                            files.append(f)
                            p.found = files.count
                            if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); report() }
                        }
                    }
                } else if url.pathExtension.lowercased() == "zip" || isZip(url) {
                    files += expandZip(url, passwordProvider: passwordProvider)
                } else if url.lastPathComponent.uppercased() == "DICOMDIR" {
                    files += DICOMDIRReader.referencedFiles(dicomdir: url)
                } else {
                    files.append(url)
                }
                p.found = files.count
            }
            p.phase = "Reading images…"
            report()
            // Parse headers in parallel chunks
            let chunk = 48
            var loaded = 0
            var index = 0
            while index < files.count && !cancelled {
                let slice = Array(files[index..<min(files.count, index + chunk * 8)])
                index += slice.count
                var results = [Instance?](repeating: nil, count: slice.count)
                results.withUnsafeMutableBufferPointer { buf in
                    DispatchQueue.concurrentPerform(iterations: slice.count) { i in
                        let u = slice[i]
                        guard DICOMFile.looksLikeDICOM(url: u), let f = try? DICOMFile.read(url: u, options: .header) else { return }
                        if f.dataSet.isEmpty { return }
                        buf[i] = Instance(url: u, file: f)
                    }
                }
                let insts = results.compactMap { $0 }
                loaded += insts.count
                p.loaded = loaded
                p.found = files.count
                let q = p
                DispatchQueue.main.async {
                    if !insts.isEmpty { batch(insts) }
                    progress(q)
                }
            }
            DispatchQueue.main.async {
                var q = p
                q.done = true
                q.phase = self.cancelled ? "Loading cancelled" : "Ready"
                progress(q)
                completion(loaded)
            }
        }
    }

    private func isZip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: 4) else { return false }
        try? h.close()
        return d == Data([0x50, 0x4B, 0x03, 0x04])
    }

    private func expandZip(_ url: URL, passwordProvider: @escaping (URL) -> String?) -> [URL] {
        guard let zip = try? ZipArchive(url: url) else { return [] }
        var password: String? = nil
        if zip.isEncrypted {
            password = DispatchQueue.main.sync { passwordProvider(url) }
            if password == nil { return [] }
        }
        let dest = DICOMLoader.tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var out: [URL] = []
        for e in zip.entries where !e.isDirectory {
            if cancelled { break }
            let name = e.path.split(separator: "/").map(String.init).filter { $0 != ".." }.joined(separator: "/")
            let ext = (name as NSString).pathExtension.lowercased()
            if DICOMLoader.skippedExtensions.contains(ext) && ext != "zip" { continue }
            if name.hasPrefix("__MACOSX") { continue }
            do {
                let data = try zip.extract(e, password: password)
                let target = dest.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target)
                if ext == "zip" { out += expandZip(target, passwordProvider: passwordProvider) } else { out.append(target) }
            } catch ZipArchive.ZipError.wrongPassword {
                password = DispatchQueue.main.sync { passwordProvider(url) }
                if password == nil { break }
            } catch {
                continue
            }
        }
        return out
    }
}

/// Decoded frame cache with memory budget and in-flight request coalescing.
final class FrameCache: @unchecked Sendable {
    static let shared = FrameCache()

    private struct Entry { let frame: PixelFrame; var lastUse: UInt64 }
    private var entries: [ImageRef: Entry] = [:]
    private var bytes = 0
    private var tick: UInt64 = 0
    private var inflight: [ImageRef: [(Result<PixelFrame, Error>) -> Void]] = [:]
    private let lock = NSLock()
    private let decodeQueue = OperationQueue()
    private var fileCache: [URL: (DICOMFile, UInt64)] = [:]
    var budget: Int

    init() {
        budget = Int(min(Double(ProcessInfo.processInfo.physicalMemory) * 0.35, 6e9))
        decodeQueue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        decodeQueue.qualityOfService = .userInitiated
    }

    func cached(_ ref: ImageRef) -> PixelFrame? {
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[ref] else { return nil }
        tick += 1
        e.lastUse = tick
        entries[ref] = e
        return e.frame
    }

    private func store(_ ref: ImageRef, _ f: PixelFrame) {
        lock.lock(); defer { lock.unlock() }
        if entries[ref] != nil { return }
        tick += 1
        entries[ref] = Entry(frame: f, lastUse: tick)
        bytes += f.pixels.count
        if bytes > budget {
            let sorted = entries.sorted { $0.value.lastUse < $1.value.lastUse }
            for (k, v) in sorted {
                if bytes <= budget * 8 / 10 { break }
                entries.removeValue(forKey: k)
                bytes -= v.frame.pixels.count
            }
        }
    }

    func parsedFile(_ url: URL) throws -> DICOMFile {
        lock.lock()
        if let (f, _) = fileCache[url] {
            tick += 1
            fileCache[url] = (f, tick)
            lock.unlock()
            return f
        }
        lock.unlock()
        let f = try DICOMFile.read(url: url)
        lock.lock()
        tick += 1
        fileCache[url] = (f, tick)
        if fileCache.count > 12, let oldest = fileCache.min(by: { $0.value.1 < $1.value.1 })?.key { fileCache.removeValue(forKey: oldest) }
        lock.unlock()
        return f
    }

    func decode(_ ref: ImageRef) throws -> PixelFrame {
        if let f = cached(ref) { return f }
        let file = try parsedFile(ref.instance.url)
        let f = try PixelDecoder.decodeFrame(file, frame: ref.frame)
        store(ref, f)
        if !ref.instance.isMultiFrame {
            lock.lock(); fileCache.removeValue(forKey: ref.instance.url); lock.unlock()
        }
        return f
    }

    func request(_ ref: ImageRef, priority: Operation.QueuePriority = .normal, completion: @escaping (Result<PixelFrame, Error>) -> Void) {
        if let f = cached(ref) { completion(.success(f)); return }
        lock.lock()
        if inflight[ref] != nil {
            inflight[ref]!.append(completion)
            lock.unlock()
            return
        }
        inflight[ref] = [completion]
        lock.unlock()
        let op = BlockOperation { [self] in
            let result: Result<PixelFrame, Error>
            do { result = .success(try decode(ref)) } catch { result = .failure(error) }
            lock.lock()
            let waiters = inflight.removeValue(forKey: ref) ?? []
            lock.unlock()
            DispatchQueue.main.async { waiters.forEach { $0(result) } }
        }
        op.queuePriority = priority
        decodeQueue.addOperation(op)
    }

    /// Prefetches neighbours of an index in a series.
    func prefetch(_ images: [ImageRef], around index: Int, radius: Int = 12) {
        guard !images.isEmpty else { return }
        for d in 1...radius {
            for i in [index + d, index - d] where i >= 0 && i < images.count {
                let r = images[i]
                if cached(r) == nil { request(r, priority: d < 4 ? .high : .low) { _ in } }
            }
        }
    }

    func purge() {
        lock.lock(); entries.removeAll(); bytes = 0; fileCache.removeAll(); lock.unlock()
    }
}
