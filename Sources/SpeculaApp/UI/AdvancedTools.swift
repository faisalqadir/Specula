import AppKit
import SwiftUI
import Charts
import DICOMCore

// MARK: - Fusion

enum FusionSheet {
    static func present(session: ViewerSession, on window: NSWindow) {
        guard let base = session.activeState?.series else { return }
        let candidates = session.collection.allSeries.filter { $0 !== base && $0.volumeCandidate && ($0.frameOfReference == base.frameOfReference || $0.study === base.study) }
        guard !candidates.isEmpty else {
            let a = NSAlert(); a.messageText = "Fusion"
            a.informativeText = "Open a second volume series of the same patient (for example PET with CT) to overlay it on the active panel."
            a.beginSheetModal(for: window); return
        }
        let a = NSAlert()
        a.messageText = "PET-CT Fusion"
        a.informativeText = "Choose the series to overlay on \"\(base.seriesDescription)\"."
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        for s in candidates { pop.addItem(withTitle: "\(s.modality) — \(s.seriesDescription) (\(s.imageCount))") }
        if let pet = candidates.firstIndex(where: { $0.modality == "PT" || $0.modality == "NM" }) { pop.selectItem(at: pet) }
        a.accessoryView = pop
        a.addButton(withTitle: "Fuse"); a.addButton(withTitle: "Cancel")
        if session.activeState?.fusion != nil { a.addButton(withTitle: "Remove Fusion") }
        a.beginSheetModal(for: window) { r in
            if r == .alertThirdButtonReturn { session.applyToActive { $0.fusion = nil }; return }
            guard r == .alertFirstButtonReturn else { return }
            let s = candidates[pop.indexOfSelectedItem]
            let progress = ProgressWindow(title: "Preparing fusion…")
            progress.show()
            Volume.build(series: s, progress: { progress.value = $0 }) { result in
                progress.close()
                if case .success(let v) = result {
                    session.applyToActive { st in
                        let layer = FusionLayer(series: s, volume: v)
                        if s.modality == "PT" { layer.colormap = .hotIron }
                        st.fusion = layer
                    }
                    session.windowController?.window?.toolbar?.validateVisibleItems()
                } else if case .failure(let e) = result {
                    let al = NSAlert(); al.messageText = "Fusion failed"; al.informativeText = e.localizedDescription; al.runModal()
                }
            }
        }
    }
}

// MARK: - Time-intensity curve

struct TICPoint: Identifiable {
    let id = UUID()
    let time: Double
    let value: Double
    let label: String
    let series: String
}

final class TICModel: ObservableObject {
    @Published var points: [TICPoint] = []
    @Published var message = ""
    @Published var useSUV = false
}

enum TimeIntensityWindow {
    private static var windows: [NSWindow] = []

    static func show(session: ViewerSession) {
        let model = TICModel()
        compute(session: session, model: model)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Time-Intensity Curve"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: TICView(model: model) { compute(session: session, model: model) })
        w.center()
        windows.append(w)
        w.makeKeyAndOrderFront(nil)
    }

    /// Uses the selected (or last) ellipse/area ROI of the active panel and measures it across
    /// all images of the series at the same position (dynamic studies) or across all open series.
    static func compute(session: ViewerSession, model: TICModel) {
        guard let v = session.active, let ref = v.state.current, let series = v.state.series else { model.message = "No image."; return }
        let rois = v.measurements.filter { $0.kind.isArea }
        guard let roi = rois.first(where: { $0.id == v.selectedMeasurement }) ?? rois.last else {
            model.message = "Draw an ellipse ROI on the active image first."
            model.points = []
            return
        }
        let poly = MeasurementCalculator.outline(roi)
        var refs: [ImageRef] = []
        if let p = ref.plane {
            // Same slice position within the series (dynamic acquisitions)
            refs = series.images.filter { r in r.plane.map { abs($0.pixel(of: p.center).distance) < 0.5 } ?? false }
        }
        if refs.count < 2 { refs = series.images }
        // Also include other open series at this position
        for o in session.viewports where o !== v {
            if let r = o.state.current, r.instance.rows == ref.instance.rows, r.instance.columns == ref.instance.columns { refs.append(r) }
        }
        var pts: [TICPoint] = []
        let t0 = refs.compactMap { $0.attributes.acquisitionTime }.min() ?? 0
        for (i, r) in refs.enumerated() {
            guard let f = try? FrameCache.shared.decode(r), !f.isColor else { continue }
            let a = r.attributes
            let st = MeasurementCalculator.stats(polygon: poly, frame: f, slope: a.rescaleSlope, intercept: a.rescaleIntercept)
            let t = r.attributes.acquisitionTime.map { $0 - t0 } ?? Double(i)
            pts.append(TICPoint(time: t, value: st.mean, label: "Se: \(r.instance.header.int(.seriesNumber) ?? 0), Im: \(r.instance.instanceNumber ?? i + 1)", series: r.instance.string(.seriesDescription) ?? ""))
        }
        model.points = pts.sorted { $0.time < $1.time }
        model.message = pts.count < 2 ? "At least two images with the ROI are required for a time-intensity curve." : "\(pts.count) points · ROI mean value"
    }
}

struct TICView: View {
    @ObservedObject var model: TICModel
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(model.message).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { refresh() }
                Button("Copy Data") {
                    let s = (["Time (s)\tMean\tImage"] + model.points.map { String(format: "%.2f\t%.3f\t%@", $0.time, $0.value, $0.label) }).joined(separator: "\n")
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
                }
            }
            Chart(model.points) { p in
                LineMark(x: .value("Time (s)", p.time), y: .value("Mean", p.value))
                PointMark(x: .value("Time (s)", p.time), y: .value("Mean", p.value))
            }
            .chartXAxisLabel("Time (s)")
            .chartYAxisLabel("Mean")
            .padding(.top, 8)
            Table(model.points) {
                TableColumn("Time (s)") { Text(String(format: "%.2f", $0.time)) }
                TableColumn("Mean") { Text(String(format: "%.2f", $0.value)) }
                TableColumn("Image", value: \.label)
                TableColumn("Series", value: \.series)
            }
            .frame(height: 150)
        }
        .padding(16)
    }
}

// MARK: - Open multiple series

enum MultiSeriesPicker {
    static func present(session: ViewerSession, on window: NSWindow) {
        let all = session.collection.allSeries.filter { $0.kind == .image || $0.kind == .video }
        guard !all.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Open multiple series"
        a.informativeText = "Select the series to show in separate panels."
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        var boxes: [NSButton] = []
        for s in all {
            let b = NSButton(checkboxWithTitle: "\(s.modality)  \(s.number.map { "#\($0) " } ?? "")\(s.seriesDescription)  (\(s.imageCount))", target: nil, action: nil)
            boxes.append(b)
            stack.addArrangedSubview(b)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: min(320, CGFloat(all.count) * 24 + 8)))
        scroll.documentView = stack
        stack.frame = NSRect(x: 0, y: 0, width: 370, height: CGFloat(all.count) * 24)
        scroll.hasVerticalScroller = true
        a.accessoryView = scroll
        a.addButton(withTitle: "Open"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in
            guard r == .alertFirstButtonReturn else { return }
            let chosen = zip(all, boxes).filter { $0.1.state == .on }.map(\.0)
            guard !chosen.isEmpty else { return }
            let cols = Int(ceil(sqrt(Double(chosen.count))))
            session.setLayout(rows: Int(ceil(Double(chosen.count) / Double(cols))), columns: cols)
            for (i, s) in chosen.enumerated() where i < session.viewports.count { session.show(s, in: session.viewports[i]) }
        }
    }
}
