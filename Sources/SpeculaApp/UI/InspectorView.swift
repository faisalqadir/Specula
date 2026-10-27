import SwiftUI
import AppKit
import DICOMCore

struct InspectorView: View {
    @ObservedObject var session: ViewerSession
    @State private var tab = 0
    @State private var tick = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Image").tag(0)
                Text("Display").tag(1)
                Text("Measurements").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case 0: InfoPane(session: session, tick: tick)
                    case 1: DisplayPane(session: session, tick: tick)
                    default: MeasurementsPane(session: session, tick: tick)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .viewportImageChanged)) { _ in tick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .activeViewportChanged)) { _ in tick += 1 }
        .onReceive(session.$measurementRevision) { _ in tick += 1 }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in if tab == 1 { tick += 1 } }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
                Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11.5))
        }
    }
}

private struct InfoPane: View {
    @ObservedObject var session: ViewerSession
    let tick: Int

    var body: some View {
        let s = session.activeState
        let r = s?.current
        let h = r?.instance.header
        VStack(alignment: .leading, spacing: 14) {
            if let h {
                GroupBox("Patient") {
                    VStack(alignment: .leading, spacing: 4) {
                        InfoRow(label: "Name", value: session.hidePatientData ? "—" : PersonName.display(h.string(.patientName)))
                        InfoRow(label: "ID", value: session.hidePatientData ? "—" : h.string(.patientID) ?? "")
                        InfoRow(label: "Birth date", value: session.hidePatientData ? "—" : DICOMDate.formatDate(h.string(.patientBirthDate)))
                        InfoRow(label: "Sex", value: h.string(.patientSex) ?? "")
                        InfoRow(label: "Age", value: h.string(.patientAge) ?? "")
                        InfoRow(label: "Weight", value: h.string(.patientWeight).map { "\($0) kg" } ?? "")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Study") {
                    VStack(alignment: .leading, spacing: 4) {
                        InfoRow(label: "Description", value: h.string(.studyDescription) ?? "")
                        InfoRow(label: "Date", value: DICOMDate.formatDate(h.string(.studyDate)) + " " + DICOMDate.formatTime(h.string(.studyTime)))
                        InfoRow(label: "Accession", value: h.string(.accessionNumber) ?? "")
                        InfoRow(label: "Referring", value: PersonName.display(h.string(.referringPhysicianName)))
                        InfoRow(label: "Institution", value: session.hidePatientData ? "—" : h.string(.institutionName) ?? "")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Series") {
                    VStack(alignment: .leading, spacing: 4) {
                        InfoRow(label: "Description", value: s?.series?.seriesDescription ?? "")
                        InfoRow(label: "Number", value: s?.series?.number.map(String.init) ?? "")
                        InfoRow(label: "Modality", value: r?.instance.modality ?? "")
                        InfoRow(label: "Images", value: "\(s?.imageCount ?? 0)")
                        InfoRow(label: "Body part", value: h.string(.bodyPartExamined) ?? "")
                        InfoRow(label: "Protocol", value: h.string(.protocolName) ?? "")
                        InfoRow(label: "Device", value: [h.string(.manufacturer), h.string(.manufacturerModelName)].compactMap { $0 }.joined(separator: " "))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let r {
                    GroupBox("Image") {
                        VStack(alignment: .leading, spacing: 4) {
                            InfoRow(label: "Size", value: "\(r.instance.columns) × \(r.instance.rows)" + (r.instance.isMultiFrame ? ", \(r.instance.frameCount) frames" : ""))
                            InfoRow(label: "Pixel spacing", value: r.instance.pixelSpacing(frame: r.frame).map { String(format: "%.4g × %.4g mm", $0.0, $0.1) } ?? "Uncalibrated")
                            InfoRow(label: "Thickness", value: r.plane?.thickness.map { String(format: "%.2f mm", $0) } ?? "")
                            InfoRow(label: "Position", value: r.plane.map { String(format: "%.1f, %.1f, %.1f", $0.position.x, $0.position.y, $0.position.z) } ?? "")
                            InfoRow(label: "Bits", value: r.instance.pixel.map { "\($0.bitsStored)/\($0.bitsAllocated) \($0.signed ? "signed" : "unsigned")" } ?? "")
                            InfoRow(label: "Photometric", value: r.instance.pixel?.photometric ?? "")
                            InfoRow(label: "Rescale", value: String(format: "%g × v + %g", r.attributes.rescaleSlope, r.attributes.rescaleIntercept))
                            InfoRow(label: "Syntax", value: r.instance.transferSyntax.name)
                            InfoRow(label: "File", value: r.instance.url.lastPathComponent)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Button("Show DICOM Tags") { TagBrowserWindow.show(ref: r) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.instance.url]) }
                    }
                    .controlSize(.small)
                }
            } else {
                Text("No image selected").foregroundStyle(.secondary)
            }
        }
        .id(tick)
    }
}

private struct DisplayPane: View {
    @ObservedObject var session: ViewerSession
    let tick: Int
    @State private var center: Double = 0
    @State private var width: Double = 0

    var body: some View {
        let s = session.activeState
        VStack(alignment: .leading, spacing: 14) {
            if let s, s.current != nil || session.active?.mpr != nil {
                GroupBox("Window") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Level").frame(width: 44, alignment: .leading)
                            TextField("", value: Binding(get: { s.display.windowCenter }, set: { v in session.applyToActive { $0.display.windowCenter = v; $0.display.windowName = nil } }), format: .number.precision(.fractionLength(0...2)))
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("Width").frame(width: 44, alignment: .leading)
                            TextField("", value: Binding(get: { s.display.windowWidth }, set: { v in session.applyToActive { $0.display.windowWidth = max(0.001, v); $0.display.windowName = nil } }), format: .number.precision(.fractionLength(0...2)))
                                .textFieldStyle(.roundedBorder)
                        }
                        Menu("Presets") {
                            Button("Default") { session.applyDefaultWindow() }
                            Button("Full dynamic") { session.applyFullDynamic() }
                            Divider()
                            ForEach(WindowPreset.presets(for: s.series?.modality ?? "CT")) { p in
                                Button("\(p.name) (\(Int(p.center))/\(Int(p.width)))") { session.applyPreset(p) }
                            }
                        }
                        Toggle("Negative", isOn: Binding(get: { s.display.negative }, set: { v in session.applyToActive { $0.display.negative = v } }))
                    }
                }
                GroupBox("Appearance") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Color map", selection: Binding(get: { s.display.colormap }, set: { v in session.applyToActive { $0.display.colormap = v } })) {
                            ForEach(Colormap.allCases) { c in Text(c.title).tag(c) }
                        }
                        Picker("Filter", selection: Binding(get: { s.display.filter }, set: { v in session.applyToActive { $0.display.filter = v } })) {
                            Text("None").tag(0)
                            ForEach(1..<DisplayState.filterNames.count, id: \.self) { i in Text(DisplayState.filterNames[i]).tag(i) }
                        }
                        Toggle("Smooth interpolation", isOn: Binding(get: { s.display.interpolate }, set: { v in session.applyToActive { $0.display.interpolate = v } }))
                        HStack {
                            Button { session.windowController?.rotateCCW(nil) } label: { Image(systemName: "rotate.left") }.help("Rotate 90° counterclockwise")
                            Button { session.windowController?.rotateCW(nil) } label: { Image(systemName: "rotate.right") }.help("Rotate 90° clockwise")
                            Button { session.windowController?.flipHorizontal(nil) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.help("Flip horizontal")
                            Button { session.windowController?.flipVertical(nil) } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }.help("Flip vertical")
                            Spacer()
                            Button("Reset") { session.windowController?.clearTransformations(nil) }
                        }
                    }
                }
                if s.imageCount > 1 {
                    GroupBox("Cine") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button { session.toggleCine() } label: { Image(systemName: s.cine.playing ? "pause.fill" : "play.fill") }
                                Slider(value: Binding(get: { s.cine.fps }, set: { v in session.applyToActive { $0.cine.fps = v } }), in: 1...60)
                                Text("\(Int(s.cine.fps)) fps").monospacedDigit().frame(width: 48)
                            }
                            Slider(value: Binding(get: { Double(s.index) }, set: { v in
                                s.setIndex(Int(v)); session.viewportImageChanged(s)
                            }), in: 0...Double(max(1, s.imageCount - 1)), step: 1)
                            Text("Image \(s.index + 1) of \(s.imageCount)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if s.subtraction.enabled {
                    GroupBox("Subtraction") {
                        VStack(alignment: .leading, spacing: 8) {
                            Stepper("Mask image: \(s.subtraction.maskIndex + 1)", value: Binding(get: { s.subtraction.maskIndex }, set: { v in session.applyToActive { $0.subtraction.maskIndex = max(0, min($0.imageCount - 1, v)) } }))
                            HStack {
                                Button("Use Current as Mask") { session.windowController?.useCurrentAsMask(nil) }
                                Button("Auto Pixel Shift") { session.windowController?.autoPixelShift(nil) }
                            }
                            Text(String(format: "Shift: %.1f, %.1f px", s.subtraction.shift.x, s.subtraction.shift.y)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let f = s.fusion {
                    GroupBox("Fusion") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(f.series.seriesDescription).font(.caption)
                            HStack { Text("Opacity"); Slider(value: Binding(get: { f.opacity }, set: { f.opacity = $0; session.active?.needsRedraw() }), in: 0...1) }
                            Picker("Color map", selection: Binding(get: { f.colormap }, set: { f.colormap = $0; session.active?.needsRedraw() })) {
                                ForEach(Colormap.allCases) { c in Text(c.title).tag(c) }
                            }
                            HStack { Text("Upper"); Slider(value: Binding(get: { f.windowCenter + f.windowWidth / 2 }, set: { v in
                                let lo = f.windowCenter - f.windowWidth / 2; f.windowWidth = max(1e-3, v - lo); f.windowCenter = lo + f.windowWidth / 2; session.active?.needsRedraw()
                            }), in: 0...max(1, f.volume.maxValue)) }
                            HStack { Text("Lower"); Slider(value: Binding(get: { f.windowCenter - f.windowWidth / 2 }, set: { v in
                                let hi = f.windowCenter + f.windowWidth / 2; f.windowWidth = max(1e-3, hi - v); f.windowCenter = v + f.windowWidth / 2; session.active?.needsRedraw()
                            }), in: 0...max(1, f.volume.maxValue)) }
                            Button("Remove Fusion") { s.fusion = nil; session.active?.needsRedraw() }
                        }
                    }
                }
            } else {
                Text("No image selected").foregroundStyle(.secondary)
            }
        }
        .id(tick)
    }
}

private struct MeasurementsPane: View {
    @ObservedObject var session: ViewerSession
    let tick: Int

    var body: some View {
        let v = session.active
        let list = v?.measurements ?? []
        VStack(alignment: .leading, spacing: 10) {
            if list.isEmpty {
                Text("No measurements on this image.").foregroundStyle(.secondary)
                Text("Choose a tool from the Measure menu in the toolbar.").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(list) { m in
                let lines = v?.mpr != nil ? (v?.mprController?.describe(m, plane: v!.mpr!) ?? []) : MeasurementCalculator.describe(m, ref: v?.state.current, frame: v?.frame2D, calibration: v.flatMap { session.calibration(for: $0) })
                HStack(alignment: .top) {
                    Image(systemName: Tool(rawValue: m.kind.rawValue)?.symbol ?? "ruler").foregroundStyle(Color(nsColor: m.style.color.nsColor)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Tool(rawValue: m.kind.rawValue)?.title ?? m.kind.rawValue).font(.system(size: 11.5, weight: .medium))
                        ForEach(lines, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    Spacer()
                    Button { v?.measurements.removeAll { $0.id == m.id }; session.measurementsChanged() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(v?.selectedMeasurement == m.id ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
                .onTapGesture { v?.selectedMeasurement = m.id }
            }
            let all = session.allMeasurements
            if !all.isEmpty {
                Divider()
                Text("\(all.count) measurement\(all.count == 1 ? "" : "s") in this window").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy as Text") { MeasurementCalculations.copyAllAsText(session: session) }
                    Button("Export CSV…") { MeasurementCalculations.exportCSV(session: session) }
                }
                .controlSize(.small)
            }
        }
        .id(tick)
    }
}
