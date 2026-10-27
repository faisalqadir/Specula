import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DICOMCore

struct SidebarView: View {
    @ObservedObject var session: ViewerSession
    @ObservedObject var collection: StudyCollection
    @State private var activeSeriesID: UUID?
    @State private var refresh = 0

    init(session: ViewerSession) {
        self.session = session
        self.collection = session.collection
    }

    var body: some View {
        Group {
            if collection.studies.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text("No Studies").font(.headline).foregroundStyle(.secondary)
                    Text("Drop DICOM files or folders here").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(collection.studies) { study in
                            StudySection(study: study, session: session, activeSeriesID: activeSeriesID)
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: activeSeriesID) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    if let u { DispatchQueue.main.async { urls.append(u) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) { session.open(urls: urls) }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeViewportChanged)) { _ in activeSeriesID = session.activeState?.series?.id }
        .onReceive(NotificationCenter.default.publisher(for: .viewportImageChanged)) { _ in
            if activeSeriesID != session.activeState?.series?.id { activeSeriesID = session.activeState?.series?.id }
        }
        .onReceive(session.$viewports) { _ in activeSeriesID = session.activeState?.series?.id }
        .safeAreaInset(edge: .bottom) {
            if let p = session.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.phase).font(.caption)
                        Text("\(p.loaded) of \(p.found) files").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { session.cancelLoading() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel loading")
                }
                .padding(10)
                .background(.bar)
            }
        }
    }
}

private struct StudySection: View {
    @ObservedObject var study: Study
    let session: ViewerSession
    let activeSeriesID: UUID?
    @State private var expanded = true

    var body: some View {
        Section(isExpanded: $expanded) {
            ForEach(study.seriesSorted()) { s in
                SeriesRow(series: s, session: session, isActive: s.id == activeSeriesID)
                    .id(s.id)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.hidePatientData ? "Patient" : (study.patientName.isEmpty ? "Unnamed" : study.patientName))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(DICOMDate.formatDate(study.studyDate))
                    if !study.modalities.isEmpty { Text("·"); Text(study.modalities) }
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                if !study.studyDescription.isEmpty {
                    Text(study.studyDescription).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .textCase(nil)
            .padding(.vertical, 2)
            .contextMenu {
                Button("Close Study") { session.collection.remove(study: study); session.redrawAll() }
            }
        }
    }
}

private struct SeriesRow: View {
    @ObservedObject var series: Series
    let session: ViewerSession
    let isActive: Bool

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.command) { session.openInNewPanel(series) } else { session.show(series) }
        } label: { rowContent }
        .buttonStyle(.plain)
        .accessibilityLabel("\(series.modality) \(series.seriesDescription), \(countText)")
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if series.volumeCandidate { MPRWindowController.open(series: series, session: session, mode: .mpr) }
        })
        .onDrag {
            let p = NSItemProvider()
            p.registerDataRepresentation(forTypeIdentifier: "com.specula.series", visibility: .ownProcess) { done in
                done(series.id.uuidString.data(using: .utf8), nil)
                return nil
            }
            return p
        }
        .help("Click to show in the active panel. ⌘-click opens it in a new panel; double-click opens MPR; drag onto any panel.")
        .contextMenu { menu }
    }

    var rowContent: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let t = series.thumbnail {
                        Image(nsImage: t).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: icon).font(.system(size: 20, weight: .light)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 64)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(isActive ? Color.accentColor : Color.white.opacity(0.08), lineWidth: isActive ? 2 : 1))
                if Preferences.shared.showSeriesNumbers, let n = series.number {
                    Text("\(n)").font(.system(size: 9, weight: .bold)).padding(.horizontal, 3).background(.black.opacity(0.6)).foregroundStyle(.white).padding(3)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(series.seriesDescription.isEmpty ? "Series \(series.number.map(String.init) ?? "—")" : series.seriesDescription)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(series.modality)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.18)))
                    Text(countText).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder var menu: some View {
            Button("Show in Active Panel") { session.show(series) }
            Button("Open in New Panel") { session.openInNewPanel(series) }
            Button("Open in New Window") {
                let wc = ViewerWindowController()
                wc.showWindow(nil)
                wc.session.open(urls: series.instances.map(\.url))
            }
            Divider()
            Button("3D MPR") { MPRWindowController.open(series: series, session: session, mode: .mpr) }.disabled(!series.volumeCandidate)
            Button("3D Volume Rendering") { MPRWindowController.open(series: series, session: session, mode: .vr) }.disabled(!series.volumeCandidate)
            Divider()
            Button("Show DICOM Tags") { if let r = series.images.first { TagBrowserWindow.show(ref: r) } }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(series.instances.prefix(200).map(\.url)) }
            Button("Split Series") {
                let parts = session.collection.split(series)
                if let f = parts.first { session.show(f) }
            }
            Menu("Sort Images By") {
                ForEach(SortMode.allCases, id: \.self) { m in
                    Button(m.title) { series.sortMode = m; series.rebuildImages(); session.redrawAll() }
                }
                Divider()
                Button("Ascending") { series.ascending = true; series.rebuildImages(); session.redrawAll() }
                Button("Descending") { series.ascending = false; series.rebuildImages(); session.redrawAll() }
            }
    }

    var icon: String {
        switch series.kind {
        case .structuredReport: return "doc.text"
        case .pdf: return "doc.richtext"
        case .video: return "film"
        default: return "photo"
        }
    }

    var countText: String {
        switch series.kind {
        case .structuredReport: return "Report"
        case .pdf: return "PDF document"
        case .video: return "Video"
        default:
            let n = series.imageCount
            return n == 1 ? "1 image" : "\(n) images"
        }
    }
}

struct StatusBarView: View {
    @ObservedObject var session: ViewerSession

    var body: some View {
        HStack(spacing: 10) {
            if let p = session.loading {
                ProgressView(value: p.found > 0 ? Double(p.loaded) / Double(max(p.found, 1)) : nil).progressViewStyle(.linear).frame(width: 120).controlSize(.small)
                Text("\(p.phase) \(p.loaded)/\(p.found)").foregroundStyle(.secondary)
            } else {
                Text(hint).foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.tool.title).foregroundStyle(.secondary)
            if session.syncMode != .disabled { Image(systemName: "link").foregroundStyle(.secondary).help("Synchronization \(session.syncMode.rawValue)") }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    var hint: String {
        if session.tool.isMeasurement {
            switch session.tool {
            case .closedPolygon, .openPolygon: return "Click to add points, double-click or press Return to finish."
            case .angle: return "Drag the first arm, then click to place the second."
            case .cobbAngle: return "Drag the first line, then drag the second line."
            case .deviation: return "Drag a reference line, then click a point."
            default: return "Drag on the image to measure. Select a measurement and press ⌫ to delete it."
            }
        }
        return "Scroll to browse · ⌥-drag window · ⇧-drag pan · ⌘-drag or pinch to zoom · double-click to maximize a panel"
    }
}

struct EmptyStateView: View {
    @ObservedObject var session: ViewerSession

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(.white.opacity(0.55))
            Text("Open a DICOM study").font(.title3.weight(.medium)).foregroundStyle(.white.opacity(0.85))
            Text("Drag files, folders, ZIP archives or a DICOMDIR here,\nor use the buttons below.").multilineTextAlignment(.center).font(.callout).foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 10) {
                Button("Open…") { session.windowController?.openDocument(nil) }.keyboardShortcut("o")
                Button("Library") { NSApp.sendAction(#selector(AppDelegate.showLibrary(_:)), to: nil, from: nil) }
                Button("PACS") { NSApp.sendAction(#selector(AppDelegate.showPACS(_:)), to: nil, from: nil) }
            }
            .controlSize(.large)
        }
        .padding(30)
    }
}
