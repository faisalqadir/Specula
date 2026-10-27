import AppKit
import SwiftUI
import DICOMCore
import DICOMNet

final class PACSSearchModel: ObservableObject {
    @Published var query = PACSQuery()
    @Published var results: [PACSStudy] = []
    @Published var selection = Set<PACSStudy.ID>()
    @Published var sortOrder = [KeyPathComparator(\PACSStudy.studyDate, order: .reverse)]
    @Published var searching = false
    @Published var status = ""
    @Published var showSeries = false
    @Published var series: [PACSSeries] = []
    @Published var seriesSelection = Set<PACSSeries.ID>()
    @Published var seriesStatus = ""
    @Published var showConfiguration = false
    private var cancel: CancelToken?
    let service = PACSService.shared

    static let modalities = ["CR", "CT", "DX", "ES", "IO", "MG", "MR", "NM", "OT", "PT", "RF", "SC", "SR", "US", "XA"]

    var selectedNodes: [DICOMNode] {
        let ids = Set(service.configuration.selectedNodeIDs)
        let nodes = service.configuration.nodes
        let chosen = nodes.filter { ids.contains($0.id) }
        return chosen.isEmpty ? nodes : chosen
    }

    var selectedStudies: [PACSStudy] { results.filter { selection.contains($0.id) } }

    func search() {
        guard !service.configuration.nodes.isEmpty else { askToConfigure(); return }
        cancel?.cancel()
        let token = CancelToken()
        cancel = token
        searching = true
        status = "Searching..."
        results = []
        selection = []
        series = []
        service.search(query, nodes: selectedNodes, cancel: token, update: { [weak self] list in
            guard let self, self.cancel === token else { return }
            self.results = list.sorted(using: self.sortOrder)
        }, completion: { [weak self] errors in
            guard let self, self.cancel === token else { return }
            self.searching = false
            let n = self.results.count
            self.status = n == 1 ? "1 study found" : "\(n) studies found"
            if !errors.isEmpty { self.status += " — " + errors.joined(separator: "; ") }
        })
    }

    func stop() {
        cancel?.cancel()
        searching = false
        service.cancelAll()
        status = "Cancelled"
    }

    func clear() {
        query = PACSQuery()
        results = []
        series = []
        status = ""
    }

    func findAllStudiesOfPatient() {
        guard let s = selectedStudies.first, !s.patientID.isEmpty else { return }
        query = PACSQuery()
        query.patientID = s.patientID
        let saved = service.configuration.wildcards
        service.configuration.wildcards = .none
        search()
        service.configuration.wildcards = saved
    }

    func loadSeries() {
        guard showSeries, let s = selectedStudies.first, selection.count == 1 else { series = []; seriesStatus = ""; return }
        seriesStatus = "Searching..."
        series = []
        service.series(of: s) { [weak self] r in
            guard let self, self.selectedStudies.first?.id == s.id else { return }
            switch r {
            case .success(let list): self.series = list; self.seriesStatus = "\(list.count) series"
            case .failure(let e): self.seriesStatus = e.localizedDescription
            }
        }
    }

    func download(_ target: DownloadTarget, studies: [PACSStudy]? = nil) {
        let list = studies ?? selectedStudies
        guard !list.isEmpty else { return }
        let chosenSeries = series.filter { seriesSelection.contains($0.id) }
        if list.count == 1 && !chosenSeries.isEmpty {
            service.download(list, series: chosenSeries, target: target)
        } else if case .separateWindow = target {
            service.download(list, target: .separateWindow)
        } else {
            service.download(list, target: target)
        }
        if service.configuration.importToLibrary == false, case .libraryOnly = target {}
        PACSDownloadsWindowController.shared.showWindow(nil)
    }

    /// "Download": into the library only when importing, otherwise into a new window.
    func defaultDownload() {
        download(service.configuration.importToLibrary ? .libraryOnly : .newWindow(UUID()))
    }

    func addToActiveWindow() {
        let wc = ViewerWindowController.all.first { $0.window?.isMainWindow == true } ?? ViewerWindowController.all.last
        download(.window(wc.map(ObjectIdentifier.init)))
    }

    private func askToConfigure() {
        let a = NSAlert()
        a.messageText = "No PACS locations"
        a.informativeText = "You need to configure PACS locations before using search & download feature. Would you like to do it now?"
        a.addButton(withTitle: "Configure…")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { showConfiguration = true }
    }

    // MARK: Presets

    func savePreset() {
        let a = NSAlert()
        a.messageText = "Add PACS search preset"
        a.informativeText = "The date range, modalities and selected PACS locations are saved."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Preset name"
        a.accessoryView = field
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        service.configuration.presets.append(PACSSearchPreset(name: name, datePreset: query.datePreset, modalities: query.modalities.sorted(), nodeIDs: service.configuration.selectedNodeIDs))
    }

    func apply(_ p: PACSSearchPreset) {
        query.datePreset = p.datePreset
        query.modalities = Set(p.modalities)
        service.configuration.selectedNodeIDs = p.nodeIDs
        search()
    }
}

struct PACSSearchView: View {
    @ObservedObject var model: PACSSearchModel
    @ObservedObject var service = PACSService.shared

    var body: some View {
        VStack(spacing: 0) {
            filters
                .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if model.showSeries {
                VSplitView {
                    studyTable.frame(minHeight: 160)
                    seriesTable.frame(minHeight: 110, idealHeight: 180)
                }
            } else {
                studyTable
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 520)
        .toolbar { toolbar }
        .sheet(isPresented: $model.showConfiguration) {
            VStack(spacing: 0) {
                PACSSettingsView()
                Divider()
                HStack { Spacer(); Button("Done") { model.showConfiguration = false }.keyboardShortcut(.defaultAction) }.padding(12)
            }
            .frame(width: 680, height: 620)
        }
        .onChange(of: model.selection) { _, _ in model.loadSeries() }
        .onChange(of: model.showSeries) { _, _ in model.loadSeries() }
        .onChange(of: model.sortOrder) { _, o in model.results.sort(using: o) }
    }

    // MARK: Filters

    private func field(_ title: String, _ prompt: String, _ text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .onSubmit { model.search() }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    field("Patient name", "Enter patient name...", $model.query.patientName)
                    field("Patient ID", "Enter patient ID...", $model.query.patientID)
                    field("Accession number", "Enter accession number...", $model.query.accession)
                    field("Study description", "Enter study description...", $model.query.studyDescription)
                }
                GridRow {
                    field("Referring physician", "Enter referring physician...", $model.query.referring)
                    field("Performing physician", "Enter performing physician...", $model.query.performing)
                    field("Reading physician", "Enter reading physician...", $model.query.reading)
                    field("Institution name", "Enter institution name...", $model.query.institution)
                }
            }
            .labelsHidden()
            HStack(spacing: 10) {
                Menu {
                    ForEach(Array(DatePreset.groups.enumerated()), id: \.offset) { i, group in
                        if i > 0 { Divider() }
                        ForEach(group) { p in
                            Button { model.query.datePreset = p } label: {
                                if model.query.datePreset == p { Label(p.rawValue, systemImage: "checkmark") } else { Text(p.rawValue) }
                            }
                        }
                    }
                } label: { Label(model.query.datePreset.rawValue, systemImage: "calendar") }
                .fixedSize()
                if model.query.datePreset == .custom {
                    DatePicker("From", selection: $model.query.customFrom, displayedComponents: .date).labelsHidden()
                    Text("–").foregroundStyle(.secondary)
                    DatePicker("To", selection: $model.query.customTo, displayedComponents: .date).labelsHidden()
                }
                Divider().frame(height: 18)
                modalityChips
                Spacer(minLength: 0)
            }
        }
    }

    private var modalityChips: some View {
        HStack(spacing: 3) {
            chip("All", on: model.query.modalities.isEmpty) { model.query.modalities = [] }
                .help("All modalities")
            ForEach(PACSSearchModel.modalities, id: \.self) { m in
                chip(m, on: model.query.modalities.contains(m)) {
                    if model.query.modalities.contains(m) { model.query.modalities.remove(m) } else { model.query.modalities.insert(m) }
                }
            }
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: on ? .semibold : .regular)).frame(minWidth: 22)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : Color.secondary.opacity(0.12)))
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Tables

    private var studyTable: some View {
        Table(model.results, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Study date", value: \PACSStudy.studyDate) { (s: PACSStudy) in Text(s.dateDisplay).monospacedDigit() }
                .width(min: 90, ideal: 130)
            TableColumn("Patient name", value: \PACSStudy.patientName).width(min: 120, ideal: 190)
            TableColumn("Date of birth", value: \PACSStudy.birthDate) { (s: PACSStudy) in Text(DICOMDate.formatDate(s.birthDate)).monospacedDigit() }
                .width(min: 70, ideal: 90)
            TableColumn("Patient ID", value: \PACSStudy.patientID).width(min: 70, ideal: 110)
            TableColumn("Modality", value: \PACSStudy.modalities).width(min: 50, ideal: 70)
            TableColumn("Study description", value: \PACSStudy.studyDescription).width(min: 120, ideal: 220)
            TableColumn("Accession number", value: \PACSStudy.accession).width(min: 70, ideal: 110)
            TableColumn("Images", value: \PACSStudy.images) { (s: PACSStudy) in Text(s.imagesDisplay).monospacedDigit() }
                .width(min: 40, ideal: 55)
            TableColumn("Source", value: \PACSStudy.source).width(min: 70, ideal: 110)
        }
        .contextMenu(forSelectionType: PACSStudy.ID.self) { ids in
            if !ids.isEmpty {
                Button("Download") { model.selection = ids; model.defaultDownload() }
                Button("Add to Active Window") { model.selection = ids; model.addToActiveWindow() }
                Button("Download to New Window") { model.selection = ids; model.download(.newWindow(UUID())) }
                Button("Download to Separate Windows") { model.selection = ids; model.download(.separateWindow) }
                Divider()
                Button("Find All Studies of This Patient") { model.selection = ids; model.findAllStudiesOfPatient() }
                Button(model.showSeries ? "Hide Series" : "Show Series") { model.showSeries.toggle() }
            }
        } primaryAction: { ids in
            model.selection = ids
            model.download(.newWindow(UUID()))
        }
        .overlay {
            if model.results.isEmpty {
                if model.searching { ProgressView("Searching...") }
                else if service.configuration.nodes.isEmpty {
                    ContentUnavailableView {
                        Label("No PACS Locations", systemImage: "network")
                    } description: {
                        Text("Add the PACS devices you want to search and download studies from.")
                    } actions: {
                        Button("Show PACS Configuration…") { model.showConfiguration = true }
                    }
                } else {
                    ContentUnavailableView("Search PACS", systemImage: "magnifyingglass", description: Text("Enter search criteria and press Return."))
                }
            }
        }
    }

    private var seriesTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Series").font(.headline)
                Text(model.seriesStatus).foregroundStyle(.secondary).font(.caption)
                Spacer()
                Text("Select series to download only those.").foregroundStyle(.secondary).font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Table(model.series, selection: $model.seriesSelection) {
                TableColumn("#", value: \PACSSeries.number).width(min: 30, ideal: 40)
                TableColumn("Modality", value: \PACSSeries.modality).width(min: 50, ideal: 60)
                TableColumn("Series description", value: \PACSSeries.seriesDescription).width(min: 150, ideal: 300)
                TableColumn("Body part", value: \PACSSeries.bodyPart).width(min: 60, ideal: 90)
                TableColumn("Images") { (s: PACSSeries) in Text(s.images > 0 ? String(s.images) : "").monospacedDigit() }.width(min: 40, ideal: 60)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.searching { ProgressView().controlSize(.small) }
            Text(model.status).lineLimit(1).truncationMode(.tail)
            Spacer()
            Image(systemName: service.isListening ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(service.listenerError != nil ? Color.red : (service.isListening ? Color.green : Color.secondary))
                .help(service.listenerStatus)
            Toggle("Import to library", isOn: $service.configuration.importToLibrary)
                .toggleStyle(.checkbox)
                .help(service.configuration.importToLibrary
                      ? "Import to local archive is enabled. Studies will be stored permanently in the database."
                      : "Import to local archive is disabled. Studies will be deleted after the viewer is closed.")
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                Button { service.configuration.selectedNodeIDs = [] } label: {
                    if service.configuration.selectedNodeIDs.isEmpty { Label("All PACS locations", systemImage: "checkmark") } else { Text("All PACS locations") }
                }
                Divider()
                ForEach(service.configuration.nodes) { n in
                    Button { toggleNode(n) } label: {
                        if service.configuration.selectedNodeIDs.contains(n.id) { Label(n.description, systemImage: "checkmark") } else { Text(n.description) }
                    }
                }
                Divider()
                Button("PACS Configuration…") { model.showConfiguration = true }
            } label: {
                Label(nodeTitle, systemImage: "server.rack")
            }
            .help("PACS locations")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(service.configuration.presets) { p in Button(p.name) { model.apply(p) } }
                if !service.configuration.presets.isEmpty { Divider() }
                Button("Add Preset…") { model.savePreset() }
                if !service.configuration.presets.isEmpty {
                    Menu("Delete Preset") {
                        ForEach(service.configuration.presets) { p in Button(p.name) { service.configuration.presets.removeAll { $0.id == p.id } } }
                    }
                }
            } label: { Label("Presets", systemImage: "bookmark") }
            .help("PACS search presets")
            Button { model.clear() } label: { Label("Clear", systemImage: "xmark.circle") }.help("Clear")
            if model.searching || service.downloads.contains(where: { $0.state.isActive }) {
                Button { model.stop() } label: { Label("Cancel", systemImage: "stop.circle") }.help("Cancel search and downloads")
            }
            Button { model.search() } label: { Label("Search", systemImage: "magnifyingglass") }
                .keyboardShortcut(.return, modifiers: .command)
                .help("Search (⌘↩)")
            Menu {
                Button("Download") { model.defaultDownload() }
                Button("Add to Active Window") { model.addToActiveWindow() }
                Button("Download to New Window") { model.download(.newWindow(UUID())) }
                Button("Download to Separate Windows") { model.download(.separateWindow) }
            } label: { Label("Download", systemImage: "arrow.down.circle") } primaryAction: { model.defaultDownload() }
            .disabled(model.selection.isEmpty)
            .help("Download")
            Toggle(isOn: $model.showSeries) { Label("Series", systemImage: "rectangle.stack") }.help(model.showSeries ? "Hide series" : "Show series")
            Button { PACSDownloadsWindowController.shared.showWindow(nil) } label: { Label("Downloads", systemImage: "arrow.down.to.line.circle") }.help("Show downloads")
        }
    }

    private var nodeTitle: String {
        let sel = service.configuration.nodes.filter { service.configuration.selectedNodeIDs.contains($0.id) }
        if sel.isEmpty { return "All PACS locations" }
        return sel.count == 1 ? sel[0].description : "\(sel.count) locations"
    }

    private func toggleNode(_ n: DICOMNode) {
        var ids = service.configuration.selectedNodeIDs
        if let i = ids.firstIndex(of: n.id) { ids.remove(at: i) } else { ids.append(n.id) }
        service.configuration.selectedNodeIDs = ids
    }
}

final class PACSWindowController: NSWindowController {
    static let shared = PACSWindowController()
    let model = PACSSearchModel()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Search PACS"
        w.toolbarStyle = .unified
        w.setFrameAutosaveName("SpeculaPACS")
        w.isReleasedWhenClosed = false
        super.init(window: w)
        let host = NSHostingController(rootView: PACSSearchView(model: model))
        host.sceneBridgingOptions = [.toolbars, .title]
        w.contentViewController = host
        w.setContentSize(NSSize(width: 1180, height: 680))
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        if PACSService.shared.configuration.nodes.isEmpty { model.showConfiguration = true }
    }

    func showDownloads() { PACSDownloadsWindowController.shared.showWindow(nil) }
}

// MARK: - Downloads

struct PACSDownloadsView: View {
    @ObservedObject var service = PACSService.shared
    @State private var selection = Set<UUID>()

    var body: some View {
        Table(service.downloads, selection: $selection) {
            TableColumn("Patient (study date)") { (d: PACSDownload) in DownloadCell(job: d, kind: .title) }.width(min: 160, ideal: 240)
            TableColumn("Progress") { (d: PACSDownload) in DownloadCell(job: d, kind: .progress) }.width(min: 110, ideal: 170)
            TableColumn("Download time") { (d: PACSDownload) in DownloadCell(job: d, kind: .time) }.width(min: 60, ideal: 80)
            TableColumn("Bytes transferred") { (d: PACSDownload) in DownloadCell(job: d, kind: .bytes) }.width(min: 70, ideal: 100)
            TableColumn("Current speed") { (d: PACSDownload) in DownloadCell(job: d, kind: .speed) }.width(min: 70, ideal: 90)
            TableColumn("Average speed") { (d: PACSDownload) in DownloadCell(job: d, kind: .average) }.width(min: 70, ideal: 90)
            TableColumn("Files") { (d: PACSDownload) in DownloadCell(job: d, kind: .files) }.width(min: 60, ideal: 80)
            TableColumn("PACS location") { (d: PACSDownload) in DownloadCell(job: d, kind: .source) }.width(min: 80, ideal: 110)
            TableColumn("Error message") { (d: PACSDownload) in DownloadCell(job: d, kind: .error) }.width(min: 100, ideal: 240)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let jobs = service.downloads.filter { ids.contains($0.id) }
            Button("Cancel") { jobs.forEach(service.cancel) }.disabled(!jobs.contains { $0.state.isActive })
            Button("Retry") { jobs.forEach(service.retry) }.disabled(!jobs.contains { !$0.state.isActive && !$0.pushed })
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(jobs.flatMap { $0.files.prefix(1) }) }
                .disabled(jobs.allSatisfy { $0.files.isEmpty })
            Button("Open") {
                for j in jobs where !j.files.isEmpty {
                    let wc = ViewerWindowController(); wc.showWindow(nil); wc.session.open(urls: j.files, recordRecent: false)
                }
            }.disabled(jobs.allSatisfy { $0.files.isEmpty })
        } primaryAction: { ids in
            for j in service.downloads where ids.contains(j.id) && !j.files.isEmpty {
                let wc = ViewerWindowController(); wc.showWindow(nil); wc.session.open(urls: j.files, recordRecent: false)
            }
        }
        .overlay {
            if service.downloads.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Studies retrieved from PACS, or sent to this computer, appear here."))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { service.downloads.filter { selection.contains($0.id) }.forEach(service.cancel) } label: { Label("Cancel", systemImage: "stop.circle") }
                    .disabled(!service.downloads.contains { selection.contains($0.id) && $0.state.isActive })
                    .help("Cancel selected downloads")
                Button { service.clearFinished() } label: { Label("Clear", systemImage: "trash") }
                    .disabled(!service.downloads.contains { !$0.state.isActive })
                    .help("Remove finished downloads from the list")
            }
        }
        .frame(minWidth: 760, minHeight: 240)
    }
}

/// Observes one job so rows refresh as counters change.
struct DownloadCell: View {
    enum Kind { case title, progress, time, bytes, speed, average, files, source, error }
    @ObservedObject var job: PACSDownload
    let kind: Kind

    var body: some View {
        switch kind {
        case .title:
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(job.title).lineLimit(1)
            }
        case .progress:
            if job.state == .downloading || job.state == .connecting {
                ProgressView(value: job.progress) { EmptyView() } currentValueLabel: { Text(job.state == .connecting ? "Connecting" : "Downloading").font(.caption2) }
                    .progressViewStyle(.linear)
            } else {
                Text(job.state.rawValue).foregroundStyle(color)
            }
        case .time: Text(Self.duration(job.elapsed)).monospacedDigit()
        case .bytes: Text(ByteCountFormatter.string(fromByteCount: job.bytes, countStyle: .file)).monospacedDigit()
        case .speed: Text(job.state.isActive ? Self.speed(job.currentSpeed) : "").monospacedDigit()
        case .average: Text(job.bytes > 0 ? Self.speed(job.averageSpeed) : "").monospacedDigit()
        case .files: Text(job.expected > 0 ? "\(job.received) / \(job.expected)" : "\(job.received)").monospacedDigit()
        case .source: Text(job.pushed ? "\(job.study.node.aeTitle) (incoming)" : job.study.node.description).lineLimit(1)
        case .error: Text(job.error).foregroundStyle(.secondary).lineLimit(2).help(job.error)
        }
    }

    private var icon: String {
        switch job.state {
        case .finished: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .cancelled: return "minus.circle"
        case .queued, .waiting: return "clock"
        case .connecting, .downloading: return job.pushed ? "tray.and.arrow.down" : "arrow.down.circle"
        }
    }

    private var color: Color {
        switch job.state {
        case .finished: return .green
        case .warning: return .orange
        case .error: return .red
        default: return .secondary
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        guard t > 0 else { return "" }
        if t < 10 { return String(format: "%.1f s", t) }
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func speed(_ bps: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s" }
}

final class PACSDownloadsWindowController: NSWindowController {
    static let shared = PACSDownloadsWindowController()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 320), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "PACS Downloads"
        w.toolbarStyle = .unifiedCompact
        w.setFrameAutosaveName("SpeculaPACSDownloads")
        w.isReleasedWhenClosed = false
        super.init(window: w)
        let host = NSHostingController(rootView: PACSDownloadsView())
        host.sceneBridgingOptions = [.toolbars, .title]
        w.contentViewController = host
        w.setContentSize(NSSize(width: 1000, height: 320))
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.orderFront(nil)
    }
}
