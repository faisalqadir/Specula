import Foundation
import DICOMCore

enum OverlayCorner: String, Codable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

/// Predefined annotation items (numbering follows RadiAnt's overlay.xml documentation).
enum OverlayItem: Int, Codable, CaseIterable {
    case imageNumber = 0x01, seriesNumber = 0x02, lossy = 0x03, patientName = 0x04, birthAndSex = 0x05, rotation = 0x06
    case mrTimes = 0x07, fieldStrength = 0x08, acquisitionDateTime = 0x09, thicknessLocation = 0x0A, positionerAngles = 0x0B
    case cursorValue = 0x0C, window = 0x0D, fps = 0x0E, tube = 0x0F, cursor3D = 0x10, filter = 0x11, dsaMask = 0x12

    var title: String {
        switch self {
        case .imageNumber: return "Image number (Im: 3/237)"
        case .seriesNumber: return "Series number (Se: 4)"
        case .lossy: return "Lossy compression"
        case .patientName: return "Patient name"
        case .birthAndSex: return "Birth date and sex"
        case .rotation: return "Rotation / flip"
        case .mrTimes: return "MR TR / TE"
        case .fieldStrength: return "MR field strength"
        case .acquisitionDateTime: return "Acquisition date and time"
        case .thicknessLocation: return "Slice thickness and location"
        case .positionerAngles: return "Positioner angles (LAO/CRA)"
        case .cursorValue: return "Cursor position and value"
        case .window: return "Window level / width"
        case .fps: return "Cine frame rate"
        case .tube: return "Tube current and voltage"
        case .cursor3D: return "3D cursor position"
        case .filter: return "Image filter"
        case .dsaMask: return "DSA mask image"
        }
    }
}

struct OverlayElement: Codable, Equatable, Hashable {
    var tag: UInt32?
    var text: String?
}

struct OverlayRow: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var row: Int
    var hideWhenAnonymous = false
    var highlight = false
    var hideIfMissing = false
    var item: OverlayItem?
    var elements: [OverlayElement] = []

    init(_ row: Int, _ item: OverlayItem, anon: Bool = false, highlight: Bool = false) {
        self.row = row; self.item = item; self.hideWhenAnonymous = anon; self.highlight = highlight
    }

    init(_ row: Int, tag: Tag, label: String? = nil, anon: Bool = false, hideIfMissing: Bool = false) {
        self.row = row
        self.hideWhenAnonymous = anon
        self.hideIfMissing = hideIfMissing
        if let label { elements.append(OverlayElement(tag: nil, text: label)) }
        elements.append(OverlayElement(tag: tag.raw, text: nil))
    }
}

struct OverlaySet: Codable, Equatable, Identifiable {
    var id = UUID()
    var modality: String?       // nil = default set
    var cine = false
    var extendsDefault = true
    var rows: [OverlayCorner: [OverlayRow]] = [:]
}

struct OverlayConfiguration: Codable, Equatable {
    var sets: [OverlaySet]

    /// Same layout as RadiAnt's shipped overlay.xml.
    static let radiantDefault: OverlayConfiguration = {
        var def = OverlaySet()
        def.extendsDefault = false
        def.rows[.topLeft] = [OverlayRow(0, .imageNumber, highlight: true), OverlayRow(1, .seriesNumber), OverlayRow(2, .lossy)]
        def.rows[.topRight] = [
            OverlayRow(0, .patientName, anon: true), OverlayRow(1, tag: .patientID, anon: true), OverlayRow(2, .birthAndSex, anon: true),
            OverlayRow(3, tag: .institutionName, anon: true), OverlayRow(4, tag: .studyID), OverlayRow(5, tag: .studyDescription),
            OverlayRow(6, tag: .seriesDescription), OverlayRow(7, tag: .imageComments), OverlayRow(8, tag: Tag(0x0032, 0x4000)),
            OverlayRow(9, .rotation, highlight: true),
        ]
        def.rows[.bottomLeft] = [OverlayRow(0, .thicknessLocation), OverlayRow(1, .window, highlight: true), OverlayRow(2, .cursorValue, highlight: true), OverlayRow(3, .filter, highlight: true)]
        def.rows[.bottomRight] = [OverlayRow(0, .acquisitionDateTime)]
        var cine = OverlaySet(); cine.cine = true
        cine.rows[.topLeft] = [OverlayRow(0, .fps, highlight: true)]
        var mr = OverlaySet(); mr.modality = "MR"
        mr.rows[.bottomRight] = [OverlayRow(1, .mrTimes), OverlayRow(2, .fieldStrength)]
        var ct = OverlaySet(); ct.modality = "CT"
        ct.rows[.bottomRight] = [OverlayRow(1, .tube)]
        var mg = OverlaySet(); mg.modality = "MG"
        mg.rows[.topLeft] = [OverlayRow(3, tag: .imageLaterality), OverlayRow(4, tag: .viewPosition)]
        var xa = OverlaySet(); xa.modality = "XA"
        xa.rows[.bottomLeft] = [OverlayRow(3, .dsaMask, highlight: true), OverlayRow(4, .filter, highlight: true)]
        xa.rows[.topLeft] = [OverlayRow(3, .positionerAngles)]
        return OverlayConfiguration(sets: [def, cine, mr, ct, mg, xa])
    }()

    /// Effective rows for a modality / cine state, ordered by row index.
    func rows(for corner: OverlayCorner, modality: String, cine: Bool) -> [OverlayRow] {
        var map: [Int: OverlayRow] = [:]
        for r in sets.first(where: { $0.modality == nil && !$0.cine })?.rows[corner] ?? [] { map[r.row] = r }
        if cine { for r in sets.first(where: { $0.modality == nil && $0.cine })?.rows[corner] ?? [] { map[r.row] = r } }
        for s in sets where s.modality?.uppercased() == modality.uppercased() && s.cine == false {
            if !s.extendsDefault { map.removeAll() }
            for r in s.rows[corner] ?? [] { map[r.row] = r }
        }
        return map.keys.sorted().map { map[$0]! }
    }
}
