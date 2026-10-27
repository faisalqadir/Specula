import Foundation
import AppKit
import DICOMCore

enum InstanceKind: String {
    case image, structuredReport, pdf, video, other
}

/// Per-frame values that may differ inside enhanced multi-frame objects.
struct FrameAttributes {
    var plane: ImagePlane?
    var windowCenters: [Double] = []
    var windowWidths: [Double] = []
    var rescaleSlope: Double = 1
    var rescaleIntercept: Double = 0
    var acquisitionTime: Double?
    var temporalIndex: Int?
    var stackPosition: Int?
}

/// One SOP instance (file on disk).
final class Instance: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    let header: DataSet
    let transferSyntax: TransferSyntax
    let kind: InstanceKind
    let sopInstanceUID: String
    let sopClassUID: String
    let studyUID: String
    let seriesUID: String
    let instanceNumber: Int?
    let frameCount: Int
    let rows: Int
    let columns: Int
    let pixel: ImagePixelInfo?
    let modality: String
    let frames: [FrameAttributes]
    let frameTimeMs: Double?
    let fileSize: Int
    let windowExplanations: [String]
    let voiFunction: String
    let hasVOILUT: Bool
    let hasModalityLUT: Bool
    let lossy: Bool
    let imageType: [String]

    enum PixelSpacingSource { case none, pixelSpacing, imagerPixelSpacing, ultrasoundRegions, calibrated }

    init(url: URL, file: DICOMFile) {
        self.url = url
        transferSyntax = file.transferSyntax
        fileSize = file.byteCount
        let ds = file.dataSet
        // Keep a compact header: drop large binary values
        let h = DataSet(bigEndian: ds.bigEndian)
        for e in ds.sortedElements {
            switch e.value {
            case .data(let d) where d.count > 4096 && !e.vr.isString: continue
            case .encapsulated: continue
            case .sequence where e.tag == Tag(0x0088, 0x0200): continue // icon image sequence
            default: h.insert(e)
            }
        }
        for e in file.fileMeta.sortedElements { h.insert(e) }
        header = h
        sopInstanceUID = ds.string(.sopInstanceUID) ?? file.fileMeta.string(.mediaStorageSOPInstanceUID) ?? url.path
        sopClassUID = ds.string(.sopClassUID) ?? file.fileMeta.string(.mediaStorageSOPClassUID) ?? ""
        studyUID = ds.string(.studyInstanceUID) ?? "unknown-study"
        seriesUID = ds.string(.seriesInstanceUID) ?? "unknown-series-\(studyUID)"
        instanceNumber = ds.int(.instanceNumber)
        modality = ds.string(.modality) ?? "OT"
        imageType = ds.strings(.imageType)
        let hasPixels = ds.contains(.pixelData) || ds.contains(.floatPixelData) || ds.contains(.doubleFloatPixelData) || (ds.int(.rows) ?? 0) > 0
        if sopClassUID.hasPrefix("1.2.840.10008.5.1.4.1.1.88.") || modality == "SR" {
            kind = .structuredReport
        } else if sopClassUID == "1.2.840.10008.5.1.4.1.1.104.1" || ds.contains(.encapsulatedDocument) {
            kind = .pdf
        } else if file.transferSyntax.isVideo {
            kind = .video
        } else if hasPixels {
            kind = .image
        } else {
            kind = .other
        }
        if kind == .image {
            let info = ImagePixelInfo(ds)
            pixel = info
            rows = info.rows
            columns = info.columns
            frameCount = max(1, info.numberOfFrames)
        } else {
            pixel = nil
            rows = 0
            columns = 0
            frameCount = kind == .video ? max(1, ds.int(.numberOfFrames) ?? 1) : 1
        }
        windowExplanations = ds.strings(.windowCenterWidthExplanation)
        voiFunction = (ds.string(.voiLUTFunction) ?? "LINEAR").uppercased()
        hasVOILUT = ds.sequence(.voiLUTSequence)?.isEmpty == false
        hasModalityLUT = ds.sequence(.modalityLUTSequence)?.isEmpty == false
        lossy = ds.string(.lossyImageCompression) == "01" || file.transferSyntax.lossy
        // Frame timing
        if let ft = ds.double(.frameTime), ft > 0 { frameTimeMs = ft }
        else if let r = ds.double(.cineRate), r > 0 { frameTimeMs = 1000 / r }
        else if let r = ds.double(.recommendedDisplayFrameRate), r > 0 { frameTimeMs = 1000 / r }
        else if let v = ds.doubles(.frameTimeVector).dropFirst().first, v > 0 { frameTimeMs = v }
        else { frameTimeMs = nil }

        // Geometry
        var spacingSource = PixelSpacingSource.none
        func spacing(from item: DataSet?) -> (Double, Double)? {
            guard let item else { return nil }
            let ps = item.doubles(.pixelSpacing)
            if ps.count >= 2, ps[0] > 0, ps[1] > 0 { return (ps[0], ps[1]) }
            return nil
        }
        var baseSpacing: (Double, Double)?
        if let s = spacing(from: ds) { baseSpacing = s; spacingSource = .pixelSpacing }
        let shared = ds.firstItem(.sharedFunctionalGroupsSequence)
        if baseSpacing == nil, let s = spacing(from: shared?.firstItem(.pixelMeasuresSequence)) { baseSpacing = s; spacingSource = .pixelSpacing }
        if baseSpacing == nil {
            let ips = ds.doubles(.imagerPixelSpacing)
            if ips.count >= 2, ips[0] > 0 {
                var f = 1.0
                if let mag = ds.double(.estimatedRadiographicMagnificationFactor), mag > 0 { f = 1 / mag }
                baseSpacing = (ips[0] * f, ips[1] * f); spacingSource = .imagerPixelSpacing
            } else if let region = ds.sequence(.sequenceOfUltrasoundRegions)?.first,
                      region.int(.physicalUnitsXDirection) == 3, region.int(.physicalUnitsYDirection) == 3,
                      let dx = region.double(.physicalDeltaX), let dy = region.double(.physicalDeltaY), dx > 0, dy > 0 {
                baseSpacing = (abs(dy) * 10, abs(dx) * 10); spacingSource = .ultrasoundRegions
            }
        }
        let baseThickness = ds.double(.sliceThickness) ?? shared?.firstItem(.pixelMeasuresSequence)?.double(.sliceThickness)

        let nRows = rows, nCols = columns
        func plane(position: [Double], orientation: [Double], spacing: (Double, Double)?, thickness: Double?) -> ImagePlane? {
            guard position.count >= 3, orientation.count >= 6, nRows > 0, nCols > 0 else { return nil }
            let r = Vec3(orientation[0], orientation[1], orientation[2]).normalized
            let c = Vec3(orientation[3], orientation[4], orientation[5]).normalized
            guard r.length > 0.5, c.length > 0.5 else { return nil }
            let sp = spacing ?? (1, 1)
            return ImagePlane(position: Vec3(position[0], position[1], position[2]), rowDirection: r, columnDirection: c,
                              rowSpacing: sp.0, columnSpacing: sp.1, rows: nRows, columns: nCols, thickness: thickness)
        }

        let centers = ds.doubles(.windowCenter), widths = ds.doubles(.windowWidth)
        let slope = ds.double(.rescaleSlope) ?? 1, intercept = ds.double(.rescaleIntercept) ?? 0
        let acqTime = DICOMDate.parseTime(ds.string(.acquisitionTime) ?? ds.string(.contentTime))
            ?? DICOMDate.dateTime(ds.string(.acquisitionDateTime)).map { $0.timeIntervalSince(Calendar.current.startOfDay(for: $0)) }

        var frameAttrs: [FrameAttributes] = []
        let isImage = kind == .image
        let nFrames = frameCount
        let ftMs = frameTimeMs
        if isImage, let perFrame = ds.sequence(.perFrameFunctionalGroupsSequence), !perFrame.isEmpty {
            let sharedOrient = shared?.firstItem(.planeOrientationSequence)?.doubles(.imageOrientationPatient) ?? ds.doubles(.imageOrientationPatient)
            let sharedVOI = shared?.firstItem(.frameVOILUTSequence)
            let sharedPVT = shared?.firstItem(.pixelValueTransformationSequence)
            for i in 0..<nFrames {
                let fg = i < perFrame.count ? perFrame[i] : nil
                var fa = FrameAttributes()
                let pos = fg?.firstItem(.planePositionSequence)?.doubles(.imagePositionPatient) ?? shared?.firstItem(.planePositionSequence)?.doubles(.imagePositionPatient) ?? []
                let orient = fg?.firstItem(.planeOrientationSequence)?.doubles(.imageOrientationPatient) ?? sharedOrient
                let sp = spacing(from: fg?.firstItem(.pixelMeasuresSequence)) ?? baseSpacing
                if sp != nil && spacingSource == .none { spacingSource = .pixelSpacing }
                let th = fg?.firstItem(.pixelMeasuresSequence)?.double(.sliceThickness) ?? baseThickness
                fa.plane = plane(position: pos, orientation: orient, spacing: sp, thickness: th)
                let voi = fg?.firstItem(.frameVOILUTSequence) ?? sharedVOI
                fa.windowCenters = voi?.doubles(.windowCenter) ?? centers
                fa.windowWidths = voi?.doubles(.windowWidth) ?? widths
                let pvt = fg?.firstItem(.pixelValueTransformationSequence) ?? sharedPVT
                fa.rescaleSlope = pvt?.double(.rescaleSlope) ?? slope
                fa.rescaleIntercept = pvt?.double(.rescaleIntercept) ?? intercept
                let content = fg?.firstItem(.frameContentSequence)
                fa.acquisitionTime = DICOMDate.dateTime(content?.string(.frameAcquisitionDateTime)).map { $0.timeIntervalSince(Calendar.current.startOfDay(for: $0)) } ?? acqTime
                fa.temporalIndex = content?.int(.temporalPositionIndex)
                fa.stackPosition = content?.int(.inStackPositionNumber)
                frameAttrs.append(fa)
            }
        } else {
            let pl = plane(position: ds.doubles(.imagePositionPatient), orientation: ds.doubles(.imageOrientationPatient), spacing: baseSpacing, thickness: baseThickness)
            var fa = FrameAttributes(plane: pl, windowCenters: centers, windowWidths: widths, rescaleSlope: slope, rescaleIntercept: intercept, acquisitionTime: acqTime)
            fa.temporalIndex = ds.int(.temporalPositionIdentifier)
            if nFrames > 1 {
                // Legacy multi-frame: same geometry for all frames, times from the frame time
                frameAttrs = (0..<nFrames).map { i in
                    var f = fa
                    if let t = acqTime, let ft = ftMs { f.acquisitionTime = t + Double(i) * ft / 1000 }
                    return f
                }
            } else {
                frameAttrs = [fa]
            }
        }
        frames = frameAttrs
        pixelSpacingSourceOverride = spacingSource
    }

    private var pixelSpacingSourceOverride: PixelSpacingSource

    var effectiveSpacingSource: PixelSpacingSource { pixelSpacingSourceOverride }

    /// Pixel spacing (row, column) in mm for a frame, or nil when unknown.
    func pixelSpacing(frame: Int) -> (Double, Double)? {
        if let p = frames[safe: frame]?.plane, effectiveSpacingSource != .none { return (p.rowSpacing, p.columnSpacing) }
        guard effectiveSpacingSource != .none else { return nil }
        let ds = header
        let ps = ds.doubles(.pixelSpacing)
        if ps.count >= 2 { return (ps[0], ps[1]) }
        let ips = ds.doubles(.imagerPixelSpacing)
        if ips.count >= 2 { return (ips[0], ips[1]) }
        if let region = ds.sequence(.sequenceOfUltrasoundRegions)?.first, let dx = region.double(.physicalDeltaX), let dy = region.double(.physicalDeltaY) {
            return (abs(dy) * 10, abs(dx) * 10)
        }
        return nil
    }

    var isMultiFrame: Bool { frameCount > 1 }
    var isColor: Bool { (pixel?.samplesPerPixel ?? 1) > 1 || pixel?.isPalette == true }
    var isMonochrome1: Bool { pixel?.photometric == "MONOCHROME1" }

    func string(_ t: Tag) -> String? { header.string(t) }
}

/// A displayable image: one frame of an instance.
struct ImageRef: Hashable, Identifiable {
    let instance: Instance
    let frame: Int
    var id: String { instance.sopInstanceUID + "#\(frame)" }

    static func == (a: ImageRef, b: ImageRef) -> Bool { a.instance === b.instance && a.frame == b.frame }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(instance)); h.combine(frame) }

    var attributes: FrameAttributes { instance.frames[safe: frame] ?? instance.frames.first ?? FrameAttributes() }
    var plane: ImagePlane? { attributes.plane }
}

enum SortMode: String, CaseIterable {
    case instanceNumber, spatialPosition, acquisitionTime, fileName
    var title: String {
        switch self {
        case .instanceNumber: return "Instance Number"
        case .spatialPosition: return "Spatial Position"
        case .acquisitionTime: return "Acquisition Time"
        case .fileName: return "File Name"
        }
    }
}

final class Series: Identifiable, ObservableObject {
    let id = UUID()
    let uid: String
    weak var study: Study?
    @Published private(set) var instances: [Instance] = []
    @Published private(set) var images: [ImageRef] = []
    @Published var thumbnail: NSImage?
    var sortMode: SortMode = .spatialPosition
    var ascending = true
    var splitLabel: String?
    private var uids = Set<String>()

    init(uid: String, study: Study?) {
        self.uid = uid
        self.study = study
    }

    var number: Int? { instances.first?.header.int(.seriesNumber) }
    var modality: String { instances.first?.modality ?? "" }
    var seriesDescription: String {
        let d = instances.first?.string(.seriesDescription) ?? instances.first?.string(.protocolName) ?? ""
        if let s = splitLabel { return d.isEmpty ? s : "\(d) [\(s)]" }
        return d
    }
    var kind: InstanceKind { instances.first?.kind ?? .other }
    var imageCount: Int { images.count }
    var first: Instance? { instances.first }
    var frameOfReference: String? { instances.first?.string(.frameOfReferenceUID) }

    @discardableResult
    func add(_ inst: Instance) -> Bool {
        guard !uids.contains(inst.sopInstanceUID) else { return false }
        uids.insert(inst.sopInstanceUID)
        instances.append(inst)
        return true
    }

    func remove(_ inst: Instance) {
        instances.removeAll { $0 === inst }
        uids.remove(inst.sopInstanceUID)
    }

    /// Default sort: instance number when it is complete and unique (usually head-first for axial CT),
    /// otherwise spatial position.
    func chooseDefaultSort() {
        let nums = instances.compactMap(\.instanceNumber)
        let multiFrame = instances.contains { $0.isMultiFrame }
        if !multiFrame, nums.count == instances.count, Set(nums).count == nums.count, instances.count > 0 {
            sortMode = .instanceNumber
            return
        }
        let planes = instances.compactMap { $0.frames.first?.plane }
        if planes.count == instances.count && instances.count > 1, let n = planes.first?.normal,
           planes.allSatisfy({ abs($0.normal.dot(n)) > 0.99 }),
           Set(planes.map { Int(($0.position.dot(n) * 100).rounded()) }).count > 1 {
            sortMode = .spatialPosition
        } else {
            sortMode = .instanceNumber
        }
    }

    func rebuildImages() {
        var refs: [ImageRef] = []
        for inst in instances where inst.kind == .image || inst.kind == .video {
            for f in 0..<inst.frameCount { refs.append(ImageRef(instance: inst, frame: f)) }
        }
        if refs.isEmpty {
            refs = instances.map { ImageRef(instance: $0, frame: 0) }
        }
        var normal = refs.first?.plane?.normal
        if let n = normal {
            // Head-first / right-first / anterior-first: walk against the dominant patient axis
            let dominant = [abs(n.x), abs(n.y), abs(n.z)].enumerated().max { $0.element < $1.element }!.offset
            let comp = [n.x, n.y, n.z][dominant]
            if dominant == 2 ? comp > 0 : comp < 0 { normal = n * -1 }
        }
        func key(_ r: ImageRef) -> (Double, Double, Double) {
            let inum = Double(r.instance.instanceNumber ?? 0)
            switch sortMode {
            case .instanceNumber:
                return (inum, Double(r.attributes.stackPosition ?? r.frame), r.attributes.acquisitionTime ?? 0)
            case .spatialPosition:
                if let p = r.plane, let n = normal { return (p.position.dot(n), Double(r.attributes.temporalIndex ?? 0), inum) }
                return (inum, Double(r.frame), 0)
            case .acquisitionTime:
                return (r.attributes.acquisitionTime ?? 0, inum, Double(r.frame))
            case .fileName:
                return (0, inum, Double(r.frame))
            }
        }
        if sortMode == .fileName {
            refs.sort { a, b in
                let c = a.instance.url.lastPathComponent.localizedStandardCompare(b.instance.url.lastPathComponent)
                return c == .orderedSame ? a.frame < b.frame : c == .orderedAscending
            }
        } else {
            let keys = Dictionary(uniqueKeysWithValues: refs.map { ($0, key($0)) })
            refs.sort { a, b in
                let ka = keys[a]!, kb = keys[b]!
                if ka != kb { return ka < kb }
                if a.instance.url.path != b.instance.url.path { return a.instance.url.path < b.instance.url.path }
                return a.frame < b.frame
            }
        }
        images = ascending ? refs : refs.reversed()
    }

    /// True when images form a regular stack usable for MPR / 3D.
    var volumeCandidate: Bool {
        guard images.count >= 3 else { return false }
        let planes = images.compactMap(\.plane)
        guard planes.count == images.count, let f = planes.first else { return false }
        return planes.allSatisfy { abs($0.normal.dot(f.normal)) > 0.995 && $0.rows == f.rows && $0.columns == f.columns }
    }

    func middleImage() -> ImageRef? { images.isEmpty ? nil : images[images.count / 2] }
}

final class Study: Identifiable, ObservableObject {
    let id = UUID()
    let uid: String
    @Published var series: [Series] = []
    var header: DataSet

    init(uid: String, header: DataSet) {
        self.uid = uid
        self.header = header
    }

    var patientName: String { PersonName.display(header.string(.patientName)) }
    var patientNameRaw: String { header.string(.patientName) ?? "" }
    var patientID: String { header.string(.patientID) ?? "" }
    var birthDate: String { header.string(.patientBirthDate) ?? "" }
    var sex: String { header.string(.patientSex) ?? "" }
    var studyDate: String { header.string(.studyDate) ?? "" }
    var studyTime: String { header.string(.studyTime) ?? "" }
    var studyDescription: String { header.string(.studyDescription) ?? "" }
    var accession: String { header.string(.accessionNumber) ?? "" }
    var modalities: String { Array(Set(series.map(\.modality))).sorted().joined(separator: "/") }
    var date: Date? { DICOMDate.date(da: studyDate, tm: studyTime) }

    func seriesSorted() -> [Series] {
        series.sorted { ($0.number ?? Int.max, $0.first?.string(.seriesTime) ?? "") < ($1.number ?? Int.max, $1.first?.string(.seriesTime) ?? "") }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
