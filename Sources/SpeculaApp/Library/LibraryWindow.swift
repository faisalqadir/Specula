import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DICOMCore

enum DateFilter: String, CaseIterable, Identifiable {
    case all = "All Dates", today = "Today", yesterday = "Since Yesterday", week = "Last Week", month = "Last Month", threeMonths = "Last 3 Months", year = "Last Year"
    var id: String { rawValue }
    var since: Date? {
        let cal = Calendar.current, now = Date()
        switch self {
        case .all: return nil
        case .today: return cal.startOfDay(for: now)
        case .yesterday: return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))
        case .week: return cal.date(byAdding: .day, value: -7, to: now)
        case .month: return cal.date(byAdding: .month, value: -1, to: now)
        case .threeMonths: return cal.date(byAdding: .month, value: -3, to: now)
        case .year: return cal.date(byAdding: .year, value: -1, to: now)
        }
    }
}

final class LibraryModel: ObservableObject {
    @Published var studies: [LibraryStudy] = []
    @Published var selection = Set<LibraryStudy.ID>()
    @Published var search = "" { didSet { reload() } }
    @Published var dateFilter: DateFilter = .all { didSet { reload() } }
    @Published var series: [LibrarySeries] = []
    @Published var importing: LoadProgress?
    @Published var error: String?
    @Published var sortOrder = [KeyPathComparator(\LibraryStudy.studyDate, order: .reverse)]
    let db: LibraryDatabase?
    private var loader: DICOMLoader?

    init() {
        db = LibraryDatabase.shared
        if db == nil { error = "The library database could not be opened at \(Preferences.shared.libraryPath)." }
        reload()
    }

    func reload() {
        guard let db else { return }
        studies = db.studies(search: search, since: dateFilter.since)
        updateSeries()
    }

    func updateSeries() {
        guard let db, selection.count == 1, let id = selection.first else { series = []; return }
        series = db.series(study: id)
    }

    var summary: String {
        guard let s = db?.summary else { return "" }
        return "Studies: \(s.studies)  Images: \(s.images)  Size: \(ByteCountFormatter.string(fromByteCount: s.size, countStyle: .file))"
    }

    func importURLs(_ urls: [URL], copy: Bool = Preferences.shared.importCopiesFiles) {
        guard let db, !urls.isEmpty else { return }
        let loader = DICOMLoader()
        self.loader = loader
        var all: [Instance] = []
        loader.load(urls: urls, passwordProvider: { _ in nil }, batch: { insts in all += insts }, progress: { [weak self] p in
            self?.importing = p.done ? nil : p
        }, completion: { [weak self] _ in
            let list = all
            DispatchQueue.global(qos: .userInitiated).async {
                db.importInstances(list, copy: copy)
                // thumbnails
                var bySeries: [String: [Instance]] = [:]
                for i in list where i.kind == .image { bySeries[i.seriesUID, default: []].append(i) }
                for (uid, insts) in bySeries {
                    let mid = insts.sorted { ($0.instanceNumber ?? 0) < ($1.instanceNumber ?? 0) }[insts.count / 2]
                    let ref = ImageRef(instance: mid, frame: mid.frameCount / 2)
                    if let f = try? FrameCache.shared.decode(ref), let img = ThumbnailGenerator.render(f, ref: ref, size: 96),
                       let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) {
                        db.setThumbnail(seriesUID: uid, png: png)
                    }
                }
                DispatchQueue.main.async { self?.importing = nil; self?.reload() }
            }
        })
    }

    func cancelImport() { loader?.cancel() }

    func open(_ ids: [Int64], target: OpenTarget) {
        guard let db else { return }
        let urls = db.files(studies: ids)
        guard !urls.isEmpty else { return }
        switch target {
        case .newWindow:
            let wc = ViewerWindowController()
            wc.showWindow(nil)
            wc.session.open(urls: urls)
        case .activeWindow:
            if let wc = ViewerWindowController.all.last { wc.window?.makeKeyAndOrderFront(nil); wc.session.open(urls: urls) } else { open(ids, target: .newWindow) }
        case .separate:
            for id in ids { open([id], target: .newWindow) }
        }
        reload()
    }

    enum OpenTarget { case newWindow, activeWindow, separate }

    func delete(_ ids: [Int64]) {
        db?.delete(studies: ids)
        selection.removeAll()
        reload()
    }

    func exportCSV(to url: URL) {
        let header = ["Patient name", "Patient ID", "Birth date", "Sex", "Study date", "Description", "Modalities", "Accession", "Images", "Size", "Keywords"]
        let rows = studies.map { s in [s.patientName, s.patientID, DICOMDate.formatDate(s.birthDate), s.sex, DICOMDate.formatDate(s.studyDate), s.description, s.modalities, s.accession, "\(s.images)", "\(s.size)", s.keywords] }
        let csv = ([header] + rows).map { $0.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") }.joined(separator: "\n")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @State private var keywordPrompt = false
    @State private var keyword = ""

    var body: some View {
        VSplitView {
            studyTable
            seriesStrip.frame(minHeight: 120, idealHeight: 150)
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search all studies")
        .safeAreaInset(edge: .bottom) { statusBar }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var urls: [URL] = []
            let g = DispatchGroup()
            for p in providers { g.enter(); _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { urls.append(u) } }; g.leave() } }
            g.notify(queue: .main) { model.importURLs(urls) }
            return true
        }
        .alert("Add keyword", isPresented: $keywordPrompt) {
            TextField("Keyword", text: $keyword)
            Button("Add") { model.db?.addKeyword(keyword, to: Array(model.selection)); keyword = ""; model.reload() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Existing keywords: \(model.db?.allKeywords.joined(separator: ", ") ?? "")") }
    }

    @ViewBuilder var studyTable: some View {
            Table(model.studies, selection: $model.selection) {
            TableColumn("Patient") { (s: LibraryStudy) in Text(s.patientName).fontWeight(.medium) }.width(min: 120, ideal: 180)
            TableColumn("Patient ID") { (s: LibraryStudy) in Text(s.patientID) }.width(min: 60, ideal: 90)
            TableColumn("Birth Date") { (s: LibraryStudy) in Text(DICOMDate.formatDate(s.birthDate)) }.width(min: 70, ideal: 80)
            TableColumn("Study Date") { (s: LibraryStudy) in Text(DICOMDate.formatDate(s.studyDate)) }.width(min: 70, ideal: 80)
            TableColumn("Modality") { (s: LibraryStudy) in Text(s.modalities) }.width(min: 40, ideal: 60)
            TableColumn("Description") { (s: LibraryStudy) in Text(s.description) }.width(min: 100, ideal: 200)
            TableColumn("Accession") { (s: LibraryStudy) in Text(s.accession) }.width(min: 60, ideal: 90)
            TableColumn("Images") { (s: LibraryStudy) in Text("\(s.images) · \(ByteCountFormatter.string(fromByteCount: s.size, countStyle: .file))") }.width(min: 60, ideal: 110)
            TableColumn("Keywords") { (s: LibraryStudy) in Text(s.keywords) }.width(min: 60, ideal: 120)
        }
        .contextMenu(forSelectionType: LibraryStudy.ID.self) { ids in
            Button("Open in New Window") { model.open(Array(ids), target: .newWindow) }
            Button("Add to Active Window") { model.open(Array(ids), target: .activeWindow) }
            Button("Open in Separate Windows") { model.open(Array(ids), target: .separate) }
            Divider()
            Button("Add Keyword…") { model.selection = ids; keywordPrompt = true }
            Button("Remove Keywords") { model.db?.removeKeywords(from: Array(ids)); model.reload() }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array((model.db?.files(studies: Array(ids)) ?? []).prefix(100))) }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete(Array(ids)) }
        } primaryAction: { ids in model.open(Array(ids), target: .newWindow) }
        .onChange(of: model.selection) { _, _ in model.updateSeries() }
        .frame(minHeight: 220)

    }

    var statusBar: some View {
            HStack {
                if let p = model.importing {
                    ProgressView().controlSize(.small)
                    Text("\(p.phase) \(p.loaded)/\(p.found)").font(.caption)
                    Button("Cancel Import") { model.cancelImport() }.controlSize(.small)
                } else if let e = model.error {
                    Text(e).foregroundStyle(.red).font(.caption)
                } else {
                    Text(model.studies.isEmpty ? "The library is empty. Import a folder, disc or ZIP archive to begin." : model.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $model.dateFilter) { ForEach(DateFilter.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 160).controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
            }

    var seriesStrip: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                if model.series.isEmpty {
                    Text(model.selection.count > 1 ? "\(model.selection.count) studies selected" : "Select a study to see its series").foregroundStyle(.secondary).padding()
                }
                ForEach(model.series) { s in
                    VStack(spacing: 4) {
                        Group {
                            if let d = s.thumbnail, let img = NSImage(data: d) { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit) }
                            else { Image(systemName: "photo").foregroundStyle(.secondary) }
                        }
                        .frame(width: 84, height: 84).background(Color.black).clipShape(RoundedRectangle(cornerRadius: 5))
                        Text(s.description.isEmpty ? "Series \(s.number.map(String.init) ?? "")" : s.description).font(.caption).lineLimit(2).frame(width: 96)
                        Text("\(s.modality) · \(s.images)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .onTapGesture(count: 2) {
                        guard let urls = model.db?.files(series: s.id), !urls.isEmpty else { return }
                        let wc = ViewerWindowController(); wc.showWindow(nil); wc.session.open(urls: urls)
                    }
                }
            }
            .padding(10)
        }
    }

    func confirmDelete(_ ids: [Int64]) {
        let a = NSAlert()
        a.messageText = "Delete studies"
        a.informativeText = "Are you sure you want to permanently delete \(ids.count) selected stud\(ids.count == 1 ? "y" : "ies")? Copied files are removed from the library folder."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { model.delete(ids) }
    }
}

final class LibraryWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = LibraryWindowController()
    let model = LibraryModel()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Library"
        w.subtitle = Preferences.shared.libraryPath
        w.toolbarStyle = .unified
        w.setFrameAutosaveName("SpeculaLibrary")
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.contentViewController = NSHostingController(rootView: LibraryView(model: model))
        let tb = NSToolbar(identifier: "SpeculaLibraryToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        w.toolbar = tb
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func importFiles(_ urls: [URL]) { model.importURLs(urls) }

    private enum TB {
        static let importItem = NSToolbarItem.Identifier("libImport")
        static let open = NSToolbarItem.Identifier("libOpen")
        static let delete = NSToolbarItem.Identifier("libDelete")
        static let pacs = NSToolbarItem.Identifier("libPACS")
        static let more = NSToolbarItem.Identifier("libMore")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [TB.importItem, TB.open, TB.delete, .flexibleSpace, TB.pacs, TB.more] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func img(_ n: String) -> NSImage { NSImage(systemSymbolName: n, accessibilityDescription: nil) ?? NSImage() }
        switch id {
        case TB.importItem:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.label = "Import"; i.image = img("square.and.arrow.down"); i.toolTip = "Import DICOM files into the library"
            i.target = self; i.action = #selector(importFolder(_:))
            let m = NSMenu()
            for (t, s) in [("Import DICOM Folder or Files…", #selector(importFolder(_:))), ("Import CD/DVD Disc", #selector(importDisc(_:))), ("Import ZIP Archive…", #selector(importFolder(_:)))] {
                let it = NSMenuItem(title: t, action: s, keyEquivalent: ""); it.target = self; m.addItem(it)
            }
            m.addItem(.separator())
            let copy = NSMenuItem(title: "Copy Files into Library", action: #selector(toggleCopy(_:)), keyEquivalent: ""); copy.target = self; m.addItem(copy)
            i.menu = m
            return i
        case TB.open:
            let i = NSToolbarItem(itemIdentifier: id); i.label = "Open"; i.image = img("rectangle.portrait.on.rectangle.portrait"); i.target = self; i.action = #selector(openSelected(_:)); i.toolTip = "Open selected studies"
            return i
        case TB.delete:
            let i = NSToolbarItem(itemIdentifier: id); i.label = "Delete"; i.image = img("trash"); i.target = self; i.action = #selector(deleteSelected(_:))
            return i
        case TB.pacs:
            let i = NSToolbarItem(itemIdentifier: id); i.label = "PACS"; i.image = img("network"); i.action = #selector(AppDelegate.showPACS(_:)); i.toolTip = "Search and download studies from PACS"
            return i
        case TB.more:
            let i = NSMenuToolbarItem(itemIdentifier: id); i.label = "More"; i.image = img("ellipsis.circle"); i.showsIndicator = false
            let m = NSMenu()
            for (t, s) in [("Export Study List to CSV…", #selector(exportCSV(_:))), ("Anonymize Selected Studies…", #selector(anonymizeSelected(_:))), ("Optimize Database", #selector(optimize(_:))), ("Show Library Folder", #selector(showFolder(_:)))] {
                let it = NSMenuItem(title: t, action: s, keyEquivalent: ""); it.target = self; m.addItem(it)
            }
            i.menu = m
            return i
        default: return nil
        }
    }

    @objc func importFolder(_ s: Any?) {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = true; p.allowsMultipleSelection = true
        p.message = "Choose DICOM folders, files, DICOMDIR or ZIP archives to import"
        p.beginSheetModal(for: window!) { [weak self] r in if r == .OK { self?.model.importURLs(p.urls) } }
    }

    @objc func importDisc(_ s: Any?) {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsEjectableKey], options: [.skipHiddenVolumes]) ?? []
        if let disc = vols.first(where: { (try? $0.resourceValues(forKeys: [.volumeIsEjectableKey]).volumeIsEjectable) == true }) { model.importURLs([disc]) } else { importFolder(s) }
    }

    @objc func toggleCopy(_ s: NSMenuItem) { Preferences.shared.importCopiesFiles.toggle() }
    @objc func openSelected(_ s: Any?) { model.open(Array(model.selection), target: .newWindow) }
    @objc func deleteSelected(_ s: Any?) { guard !model.selection.isEmpty else { return }; LibraryView(model: model).confirmDelete(Array(model.selection)) }

    @objc func exportCSV(_ s: Any?) {
        let p = NSSavePanel(); p.allowedContentTypes = [.commaSeparatedText]; p.nameFieldStringValue = "Library.csv"
        p.beginSheetModal(for: window!) { [weak self] r in if r == .OK, let u = p.url { self?.model.exportCSV(to: u) } }
    }

    @objc func anonymizeSelected(_ s: Any?) {
        let urls = model.db?.files(studies: Array(model.selection)) ?? []
        guard !urls.isEmpty else { return }
        AnonymizerWindow.show(urls: urls)
    }

    @objc func optimize(_ s: Any?) {
        let ok = model.db?.optimize() ?? false
        let a = NSAlert(); a.messageText = ok ? "The database file has been optimized." : "The database file could not be optimized."; a.beginSheetModal(for: window!)
    }

    @objc func showFolder(_ s: Any?) { NSWorkspace.shared.open(URL(fileURLWithPath: Preferences.shared.libraryPath)) }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleCopy(_:)) { item.state = Preferences.shared.importCopiesFiles ? .on : .off }
        return true
    }
}
