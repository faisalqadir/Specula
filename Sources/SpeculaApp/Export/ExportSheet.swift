import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import DICOMCore

enum ExportScope: String, CaseIterable, Identifiable {
    case currentImage = "Current image", currentSeries = "Current series", allOpenedSeries = "All opened series", currentStudy = "Current study", allStudies = "All opened studies", currentPatient = "Current patient"
    var id: String { rawValue }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG", png = "PNG", tiff = "TIFF", bmp = "BMP", dicom = "DICOM", mp4 = "MP4 movie"
    var id: String { rawValue }
    var ext: String { ["JPEG": "jpg", "PNG": "png", "TIFF": "tiff", "BMP": "bmp", "DICOM": "dcm", "MP4 movie": "mp4"][rawValue]! }
}

enum ExportSize: String, CaseIterable, Identifiable {
    case original = "Default (1:1)", current = "Current size", fit = "Fit to"
    var id: String { rawValue }
}

enum ExportAnnotations: String, CaseIterable, Identifiable {
    case full = "Full", basic = "Basic (anonymous)", none = "Disabled"
    var id: String { rawValue }
}

final class ExportModel: ObservableObject {
    @Published var scope: ExportScope = .currentSeries
    @Published var format: ExportFormat = .jpeg
    @Published var size: ExportSize = .original
    @Published var fitPixels = 1024
    @Published var annotations: ExportAnnotations = .full
    @Published var quality = 0.9
    @Published var fps = 10.0
    @Published var useSeriesFPS = true
    @Published var folder: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    @Published var prefix = "IMG"
    @Published var revealAfter = true
    @Published var progress: Double?
    @Published var status = ""
    var cancelled = false
}

struct ExportView: View {
    @ObservedObject var model: ExportModel
    let session: ViewerSession
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Images").font(.title3.weight(.semibold))
            Form {
                Picker("Export", selection: $model.scope) { ForEach(ExportScope.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Format", selection: $model.format) { ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) } }
                if model.format != .dicom {
                    Picker("Size", selection: $model.size) { ForEach(ExportSize.allCases) { Text($0.rawValue).tag($0) } }
                    if model.size == .fit { Stepper("\(model.fitPixels) px", value: $model.fitPixels, in: 128...8192, step: 128) }
                    Picker("Annotations", selection: $model.annotations) { ForEach(ExportAnnotations.allCases) { Text($0.rawValue).tag($0) } }
                }
                if model.format == .jpeg || model.format == .mp4 {
                    HStack { Text("Quality"); Slider(value: $model.quality, in: 0.3...1) { } minimumValueLabel: { Text("Smaller").font(.caption) } maximumValueLabel: { Text("Better").font(.caption) } }
                }
                if model.format == .mp4 {
                    Toggle("Use the series frame rate", isOn: $model.useSeriesFPS)
                    if !model.useSeriesFPS { Stepper("\(Int(model.fps)) fps", value: $model.fps, in: 1...60) }
                }
                LabeledContent("Folder") {
                    HStack {
                        Text(model.folder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") {
                            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                            if p.runModal() == .OK, let u = p.url { model.folder = u }
                        }
                    }
                }
                TextField("File name prefix", text: $model.prefix)
                Toggle("Show in Finder after export", isOn: $model.revealAfter)
            }
            .formStyle(.grouped)
            .frame(height: 380)
            if let p = model.progress {
                ProgressView(value: p) { Text(model.status).font(.caption) }
            }
            HStack {
                Spacer()
                Button("Cancel") { if model.progress != nil { model.cancelled = true } else { close() } }.keyboardShortcut(.cancelAction)
                Button("Export") { ExportEngine.run(model: model, session: session, done: close) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.progress != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

enum ExportSheet {
    static func present(session: ViewerSession, on window: NSWindow) {
        let model = ExportModel()
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: ExportView(model: model, session: session) { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        })
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }
}

enum ExportEngine {
    static func series(for scope: ExportScope, session: ViewerSession) -> [Series] {
        let active = session.activeState?.series
        switch scope {
        case .currentImage, .currentSeries: return active.map { [$0] } ?? []
        case .allOpenedSeries: return session.viewports.compactMap { $0.state.series }
        case .currentStudy: return active?.study?.seriesSorted() ?? []
        case .allStudies: return session.collection.allSeries
        case .currentPatient:
            let pid = active?.study?.patientID
            return session.collection.studies.filter { $0.patientID == pid }.flatMap { $0.seriesSorted() }
        }
    }

    static func run(model: ExportModel, session: ViewerSession, done: @escaping () -> Void) {
        let seriesList = series(for: model.scope, session: session)
        guard !seriesList.isEmpty, let active = session.active else { return }
        model.progress = 0
        model.cancelled = false
        let folder = model.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []

        if model.format == .dicom {
            var files: [URL] = []
            for s in seriesList { files += s.instances.map(\.url) }
            if model.scope == .currentImage, let r = active.state.current { files = [r.instance.url] }
            DispatchQueue.global(qos: .userInitiated).async {
                for (i, f) in files.enumerated() {
                    if model.cancelled { break }
                    let dest = folder.appendingPathComponent(String(format: "%@%05d.dcm", model.prefix, i + 1))
                    try? FileManager.default.copyItem(at: f, to: dest)
                    written.append(dest)
                    DispatchQueue.main.async { model.progress = Double(i + 1) / Double(files.count); model.status = "Exporting images… \(i + 1)/\(files.count)" }
                }
                DispatchQueue.main.async { finish(model, written, done) }
            }
            return
        }

        // Rendering happens on the main thread (AppKit drawing); process in small batches to keep the UI alive.
        var jobs: [(Series, [Int])] = []
        for s in seriesList {
            if model.scope == .currentImage { jobs.append((s, [active.state.index])) } else { jobs.append((s, Array(0..<s.images.count))) }
        }
        let total = jobs.reduce(0) { $0 + $1.1.count }
        var count = 0
        let offscreenState = ViewportState()
        let off = ViewportView(state: offscreenState, session: session)
        off.overrideAnnotations = model.annotations != .none
        off.overrideAnonymous = model.annotations == .basic
        let movie = model.format == .mp4
        var writerQueue: [(Series, [Int])] = jobs

        func renderFrame(_ s: Series, _ idx: Int) -> NSImage? {
            if offscreenState.series !== s {
                offscreenState.setSeries(s, index: idx)
                let src = session.viewports.first { $0.state.series === s }?.state ?? active.state
                if src.series === s { offscreenState.display = src.display }
            }
            offscreenState.index = idx
            offscreenState.display.fitMode = .fit
            off.resetFrame()
            guard let ref = s.images[safe: idx], let f = try? FrameCache.shared.decode(ref) else { return nil }
            var size: CGSize
            switch model.size {
            case .original: size = CGSize(width: f.width, height: Int(Double(f.height) * Double(off.contentGeometry?.aspect ?? 1)))
            case .current: size = active.bounds.size
            case .fit:
                let m = Double(max(f.width, f.height))
                let k = Double(model.fitPixels) / m
                size = CGSize(width: Double(f.width) * k, height: Double(f.height) * k * Double(off.contentGeometry?.aspect ?? 1))
            }
            if movie { size = CGSize(width: (Int(size.width) / 2) * 2, height: (Int(size.height) / 2) * 2) }
            off.frame = CGRect(origin: .zero, size: size)
            off.layoutSubtreeIfNeeded()
            off.ensureFrameSynchronously()
            return off.snapshot(scale: 1, includeOverlay: model.annotations != .none)
        }

        func step() {
            guard !model.cancelled, !writerQueue.isEmpty else { finish(model, written, done); return }
            let (s, indices) = writerQueue.removeFirst()
            let baseName = model.prefix + "_" + (s.number.map { "S\($0)" } ?? "S") + "_" + sanitized(s.seriesDescription)
            if movie {
                let url = folder.appendingPathComponent(baseName + ".mp4")
                let fps = model.useSeriesFPS ? (s.first?.frameTimeMs.map { 1000 / $0 } ?? Preferences.shared.defaultCineFPS) : model.fps
                let frames = indices.compactMap { i -> NSImage? in
                    count += 1
                    model.progress = Double(count) / Double(total)
                    model.status = "Rendering video… \(count)/\(total)"
                    return renderFrame(s, i)
                }
                MovieWriter.write(images: frames, fps: fps, quality: model.quality, to: url) { ok in
                    if ok { written.append(url) }
                    DispatchQueue.main.async { step() }
                }
                return
            }
            for i in indices {
                if model.cancelled { break }
                autoreleasepool {
                    if let img = renderFrame(s, i), let data = encode(img, model.format, quality: model.quality) {
                        let name = indices.count == 1 && model.scope == .currentImage ? baseName : String(format: "%@_%04d", baseName, i + 1)
                        let url = folder.appendingPathComponent(name).appendingPathExtension(model.format.ext)
                        try? data.write(to: url)
                        written.append(url)
                    }
                }
                count += 1
                model.progress = Double(count) / Double(total)
                model.status = "Exporting images… \(count)/\(total)"
            }
            DispatchQueue.main.async { step() }
        }
        DispatchQueue.main.async { step() }
    }

    static func finish(_ model: ExportModel, _ written: [URL], _ done: () -> Void) {
        model.progress = nil
        if model.revealAfter, !written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(Array(written.prefix(50))) }
        done()
    }

    static func sanitized(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let t = String(s.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "series" : String(t.prefix(40))
    }

    static func encode(_ img: NSImage, _ f: ExportFormat, quality: Double) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        switch f {
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        case .png: return rep.representation(using: .png, properties: [:])
        case .tiff: return rep.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue])
        case .bmp: return rep.representation(using: .bmp, properties: [:])
        default: return nil
        }
    }
}

/// H.264 MP4 writer for rendered frames.
enum MovieWriter {
    static func write(images: [NSImage], fps: Double, quality: Double, to url: URL, completion: @escaping (Bool) -> Void) {
        guard let first = images.first, let cg0 = first.cgImage(forProposedRect: nil, context: nil, hints: nil) else { completion(false); return }
        let w = (cg0.width / 2) * 2, h = (cg0.height / 2) * 2
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { completion(false); return }
        let bitrate = Double(w * h) * max(1, fps) * (0.08 + quality * 0.25)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
                                       AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate]]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        DispatchQueue.global(qos: .userInitiated).async {
            let timescale: Int32 = 600
            for (i, img) in images.enumerated() {
                guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil), let pool = adaptor.pixelBufferPool else { continue }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let buffer = pb else { continue }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(Double(i) * Double(timescale) / max(1, fps)), timescale: timescale))
            }
            input.markAsFinished()
            writer.finishWriting { completion(writer.status == .completed) }
        }
    }
}
