import AppKit
import SwiftUI
import DICOMCore

enum TagAction: String, Codable, CaseIterable, Identifiable {
    case erase = "Erase", modify = "Modify / Insert", keep = "No action"
    var id: String { rawValue }
}

struct TagRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var tag: UInt32
    var action: TagAction
    var value: String = ""
    var name: String { DataDictionary.name(for: Tag(raw: tag)) }
}

struct AnonymizationTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var rules: [TagRule]
    var erasePrivate = true
    var randomizeUIDs = true

    /// Attributes removed by default (subset of the DICOM basic application confidentiality profile).
    static let defaultTags: [Tag] = [
        .patientBirthDate, .patientSex, .patientAge, .patientSize, .patientWeight, .otherPatientIDs, .otherPatientNames, .patientAddress, .patientTelephoneNumbers,
        .institutionName, .institutionAddress, .referringPhysicianName, .performingPhysicianName, .nameOfPhysiciansReadingStudy, .operatorsName,
        .stationName, .accessionNumber, .studyID, .deviceSerialNumber, .imageComments, Tag(0x0032, 0x4000), Tag(0x0010, 0x21B0), Tag(0x0010, 0x4000),
        Tag(0x0008, 0x1048), Tag(0x0008, 0x1040), Tag(0x0008, 0x0092), Tag(0x0008, 0x0094), Tag(0x0040, 0xA730), Tag(0x0018, 0x1030),
    ]

    static let standard = AnonymizationTemplate(name: "Default", rules: defaultTags.map { TagRule(tag: $0.raw, action: .erase) })
}

final class AnonymizerModel: ObservableObject {
    @Published var files: [URL]
    @Published var patientName = "Anonymous"
    @Published var patientID = "ANON0001"
    @Published var template: AnonymizationTemplate
    @Published var templates: [AnonymizationTemplate]
    @Published var destination: URL
    @Published var pathTemplate = "{PatientName}/{StudyDate} {StudyDescription}/{SeriesNumber} {SeriesDescription}/{InstanceNumber}.dcm"
    @Published var reveal = true
    @Published var progress: Double?
    @Published var status = ""
    var cancelled = false

    init(files: [URL]) {
        self.files = files
        let saved = (UserDefaults.standard.data(forKey: "anonTemplates")).flatMap { try? JSONDecoder().decode([AnonymizationTemplate].self, from: $0) } ?? []
        templates = [AnonymizationTemplate.standard] + saved
        template = AnonymizationTemplate.standard
        destination = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent("Anonymized")
    }

    func saveTemplates() {
        let custom = templates.filter { $0.name != "Default" }
        UserDefaults.standard.set(try? JSONEncoder().encode(custom), forKey: "anonTemplates")
    }

    func run(done: @escaping (Int, Int) -> Void) {
        let files = self.files, tpl = template, name = patientName, pid = patientID, dest = destination, pathTpl = pathTemplate
        progress = 0
        cancelled = false
        let salt = UUID().uuidString
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = 0, failed = 0
            for (i, url) in files.enumerated() {
                if self.cancelled { break }
                do {
                    let f = try DICOMFile.read(url: url)
                    let ds = f.dataSet.copy()
                    Anonymizer.apply(tpl, to: ds, patientName: name, patientID: pid, salt: salt)
                    let rel = Anonymizer.path(from: pathTpl, ds: ds, index: i + 1)
                    let out = dest.appendingPathComponent(rel)
                    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try DICOMWriter.fileData(ds, transferSyntax: f.transferSyntax.deflated ? .explicitVRLittleEndian : f.transferSyntax).write(to: out)
                    ok += 1
                } catch { failed += 1 }
                if i % 5 == 0 || i == files.count - 1 {
                    let p = Double(i + 1) / Double(files.count)
                    DispatchQueue.main.async { self.progress = p; self.status = "Anonymizing DICOM files… [\(i + 1)/\(files.count)]" }
                }
            }
            DispatchQueue.main.async { self.progress = nil; done(ok, failed) }
        }
    }
}

enum Anonymizer {
    static let uidTags: Set<Tag> = [.studyInstanceUID, .seriesInstanceUID, .sopInstanceUID, .frameOfReferenceUID, .mediaStorageSOPInstanceUID, .referencedSOPInstanceUID, Tag(0x0020, 0x0200)]

    static func apply(_ t: AnonymizationTemplate, to ds: DataSet, patientName: String, patientID: String, salt: String) {
        ds.set(.patientName, .PN, string: patientName)
        ds.set(.patientID, .LO, string: patientID)
        for r in t.rules {
            let tag = Tag(raw: r.tag)
            switch r.action {
            case .erase: ds.remove(tag)
            case .modify:
                let vr = DataDictionary.vr(for: tag)
                ds.set(tag, vr == .UN ? .LO : vr, string: r.value)
            case .keep: break
            }
        }
        if t.erasePrivate { ds.removeAll { $0.tag.isPrivate } }
        if t.randomizeUIDs { remapUIDs(ds, salt: salt) }
        ds.set(Tag(0x0012, 0x0062), .CS, string: "YES")            // Patient Identity Removed
        ds.set(Tag(0x0012, 0x0063), .LO, string: "Specula anonymizer (\(t.name))")
        if ds.string(.specificCharacterSet) == nil && (patientName + patientID).unicodeScalars.contains(where: { $0.value > 127 }) {
            ds.set(.specificCharacterSet, .CS, string: "ISO_IR 192")
        }
    }

    /// Replaces UIDs with deterministic new ones so studies/series stay grouped across files.
    static func remapUIDs(_ ds: DataSet, salt: String) {
        for e in ds.sortedElements {
            if case .sequence(let items) = e.value { items.forEach { remapUIDs($0, salt: salt) } }
            else if uidTags.contains(e.tag), let v = ds.string(e.tag) {
                ds.set(e.tag, .UI, string: UIDGenerator.derived(from: v, salt: salt))
            }
        }
    }

    static func path(from template: String, ds: DataSet, index: Int) -> String {
        func clean(_ s: String) -> String {
            let t = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "^", with: " ").trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? "unknown" : t
        }
        let map: [String: String] = [
            "PatientName": clean(PersonName.display(ds.string(.patientName))), "PatientID": clean(ds.string(.patientID) ?? ""),
            "StudyDate": clean(DICOMDate.formatDate(ds.string(.studyDate))), "StudyDescription": clean(ds.string(.studyDescription) ?? ""),
            "SeriesNumber": String(format: "%03d", ds.int(.seriesNumber) ?? 0), "SeriesDescription": clean(ds.string(.seriesDescription) ?? ""),
            "Modality": clean(ds.string(.modality) ?? ""), "InstanceNumber": String(format: "%05d", ds.int(.instanceNumber) ?? index),
            "SOPInstanceUID": clean(ds.string(.sopInstanceUID) ?? "\(index)"), "Index": String(format: "%05d", index),
        ]
        var out = template
        for (k, v) in map { out = out.replacingOccurrences(of: "{\(k)}", with: v) }
        return out.replacingOccurrences(of: "//", with: "/")
    }
}

struct AnonymizerView: View {
    @ObservedObject var model: AnonymizerModel
    let close: () -> Void
    @State private var newTag = ""
    @State private var newValue = ""
    @State private var newAction: TagAction = .erase

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Anonymize DICOM Files").font(.title3.weight(.semibold))
            Text("\(model.files.count) file\(model.files.count == 1 ? "" : "s") selected").foregroundStyle(.secondary)
            Form {
                Section("Quick settings") {
                    TextField("Patient Name", text: $model.patientName)
                    TextField("Patient ID", text: $model.patientID)
                    Toggle("Erase private tags", isOn: $model.template.erasePrivate)
                    Toggle("Randomize UIDs", isOn: $model.template.randomizeUIDs)
                }
                Section("Template") {
                    Picker("Template", selection: Binding(get: { model.template.id }, set: { id in if let t = model.templates.first(where: { $0.id == id }) { model.template = t } })) {
                        ForEach(model.templates) { Text($0.name).tag($0.id) }
                    }
                    List {
                        ForEach(model.template.rules) { r in
                            HStack {
                                Text(String(format: "%04X,%04X", r.tag >> 16, r.tag & 0xFFFF)).font(.system(.caption, design: .monospaced))
                                Text(r.name).lineLimit(1)
                                Spacer()
                                Text(r.action == .modify ? "→ \(r.value)" : r.action.rawValue).foregroundStyle(.secondary).font(.caption)
                                Button { model.template.rules.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }
                        }
                    }
                    .frame(height: 150)
                    HStack {
                        TextField("Tag (gggg,eeee) or keyword", text: $newTag).frame(width: 170)
                        Picker("", selection: $newAction) { ForEach(TagAction.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 130)
                        if newAction == .modify { TextField("New value", text: $newValue) }
                        Button("Add") {
                            let tag = Tag(string: newTag) ?? DataDictionary.entry(keyword: newTag)?.tag
                            guard let tag else { return }
                            model.template.rules.append(TagRule(tag: tag.raw, action: newAction, value: newValue))
                            newTag = ""; newValue = ""
                        }
                    }
                    Button("Save as New Template…") {
                        let a = NSAlert(); a.messageText = "New template"; a.informativeText = "Enter a name for the new anonymization template."
                        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24)); a.accessoryView = f
                        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
                        if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty {
                            var t = model.template; t.id = UUID(); t.name = f.stringValue
                            model.templates.append(t); model.template = t; model.saveTemplates()
                        }
                    }
                }
                Section("Destination") {
                    HStack {
                        Text(model.destination.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") {
                            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                            if p.runModal() == .OK, let u = p.url { model.destination = u }
                        }
                    }
                    TextField("Path template", text: $model.pathTemplate).font(.system(.caption, design: .monospaced))
                    Toggle("Show in Finder after finish", isOn: $model.reveal)
                }
            }
            .formStyle(.grouped)
            if let p = model.progress { ProgressView(value: p) { Text(model.status).font(.caption) } }
            HStack {
                Spacer()
                Button("Cancel") { if model.progress != nil { model.cancelled = true } else { close() } }.keyboardShortcut(.cancelAction)
                Button("Anonymize") {
                    model.run { ok, failed in
                        let a = NSAlert()
                        a.messageText = "Anonymization finished."
                        if failed > 0 { a.informativeText = "\(failed) of \(ok + failed) file(s) could not be anonymized." }
                        a.runModal()
                        if model.reveal { NSWorkspace.shared.open(model.destination) }
                        close()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.progress != nil || model.files.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 720)
    }
}

enum AnonymizerWindow {
    private static var windows: [NSWindow] = []

    static func show(session: ViewerSession) {
        let urls = session.collection.studies.flatMap { $0.series.flatMap { $0.instances.map(\.url) } }
        show(urls: urls)
    }

    static func show(urls: [URL]) {
        let model = AnonymizerModel(files: urls)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Anonymization"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: AnonymizerView(model: model) { [weak w] in w?.close() })
        w.center()
        windows.append(w)
        w.makeKeyAndOrderFront(nil)
    }
}
