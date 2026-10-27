import AppKit
import WebKit
import PDFKit
import AVKit
import AVFoundation
import CoreMedia
import VideoToolbox
import DICOMCore

/// Structured reports (rendered as HTML) and encapsulated PDF documents.
enum DocumentViewer {
    private static var windows: [NSWindowController] = []

    static func show(series: Series, from parent: NSWindow?) {
        guard let inst = series.first else { return }
        guard let f = try? DICOMFile.read(url: inst.url) else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 900), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = inst.string(.documentTitle) ?? inst.string(.seriesDescription) ?? (inst.kind == .pdf ? "PDF Document" : "Structured Report")
        w.isReleasedWhenClosed = false
        if inst.kind == .pdf, let e = f.dataSet[.encapsulatedDocument] {
            var data = Data()
            switch e.value {
            case .data(let d): data = d
            case .encapsulated(let enc): enc.fragments.forEach { data.append($0) }
            default: break
            }
            // trim trailing padding after %%EOF
            let pv = PDFView()
            pv.autoScales = true
            pv.document = PDFDocument(data: data)
            w.contentView = pv
        } else {
            let web = WKWebView()
            web.loadHTMLString(SRRenderer.html(f.dataSet), baseURL: nil)
            w.contentView = web
        }
        let wc = NSWindowController(window: w)
        windows.append(wc)
        w.center()
        wc.showWindow(nil)
    }
}

enum SRRenderer {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func html(_ ds: DataSet) -> String {
        func row(_ k: String, _ v: String?) -> String { (v?.isEmpty ?? true) ? "" : "<tr><th>\(esc(k))</th><td>\(esc(v!))</td></tr>" }
        var h = """
        <html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        body { font: 13px -apple-system, system-ui; margin: 28px; line-height: 1.45; }
        h1 { font-size: 20px; margin: 0 0 16px; } h2 { font-size: 15px; margin: 22px 0 8px; border-bottom: 1px solid rgba(128,128,128,.3); padding-bottom: 4px; }
        h3 { font-size: 13px; margin: 14px 0 6px; } table { border-collapse: collapse; } th { text-align: right; padding: 2px 12px 2px 0; color: gray; font-weight: 500; vertical-align: top; }
        td { padding: 2px 0; } .item { margin: 6px 0 6px 0; } .name { color: gray; } .lvl { margin-left: 18px; }
        </style></head><body>
        """
        let title = ds.firstItem(.conceptNameCodeSequence)?.string(.codeMeaning) ?? "Structured Report"
        h += "<h1>\(esc(title))</h1>"
        h += "<h2>Patient Information</h2><table>"
        h += row("Name", PersonName.display(ds.string(.patientName))) + row("Patient ID", ds.string(.patientID)) + row("Birth date", DICOMDate.formatDate(ds.string(.patientBirthDate))) + row("Sex", ds.string(.patientSex))
        h += "</table><h2>Study Information</h2><table>"
        h += row("Description", ds.string(.studyDescription)) + row("Date", DICOMDate.formatDate(ds.string(.studyDate))) + row("Study ID", ds.string(.studyID)) + row("Accession", ds.string(.accessionNumber))
        h += row("Manufacturer", ds.string(.manufacturer)) + row("Model", ds.string(.manufacturerModelName)) + row("Institution", ds.string(.institutionName))
        h += "</table><h2>SR Document Information</h2><table>"
        h += row("Completion", ds.string(.completionFlag)) + row("Verification", ds.string(.verificationFlag)) + row("Content date", DICOMDate.formatDate(ds.string(.contentDate)))
        h += "</table><h2>Content</h2>"
        h += content(ds.sequence(.contentSequence) ?? [], level: 0)
        h += "</body></html>"
        return h
    }

    static func content(_ items: [DataSet], level: Int) -> String {
        var h = ""
        for it in items {
            let name = it.firstItem(.conceptNameCodeSequence)?.string(.codeMeaning) ?? ""
            let type = it.string(.valueType) ?? ""
            var value = ""
            switch type {
            case "TEXT": value = it.string(.textValue) ?? ""
            case "CODE": value = it.firstItem(.conceptCodeSequence)?.string(.codeMeaning) ?? ""
            case "NUM":
                let mv = it.firstItem(.measuredValueSequence)
                value = (mv?.string(.numericValue) ?? "") + " " + (mv?.firstItem(.measurementUnitsCodeSequence)?.string(.codeValue) ?? "")
            case "PNAME": value = PersonName.display(it.string(.personName))
            case "DATE": value = DICOMDate.formatDate(it.string(.dateValue))
            case "TIME": value = DICOMDate.formatTime(it.string(.timeValue))
            case "DATETIME": value = it.string(.dateTimeValue) ?? ""
            case "UIDREF": value = it.string(.uidValue) ?? ""
            case "IMAGE", "COMPOSITE":
                let r = it.firstItem(.referencedSOPSequence)
                value = "Reference: " + (r?.string(.referencedSOPInstanceUID) ?? "")
            default: break
            }
            if type == "CONTAINER" {
                h += level == 0 ? "<h3>\(esc(name))</h3>" : "<div class='item'><b>\(esc(name))</b></div>"
            } else {
                h += "<div class='item'>\(name.isEmpty ? "" : "<span class='name'>\(esc(name)): </span>")\(esc(value).replacingOccurrences(of: "\n", with: "<br>"))</div>"
            }
            if let kids = it.sequence(.contentSequence), !kids.isEmpty {
                h += "<div class='lvl'>" + content(kids, level: level + 1) + "</div>"
            }
        }
        return h
    }
}

/// Plays DICOM-encapsulated H.264 / HEVC video by re-muxing the elementary stream into MP4.
enum VideoPlayerWindow {
    private static var windows: [NSWindowController] = []

    static func show(instance: Instance) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try remux(instance) }
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
                    w.title = instance.string(.seriesDescription) ?? "Video"
                    w.isReleasedWhenClosed = false
                    let pv = AVPlayerView()
                    pv.player = AVPlayer(url: url)
                    pv.controlsStyle = .floating
                    w.contentView = pv
                    let wc = NSWindowController(window: w)
                    windows.append(wc)
                    w.center()
                    wc.showWindow(nil)
                    pv.player?.play()
                case .failure(let e):
                    let a = NSAlert()
                    a.messageText = "The video could not be played"
                    a.informativeText = e.localizedDescription
                    a.runModal()
                }
            }
        }
    }

    static func remux(_ inst: Instance) throws -> URL {
        let f = try DICOMFile.read(url: inst.url)
        guard let enc = f.dataSet[.pixelData]?.encapsulated else { throw DICOMError.decode("no video stream") }
        var stream = Data()
        enc.fragments.forEach { stream.append($0) }
        let out = DICOMLoader.tempRoot.appendingPathComponent(UUID().uuidString + ".mp4")
        switch f.transferSyntax.codec {
        case .h264, .hevc:
            try AnnexBMuxer.write(stream, hevc: f.transferSyntax.codec == .hevc, fps: inst.frameTimeMs.map { 1000 / $0 } ?? 30, to: out)
        case .mpeg2:
            // Some files actually hold an MPEG-4 container; try AVFoundation directly.
            let raw = DICOMLoader.tempRoot.appendingPathComponent(UUID().uuidString + ".mpg")
            try stream.write(to: raw)
            return raw
        default:
            throw DICOMError.unsupported(f.transferSyntax.name)
        }
        return out
    }
}

/// Converts an Annex B H.264/HEVC byte stream into an MP4 file without re-encoding.
enum AnnexBMuxer {
    static func nalUnits(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var starts: [(Int, Int)] = [] // (start of NAL, prefix length)
        var i = 0
        while i + 3 < b.count {
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 { starts.append((i + 3, 3)); i += 3; continue }
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 0 && i + 3 < b.count && b[i + 3] == 1 { starts.append((i + 4, 4)); i += 4; continue }
            i += 1
        }
        var out: [Data] = []
        for (k, s) in starts.enumerated() {
            var end = k + 1 < starts.count ? starts[k + 1].0 - starts[k + 1].1 : b.count
            while end > s.0 && b[end - 1] == 0 { end -= 1 }
            if end > s.0 { out.append(Data(b[s.0..<end])) }
        }
        return out
    }

    static func write(_ stream: Data, hevc: Bool, fps: Double, to url: URL) throws {
        let nals = nalUnits(stream)
        func type(_ n: Data) -> Int { hevc ? Int((n.first ?? 0) >> 1) & 0x3F : Int(n.first ?? 0) & 0x1F }
        var vps: Data?, sps: Data?, pps: Data?
        for n in nals {
            let t = type(n)
            if hevc { if t == 32 { vps = vps ?? n } else if t == 33 { sps = sps ?? n } else if t == 34 { pps = pps ?? n } }
            else { if t == 7 { sps = sps ?? n } else if t == 8 { pps = pps ?? n } }
        }
        guard let sps, let pps, !hevc || vps != nil else { throw DICOMError.decode("missing parameter sets") }
        var fmt: CMVideoFormatDescription?
        let params = hevc ? [vps!, sps, pps] : [sps, pps]
        let ptrs = params.map { d -> UnsafePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return UnsafePointer(p)
        }
        defer { ptrs.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
        let sizes = params.map(\.count)
        let status: OSStatus
        if hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3, parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        }
        guard status == noErr, let fmt else { throw DICOMError.decode("format description \(status)") }
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        // Group NAL units into access units: a new AU starts at each VCL NAL with first_slice flag / AUD
        var au = Data()
        var frame: Int64 = 0
        let timescale: Int32 = 600
        let duration = CMTime(value: CMTimeValue(Double(timescale) / max(1, fps)), timescale: timescale)
        func flush() {
            guard !au.isEmpty else { return }
            var block: CMBlockBuffer?
            let len = au.count
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: len, flags: 0, blockBufferOut: &block)
            guard let block else { return }
            au.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: len) }
            var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: CMTimeMultiply(duration, multiplier: Int32(frame)), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            var size = len
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
            if let sample {
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
                input.append(sample)
            }
            frame += 1
            au = Data()
        }
        for n in nals {
            let t = type(n)
            let isVCL = hevc ? t < 32 : (t >= 1 && t <= 5)
            if isVCL {
                let firstSlice = hevc ? (n.count > 2 && n[n.startIndex + 2] & 0x80 != 0) : (n.count > 1 && n[n.startIndex + 1] & 0x80 != 0)
                if firstSlice { flush() }
            } else if (hevc && t == 35) || (!hevc && t == 9) {
                flush()
            }
            if (hevc && (t == 32 || t == 33 || t == 34)) || (!hevc && (t == 7 || t == 8)) { continue }
            var l = UInt32(n.count).bigEndian
            withUnsafeBytes(of: &l) { au.append(contentsOf: $0) }
            au.append(n)
        }
        flush()
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw DICOMError.decode(writer.error?.localizedDescription ?? "mux failed") }
    }
}
