import AppKit
import SwiftUI
import DICOMCore
import DICOMNet

/// "PACS configuration": listener identity, PACS locations and advanced settings.
struct PACSSettingsView: View {
    @ObservedObject var service = PACSService.shared
    @State private var selection: DICOMNode.ID?
    @State private var editing: DICOMNode?
    @State private var isNew = false
    @State private var verify: [UUID: String] = [:]
    @State private var aeTitle = ""
    @State private var port = ""
    @State private var identityError = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("My AE title") {
                    TextField("My AE title", text: $aeTitle).labelsHidden().frame(width: 180).onSubmit(applyIdentity)
                }
                LabeledContent("Listener port") {
                    HStack {
                        TextField("Listener port", text: $port).labelsHidden().frame(width: 80).onSubmit(applyIdentity)
                        Button("Apply", action: applyIdentity).disabled(aeTitle == service.configuration.aeTitle && port == String(service.configuration.listenerPort))
                    }
                }
                if !identityError.isEmpty { Text(identityError).foregroundStyle(.red).font(.caption) }
                LabeledContent("Status") {
                    HStack {
                        Text(service.listenerStatus).foregroundStyle(service.listenerError == nil ? Color.secondary : Color.red)
                        Spacer()
                        if service.isListening { Button("Stop") { service.stopListener() } } else { Button("Start") { service.startListener() } }
                    }
                }
            } header: {
                Text("This computer")
            } footer: {
                Text("PACS devices send retrieved studies (C-MOVE) to this AE title and port, so they must be configured with this Mac's IP address, port and AE title.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("PACS locations") {
                Table(service.configuration.nodes, selection: $selection) {
                    TableColumn("Description", value: \DICOMNode.description).width(min: 90, ideal: 140)
                    TableColumn("IP address", value: \DICOMNode.host).width(min: 90, ideal: 140)
                    TableColumn("Port") { (n: DICOMNode) in Text(String(n.port)).monospacedDigit() }.width(min: 40, ideal: 55)
                    TableColumn("AE title", value: \DICOMNode.aeTitle).width(min: 70, ideal: 100)
                    TableColumn("Verify") { (n: DICOMNode) in
                        Text(verify[n.id] ?? "").foregroundStyle((verify[n.id] ?? "").hasPrefix("OK") ? Color.green : Color.red).lineLimit(1).help(verify[n.id] ?? "")
                    }.width(min: 60, ideal: 120)
                }
                .contextMenu(forSelectionType: DICOMNode.ID.self) { ids in
                    Button("Edit…") { if let id = ids.first { editing = service.configuration.nodes.first { $0.id == id }; isNew = false } }
                    Button("Verify") { verifyNodes(ids) }
                    Button("Delete", role: .destructive) { service.configuration.nodes.removeAll { ids.contains($0.id) } }
                } primaryAction: { ids in
                    if let id = ids.first { editing = service.configuration.nodes.first { $0.id == id }; isNew = false }
                }
                .frame(minHeight: 120)
                HStack {
                    Button { editing = DICOMNode(description: "", host: "", port: 104, aeTitle: ""); isNew = true } label: { Image(systemName: "plus") }
                        .help("Add PACS location")
                    Button { service.configuration.nodes.removeAll { $0.id == selection } } label: { Image(systemName: "minus") }
                        .disabled(selection == nil).help("Remove PACS location")
                    Button("Edit…") { editing = service.configuration.nodes.first { $0.id == selection }; isNew = false }.disabled(selection == nil)
                    Spacer()
                    Button("Verify PACS Hosts") { verifyNodes(Set(service.configuration.nodes.map(\.id))) }
                        .disabled(service.configuration.nodes.isEmpty)
                }
            }

            Section("Advanced settings") {
                Stepper("Maximum active downloads: \(service.configuration.maxActiveDownloads)", value: $service.configuration.maxActiveDownloads, in: 1...10)
                Picker("Retrieve protocol", selection: $service.configuration.retrieveProtocol) {
                    ForEach(RetrieveProtocol.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Preferred transfer syntax", selection: $service.configuration.preferredTransferSyntax) {
                    ForEach(PACSConfiguration.preferredChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Proposed transfer syntaxes", selection: $service.configuration.proposedTransferSyntaxes) {
                    ForEach(ProposedTransferSyntaxes.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Accept all presentation contexts", isOn: $service.configuration.acceptAllContexts)
                Picker("Accept connections", selection: $service.configuration.acceptConnections) {
                    ForEach(AcceptConnections.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Pause listener on session lock", isOn: $service.configuration.pauseListenerOnLock)
                Stepper("Connection timeout: \(Int(service.configuration.timeout)) s", value: $service.configuration.timeout, in: 5...300, step: 5)
            }

            Section("Search settings") {
                Stepper("Query timeout: \(Int(service.configuration.queryTimeout)) s", value: $service.configuration.queryTimeout, in: 5...600, step: 5)
                Picker("Character set", selection: $service.configuration.characterSet) {
                    ForEach(QueryCharacterSet.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Force selected character set", isOn: $service.configuration.forceCharacterSet)
                    .disabled(service.configuration.characterSet == .automatic)
                Picker("Add wildcards (*)", selection: $service.configuration.wildcards) {
                    ForEach(WildcardMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Replace spaces with carets (^)", isOn: $service.configuration.spacesToCarets)
                Toggle("Replace non-ASCII characters with wildcards (?)", isOn: $service.configuration.nonASCIIToWildcards)
            }
        }
        .formStyle(.grouped)
        .onAppear { aeTitle = service.configuration.aeTitle; port = String(service.configuration.listenerPort) }
        .sheet(item: $editing) { node in
            NodeEditor(node: node, isNew: isNew) { saved in
                if let saved {
                    if let i = service.configuration.nodes.firstIndex(where: { $0.id == saved.id }) { service.configuration.nodes[i] = saved }
                    else { service.configuration.nodes.append(saved) }
                    if !service.isListening { service.startListenerIfConfigured() }
                }
                editing = nil
            }
        }
    }

    private func applyIdentity() {
        let ae = aeTitle.trimmingCharacters(in: .whitespaces)
        guard PACSConfiguration.validAE(ae) else { identityError = "Please enter valid AE title (1-16 characters)."; return }
        guard let p = Int(port), (1...65535).contains(p) else { identityError = "Please enter valid port."; return }
        identityError = ""
        service.configuration.aeTitle = ae
        service.configuration.listenerPort = p
    }

    private func verifyNodes(_ ids: Set<UUID>) {
        for n in service.configuration.nodes where ids.contains(n.id) {
            verify[n.id] = "Connecting…"
            let client = service.client(for: n)
            DispatchQueue.global(qos: .userInitiated).async {
                let text: String
                do { text = String(format: "OK (%.0f ms)", try client.echo() * 1000) } catch { text = error.localizedDescription }
                DispatchQueue.main.async { verify[n.id] = text }
            }
        }
    }
}

struct NodeEditor: View {
    @State var node: DICOMNode
    let isNew: Bool
    let done: (DICOMNode?) -> Void
    @State private var portText = ""
    @State private var error = ""
    @State private var testing = false
    @State private var testResult = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Add PACS Location" : "Edit PACS Location").font(.headline)
            Form {
                TextField("Description", text: $node.description, prompt: Text("Main PACS"))
                TextField("IP address", text: $node.host, prompt: Text("192.168.1.10 or pacs.example.org"))
                TextField("Port", text: $portText, prompt: Text("104"))
                TextField("AE title", text: $node.aeTitle, prompt: Text("PACS"))
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            if !testResult.isEmpty { Text(testResult).foregroundStyle(testResult.hasPrefix("OK") ? Color.green : Color.red).font(.caption) }
            HStack {
                Button("Verify") { test() }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { portText = String(node.port) }
    }

    private func current() -> DICOMNode {
        var n = node
        n.description = n.description.trimmingCharacters(in: .whitespaces)
        n.host = n.host.trimmingCharacters(in: .whitespaces)
        n.aeTitle = n.aeTitle.trimmingCharacters(in: .whitespaces)
        n.port = Int(portText) ?? 0
        return n
    }

    private func save() {
        let n = current()
        if let e = PACSService.shared.configuration.validate(node: n, ignoring: n.id) { error = e; return }
        done(n)
    }

    private func test() {
        let n = current()
        if !(1...65535).contains(n.port) { error = "Please enter valid port."; return }
        testing = true
        testResult = ""
        let client = PACSService.shared.client(for: n)
        DispatchQueue.global(qos: .userInitiated).async {
            let text: String
            do { text = String(format: "OK — C-ECHO answered in %.0f ms", try client.echo() * 1000) } catch { text = error.localizedDescription }
            DispatchQueue.main.async { testResult = text; testing = false }
        }
    }
}

// MARK: - Send to PACS

final class SendModel: ObservableObject {
    @Published var scope: ExportScope = .currentStudy
    @Published var nodeID: UUID?
    @Published var progress: Double?
    @Published var status = ""
    @Published var errors: [String] = []
    @Published var finished = false
    @Published var closeWhenDone = UserDefaults.standard.object(forKey: "sendCloseWhenDone") as? Bool ?? true {
        didSet { UserDefaults.standard.set(closeWhenDone, forKey: "sendCloseWhenDone") }
    }
    let cancel = CancelToken()
}

struct SendToPACSView: View {
    @ObservedObject var model: SendModel
    @ObservedObject var service = PACSService.shared
    let session: ViewerSession
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send to PACS").font(.title3.weight(.semibold))
            if service.configuration.nodes.isEmpty {
                Text("No PACS locations are configured.").foregroundStyle(.secondary)
                Button("Show PACS Configuration…") { close(); PACSWindowController.shared.showWindow(nil) }
            } else {
                Form {
                    Picker("Destination", selection: $model.nodeID) {
                        ForEach(service.configuration.nodes) { n in Text("\(n.description) (\(n.aeTitle)@\(n.host):\(n.port))").tag(Optional(n.id)) }
                    }
                    Picker("Send", selection: $model.scope) {
                        ForEach(ExportScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    LabeledContent("Files", value: "\(files().count)")
                    Toggle("Close when finished successfully", isOn: $model.closeWhenDone)
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(height: 210)
                if let p = model.progress {
                    ProgressView(value: p) { Text(model.status).font(.caption) }
                } else if !model.status.isEmpty {
                    Text(model.status).font(.callout)
                }
                if !model.errors.isEmpty {
                    ScrollView { Text(model.errors.joined(separator: "\n")).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .frame(maxHeight: 90)
                }
            }
            HStack {
                Spacer()
                Button(model.progress != nil ? "Stop" : (model.finished ? "Close" : "Cancel")) {
                    if model.progress != nil { model.cancel.cancel() } else { close() }
                }
                .keyboardShortcut(.cancelAction)
                if !model.finished {
                    Button("Send") { send() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.progress != nil || model.nodeID == nil || files().isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { if model.nodeID == nil { model.nodeID = service.configuration.nodes.first?.id } }
    }

    private func files() -> [URL] {
        if model.scope == .currentImage, let r = session.activeState?.current { return [r.instance.url] }
        var seen = Set<URL>()
        return ExportEngine.series(for: model.scope, session: session).flatMap { $0.instances.map(\.url) }.filter { seen.insert($0).inserted }
    }

    private func send() {
        guard let node = service.configuration.nodes.first(where: { $0.id == model.nodeID }) else { return }
        let list = files()
        model.progress = 0
        model.errors = []
        model.status = "Sending images to PACS... [0/\(list.count)]"
        let client = service.client(for: node)
        let m = model
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try client.store(files: list, cancel: m.cancel) { i, n in
                    DispatchQueue.main.async { m.progress = Double(i) / Double(max(n, 1)); m.status = "Sending images to PACS... [\(i)/\(n)]" }
                }
                DispatchQueue.main.async {
                    m.progress = nil
                    m.finished = true
                    m.errors = r.errors
                    if r.failed == 0 && !m.cancel.isCancelled {
                        m.status = "Sending finished. \(r.sent) image\(r.sent == 1 ? "" : "s") sent to \(node.description)."
                        if m.closeWhenDone { close() }
                    } else {
                        m.status = m.cancel.isCancelled ? "Cancelled after \(r.sent) images." : "Operation completed with errors. \(r.sent) sent, \(r.failed) failed."
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    m.progress = nil
                    m.finished = true
                    m.status = "Operation completed with errors."
                    m.errors = [error.localizedDescription]
                }
            }
        }
    }
}

enum SendToPACSSheet {
    static func present(session: ViewerSession, on window: NSWindow) {
        let model = SendModel()
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentViewController = NSHostingController(rootView: SendToPACSView(model: model, session: session) { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        })
        window.beginSheet(sheet)
    }
}
