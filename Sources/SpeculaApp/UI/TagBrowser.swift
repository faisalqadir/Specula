import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DICOMCore

struct TagNode: Identifiable, Hashable {
    let id = UUID()
    let tag: Tag?
    let name: String
    let vr: String
    let vm: String
    let length: String
    let value: String
    var children: [TagNode]?
    let element: DataElement?
    let owner: DataSet?

    static func == (a: TagNode, b: TagNode) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var tagText: String { tag.map { String(format: "%04X,%04X", $0.group, $0.element) } ?? "" }

    static func build(_ ds: DataSet) -> [TagNode] {
        ds.sortedElements.map { e in
            let name = DataDictionary.name(for: e.tag)
            var children: [TagNode]? = nil
            if let items = e.items {
                children = items.enumerated().map { i, item in
                    TagNode(tag: nil, name: "Item \(i + 1)", vr: "", vm: "", length: "", value: "\(item.count) elements", children: build(item), element: nil, owner: item)
                }
            }
            let len = e.declaredLength == 0xFFFF_FFFF ? "undefined" : "\(e.length)"
            return TagNode(tag: e.tag, name: name, vr: e.vr.rawValue, vm: "\(ds.valueMultiplicity(e))", length: len,
                           value: ds.displayValue(e, maxValues: 128), children: children, element: e, owner: ds)
        }
    }

    func matches(_ q: String) -> Bool {
        if q.isEmpty { return true }
        let l = q.lowercased()
        return name.lowercased().contains(l) || value.lowercased().contains(l) || tagText.lowercased().contains(l) || tagText.replacingOccurrences(of: ",", with: "").lowercased().contains(l)
    }

    func filtered(_ q: String) -> TagNode? {
        if q.isEmpty { return self }
        let kids = children?.compactMap { $0.filtered(q) }
        if matches(q) || !(kids?.isEmpty ?? true) {
            var n = self
            n.children = kids?.isEmpty == true ? nil : kids
            return n
        }
        return nil
    }
}

final class TagBrowserModel: ObservableObject {
    @Published var ref: ImageRef
    @Published var nodes: [TagNode] = []
    @Published var query = ""
    @Published var transferSyntax = ""
    @Published var error: String?

    init(ref: ImageRef) {
        self.ref = ref
        load()
    }

    func load() {
        do {
            let f = try DICOMFile.read(url: ref.instance.url, options: .full)
            nodes = TagNode.build(f.fileMeta) + TagNode.build(f.dataSet)
            transferSyntax = f.transferSyntax.name
            error = nil
        } catch {
            self.error = error.localizedDescription
            nodes = TagNode.build(ref.instance.header)
        }
    }

    var filtered: [TagNode] { nodes.compactMap { $0.filtered(query) } }
}

struct TagBrowserView: View {
    @ObservedObject var model: TagBrowserModel
    @State private var selection = Set<TagNode.ID>()

    var body: some View {
        VStack(spacing: 0) {
            Table(model.filtered, children: \.children, selection: $selection) {
                TableColumn("Tag") { n in Text(n.tagText).font(.system(.body, design: .monospaced)) }.width(min: 80, ideal: 92, max: 110)
                TableColumn("Description") { n in Text(n.name) }.width(min: 120, ideal: 220)
                TableColumn("VR") { n in Text(n.vr).font(.system(.body, design: .monospaced)) }.width(34)
                TableColumn("VM") { n in Text(n.vm) }.width(34)
                TableColumn("Length") { n in Text(n.length) }.width(min: 50, ideal: 64, max: 90)
                TableColumn("Value") { n in Text(n.value).lineLimit(1).help(n.value) }.width(min: 160, ideal: 360)
            }
            .contextMenu(forSelectionType: TagNode.ID.self) { ids in
                Button("Copy Value") { copy(ids, full: false) }
                Button("Copy Selected Items") { copy(ids, full: true) }
                Button("Copy All Items") { copyAll() }
                Divider()
                Button("Save Raw Value…") { saveRaw(ids) }.disabled(ids.count != 1)
            }
            Divider()
            HStack {
                Text(model.ref.instance.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("·").foregroundStyle(.tertiary)
                Text(model.transferSyntax).foregroundStyle(.secondary)
                if let e = model.error { Text(e).foregroundStyle(.red) }
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.ref.instance.url]) } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(8)
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Find text…")
        .frame(minWidth: 680, minHeight: 420)
    }

    private func find(_ ids: Set<TagNode.ID>) -> [TagNode] {
        var out: [TagNode] = []
        func walk(_ ns: [TagNode]) { for n in ns { if ids.contains(n.id) { out.append(n) }; if let c = n.children { walk(c) } } }
        walk(model.filtered)
        return out
    }

    private func copy(_ ids: Set<TagNode.ID>, full: Bool) {
        let s = find(ids).map { full ? "(\($0.tagText)) \($0.vr) \($0.name) [\($0.value)]" : $0.value }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func copyAll() {
        var lines: [String] = []
        func walk(_ ns: [TagNode], _ depth: Int) {
            for n in ns {
                lines.append(String(repeating: "  ", count: depth) + (n.tag == nil ? "> \(n.name)" : "(\(n.tagText)) \(n.vr) \(n.name) [\(n.value)]"))
                if let c = n.children { walk(c, depth + 1) }
            }
        }
        walk(model.nodes, 0)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func saveRaw(_ ids: Set<TagNode.ID>) {
        guard let n = find(ids).first, let e = n.element else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(n.tagText.replacingOccurrences(of: ",", with: "_")).raw"
        if e.tag == .encapsulatedDocument { p.nameFieldStringValue = "document.pdf" }
        p.begin { r in
            guard r == .OK, let url = p.url else { return }
            var data = Data()
            switch e.value {
            case .data(let d): data = d
            case .encapsulated(let enc): enc.fragments.forEach { data.append($0) }
            case .sequence: return
            }
            try? data.write(to: url)
        }
    }
}

final class TagBrowserWindow: NSWindowController, NSWindowDelegate {
    private static var open: [TagBrowserWindow] = []
    let model: TagBrowserModel

    static func show(ref: ImageRef) {
        if let existing = open.first(where: { $0.model.ref == ref }) { existing.showWindow(nil); return }
        let wc = TagBrowserWindow(ref: ref)
        open.append(wc)
        wc.showWindow(nil)
    }

    init(ref: ImageRef) {
        model = TagBrowserModel(ref: ref)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "DICOM Tags"
        w.subtitle = ref.instance.url.lastPathComponent
        w.toolbarStyle = .unified
        w.toolbar = NSToolbar(identifier: "tags")
        w.contentViewController = NSHostingController(rootView: TagBrowserView(model: model))
        w.setFrameAutosaveName("SpeculaTags")
        super.init(window: w)
        w.delegate = self
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { TagBrowserWindow.open.removeAll { $0 === self } }
}
