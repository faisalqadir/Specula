import Foundation
import DICOMCore
import ImageIO
import CoreGraphics

/// Synthetic, anonymous test studies (no patient data).
enum Phantom {
    struct Geometry {
        var rows: Int, cols: Int
        var spacing: (Double, Double)
        var iop: [Double]
        var origin: (Double, Double, Double)
        var sliceStep: (Double, Double, Double)
    }

    static func baseDataSet(patient: String, pid: String, study: String, studyDesc: String, series: String, seriesNumber: Int, seriesDesc: String, modality: String, sopClass: String, instance: Int) -> DataSet {
        let ds = DataSet()
        ds.set(.specificCharacterSet, .CS, string: "ISO_IR 100")
        ds.set(.imageType, .CS, string: "ORIGINAL\\PRIMARY\\AXIAL")
        ds.set(.sopClassUID, .UI, string: sopClass)
        ds.set(.sopInstanceUID, .UI, string: UIDGenerator.make())
        ds.set(.studyDate, .DA, string: "20260115")
        ds.set(.seriesDate, .DA, string: "20260115")
        ds.set(.acquisitionDate, .DA, string: "20260115")
        ds.set(.studyTime, .TM, string: "093000")
        ds.set(.seriesTime, .TM, string: String(format: "09%02d00", 30 + seriesNumber))
        ds.set(.acquisitionTime, .TM, string: String(format: "09%02d%02d", 30 + seriesNumber, instance % 60))
        ds.set(.accessionNumber, .SH, string: "ACC\(pid.suffix(4))")
        ds.set(.modality, .CS, string: modality)
        ds.set(.manufacturer, .LO, string: "Specula Phantom Generator")
        ds.set(.institutionName, .LO, string: "Synthetic Test Institute")
        ds.set(.referringPhysicianName, .PN, string: "Referrer^Test")
        ds.set(.studyDescription, .LO, string: studyDesc)
        ds.set(.seriesDescription, .LO, string: seriesDesc)
        ds.set(.patientName, .PN, string: patient)
        ds.set(.patientID, .LO, string: pid)
        ds.set(.patientBirthDate, .DA, string: "19700101")
        ds.set(.patientSex, .CS, string: "O")
        ds.set(.patientAge, .AS, string: "056Y")
        ds.set(.patientWeight, .DS, string: "72")
        ds.set(.studyInstanceUID, .UI, string: study)
        ds.set(.seriesInstanceUID, .UI, string: series)
        ds.set(.studyID, .SH, string: "1")
        ds.set(.seriesNumber, .IS, string: String(seriesNumber))
        ds.set(.instanceNumber, .IS, string: String(instance))
        return ds
    }

    static func setGeometry(_ ds: DataSet, _ g: Geometry, slice i: Int, thickness: Double) {
        let p = (g.origin.0 + g.sliceStep.0 * Double(i), g.origin.1 + g.sliceStep.1 * Double(i), g.origin.2 + g.sliceStep.2 * Double(i))
        ds.set(.imagePositionPatient, double: [p.0, p.1, p.2])
        ds.set(.imageOrientationPatient, double: g.iop)
        ds.set(.pixelSpacing, double: [g.spacing.0, g.spacing.1])
        ds.set(.sliceThickness, double: [thickness])
        let n = (g.iop[1] * g.iop[5] - g.iop[2] * g.iop[4], g.iop[2] * g.iop[3] - g.iop[0] * g.iop[5], g.iop[0] * g.iop[4] - g.iop[1] * g.iop[3])
        ds.set(.sliceLocation, double: [p.0 * n.0 + p.1 * n.1 + p.2 * n.2])
        ds.set(.frameOfReferenceUID, .UI, string: frameOfReference)
    }

    static let frameOfReference = UIDGenerator.make()

    static func setPixels16(_ ds: DataSet, rows: Int, cols: Int, values: [UInt16], signed: Bool, bitsStored: Int) {
        ds.set(.samplesPerPixel, uint16: [1])
        ds.set(.photometricInterpretation, .CS, string: "MONOCHROME2")
        ds.set(.rows, uint16: [UInt16(rows)])
        ds.set(.columns, uint16: [UInt16(cols)])
        ds.set(.bitsAllocated, uint16: [16])
        ds.set(.bitsStored, uint16: [UInt16(bitsStored)])
        ds.set(.highBit, uint16: [UInt16(bitsStored - 1)])
        ds.set(.pixelRepresentation, uint16: [signed ? 1 : 0])
        var d = Data(count: values.count * 2)
        d.withUnsafeMutableBytes { r in let p = r.bindMemory(to: UInt16.self); for i in values.indices { p[i] = values[i].littleEndian } }
        ds.set(.pixelData, .OW, data: d)
    }

    /// Torso-like phantom value in HU at patient coordinate (x, y, z) in mm.
    static func ctHU(_ x: Double, _ y: Double, _ z: Double) -> Double {
        // body ellipse
        let bx = x / 160, by = (y - 10) / 115
        if bx * bx + by * by > 1 { return -1000 }
        var hu = 40.0
        // subcutaneous fat ring
        if bx * bx + by * by > 0.82 { hu = -90 }
        // lungs (upper half of the volume)
        if z > -40 {
            for sx in [-1.0, 1.0] {
                let lx = (x - sx * 75) / 55, ly = (y - 0) / 75, lz = (z - 40) / 110
                if lx * lx + ly * ly + lz * lz < 1 { hu = -820 + 30 * sin(x * 0.3) * cos(y * 0.25) }
            }
            // heart
            let hx = (x + 15) / 50, hy = (y + 25) / 45, hz = (z - 10) / 50
            if hx * hx + hy * hy + hz * hz < 1 { hu = 45 }
        } else {
            // liver
            let lx = (x + 60) / 70, ly = (y + 10) / 60
            if lx * lx + ly * ly < 1 && z > -150 { hu = 60 }
            // kidneys
            for sx in [-1.0, 1.0] {
                let kx = (x - sx * 65) / 22, ky = (y - 45) / 32, kz = (z + 110) / 50
                if kx * kx + ky * ky + kz * kz < 1 { hu = 150 }
            }
            // lesion in liver
            let ex = (x + 70) / 14, ey = (y + 15) / 14, ez = (z + 90) / 14
            if ex * ex + ey * ey + ez * ez < 1 { hu = 110 }
        }
        // aorta (contrast)
        let ax = (x - 12) / 13, ay = (y - 40) / 13
        if ax * ax + ay * ay < 1 { hu = 320 }
        // spine: vertebral bodies every 30 mm with discs
        let vx = x / 22, vy = (y - 80) / 20
        if vx * vx + vy * vy < 1 {
            let phase = (z + 1000).truncatingRemainder(dividingBy: 30)
            hu = phase < 25 ? (vx * vx + vy * vy > 0.6 ? 900 : 300) : 80
        }
        // ribs
        if z > -60 {
            let r = sqrt(x * x / (150 * 150) + (y - 10) * (y - 10) / (105 * 105))
            let phase = (z + 1000).truncatingRemainder(dividingBy: 22)
            if r > 0.86 && r < 0.93 && phase < 7 && y < 70 { hu = 750 }
        }
        return hu
    }

    static func writeCT(to dir: URL, slices: Int, size: Int, ts: TransferSyntax, folder: String, study: String, seriesNumber: Int, desc: String) throws {
        let out = dir.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let series = UIDGenerator.make()
        let spacing = 360.0 / Double(size)
        let step = 300.0 / Double(slices)
        let g = Geometry(rows: size, cols: size, spacing: (spacing, spacing), iop: [1, 0, 0, 0, 1, 0],
                         origin: (-180 + spacing / 2, -170 + spacing / 2, 140), sliceStep: (0, 0, -step))
        for i in 0..<slices {
            let ds = baseDataSet(patient: "PHANTOM^CHEST ABDOMEN", pid: "SPC-0001", study: study, studyDesc: "CT Chest Abdomen (synthetic)", series: series, seriesNumber: seriesNumber, seriesDesc: desc, modality: "CT", sopClass: "1.2.840.10008.5.1.4.1.1.2", instance: i + 1)
            setGeometry(ds, g, slice: i, thickness: step)
            ds.set(.kvp, double: [120])
            ds.set(.xRayTubeCurrent, .IS, string: "250")
            ds.set(.rescaleIntercept, double: [-1024])
            ds.set(.rescaleSlope, double: [1])
            ds.set(.rescaleType, .LO, string: "HU")
            ds.set(.windowCenter, double: [40, -600])
            ds.set(.windowWidth, double: [400, 1500])
            ds.set(.windowCenterWidthExplanation, .LO, strings: ["SOFT TISSUE", "LUNG"])
            let z = g.origin.2 + g.sliceStep.2 * Double(i)
            var vals = [UInt16](repeating: 0, count: size * size)
            var seed: UInt64 = UInt64(i) &* 0x9E37_79B9_7F4A_7C15 &+ 1
            for r in 0..<size {
                let y = g.origin.1 + Double(r) * spacing
                for c in 0..<size {
                    let x = g.origin.0 + Double(c) * spacing
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let noise = Double(Int64(bitPattern: seed >> 33) % 17) - 8
                    let hu = ctHU(x, y, z) + (ctHU(x, y, z) > -900 ? noise : 0)
                    vals[r * size + c] = UInt16(max(0, min(4095, hu + 1024)))
                }
            }
            setPixels16(ds, rows: size, cols: size, values: vals, signed: false, bitsStored: 12)
            try encodePixels(ds, ts: ts, rows: size, cols: size, values: vals, bits: 12)
            let file = DICOMWriter.fileData(ds, transferSyntax: ts)
            try file.write(to: out.appendingPathComponent(String(format: "CT%04d.dcm", i + 1)))
        }
    }

    static func encodePixels(_ ds: DataSet, ts: TransferSyntax, rows: Int, cols: Int, values: [UInt16], bits: Int) throws {
        switch ts.codec {
        case .native: return
        case .rle:
            let f = RLECodec.encode(samples: values, width: cols, height: rows, samplesPerPixel: 1, bitsAllocated: 16)
            ds.insert(DataElement(tag: .pixelData, vr: .OB, value: .encapsulated(EncapsulatedPixelData(fragments: [f]))))
        case .jpegLossless:
            let f = JPEGLosslessEncoder.encode(samples: values, width: cols, height: rows, precision: max(2, bits), predictor: 1)
            ds.insert(DataElement(tag: .pixelData, vr: .OB, value: .encapsulated(EncapsulatedPixelData(fragments: [f]))))
        case .jpeg2000:
            // ImageIO only writes 8-bit JPEG 2000, so use OpenJPEG for the real bit depth
            guard let f = openJPEGEncode(samples: values, width: cols, height: rows, bits: bits) else { throw DICOMError.decode("j2k encode (needs opj_compress)") }
            ds.insert(DataElement(tag: .pixelData, vr: .OB, value: .encapsulated(EncapsulatedPixelData(fragments: [f]))))
        default:
            throw DICOMError.unsupported("encoder for \(ts.name)")
        }
    }

    /// Lossless JPEG 2000 codestream via OpenJPEG's opj_compress (reference encoder, test data only).
    static func openJPEGEncode(samples: [UInt16], width: Int, height: Int, bits: Int) -> Data? {
        let tool = ["/opt/homebrew/bin/opj_compress", "/usr/local/bin/opj_compress"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tool else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("specula-j2k-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let maxval = (1 << bits) - 1
        var pgm = Data("P5\n\(width) \(height)\n\(maxval)\n".utf8)
        for v in samples { pgm.append(UInt8(v >> 8)); pgm.append(UInt8(v & 0xFF)) }
        let input = tmp.appendingPathComponent("in.pgm"), output = tmp.appendingPathComponent("out.j2k")
        guard (try? pgm.write(to: input)) != nil else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-i", input.path, "-o", output.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? try? Data(contentsOf: output) : nil
    }

    static func writeMR(to dir: URL, study: String) throws {
        let out = dir.appendingPathComponent("MR_SAG_T1")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let series = UIDGenerator.make()
        let size = 192, slices = 24
        let sp = 300.0 / Double(size)
        // Sagittal: rows along -z (head to feet), columns along +y (anterior to posterior)
        let g = Geometry(rows: size, cols: size, spacing: (sp, sp), iop: [0, 1, 0, 0, 0, -1], origin: (-60, -170, 140), sliceStep: (5, 0, 0))
        for i in 0..<slices {
            let ds = baseDataSet(patient: "PHANTOM^CHEST ABDOMEN", pid: "SPC-0001", study: study, studyDesc: "CT Chest Abdomen (synthetic)", series: series, seriesNumber: 5, seriesDesc: "MR SAG T1 (synthetic)", modality: "MR", sopClass: "1.2.840.10008.5.1.4.1.1.4", instance: i + 1)
            setGeometry(ds, g, slice: i, thickness: 4)
            ds.set(.repetitionTime, double: [540])
            ds.set(.echoTime, double: [14])
            ds.set(.magneticFieldStrength, double: [1.5])
            ds.set(.windowCenter, double: [600]); ds.set(.windowWidth, double: [1200])
            var vals = [UInt16](repeating: 0, count: size * size)
            let x = g.origin.0 + 5 * Double(i)
            for r in 0..<size {
                for c in 0..<size {
                    let y = g.origin.1 + Double(c) * sp
                    let z = g.origin.2 - Double(r) * sp
                    let hu = ctHU(x, y, z)
                    let v: Double = hu < -900 ? 5 : (hu < -500 ? 60 : (hu > 600 ? 300 : (hu > 250 ? 1100 : (hu < -50 ? 1600 : 700 + hu))))
                    vals[r * size + c] = UInt16(max(0, min(4095, v)))
                }
            }
            setPixels16(ds, rows: size, cols: size, values: vals, signed: false, bitsStored: 12)
            try DICOMWriter.fileData(ds, transferSyntax: .explicitVRLittleEndian).write(to: out.appendingPathComponent(String(format: "MR%04d.dcm", i + 1)))
        }
    }

    static func writePET(to dir: URL, study: String) throws {
        let out = dir.appendingPathComponent("PET_AC")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let series = UIDGenerator.make()
        let size = 128, slices = 75
        let sp = 360.0 / Double(size)
        let g = Geometry(rows: size, cols: size, spacing: (sp, sp), iop: [1, 0, 0, 0, 1, 0], origin: (-180 + sp / 2, -170 + sp / 2, 140), sliceStep: (0, 0, -4))
        for i in 0..<slices {
            let ds = baseDataSet(patient: "PHANTOM^CHEST ABDOMEN", pid: "SPC-0001", study: study, studyDesc: "CT Chest Abdomen (synthetic)", series: series, seriesNumber: 7, seriesDesc: "PET AC (synthetic)", modality: "PT", sopClass: "1.2.840.10008.5.1.4.1.1.128", instance: i + 1)
            setGeometry(ds, g, slice: i, thickness: 4)
            ds.set(.units, .CS, string: "BQML")
            ds.set(.decayCorrection, .CS, string: "START")
            ds.set(.correctedImage, .CS, strings: ["ATTN", "DECY"])
            let radio = DataSet()
            radio.set(.radiopharmaceuticalStartTime, .TM, string: "083000")
            radio.set(.radionuclideTotalDose, double: [370e6])
            radio.set(.radionuclideHalfLife, double: [6586.2])
            ds.set(.radiopharmaceuticalInformationSequence, sequence: [radio])
            let z = g.origin.2 - 4 * Double(i)
            var f = [Double](repeating: 0, count: size * size)
            var mx = 0.0
            for r in 0..<size {
                for c in 0..<size {
                    let x = g.origin.0 + Double(c) * sp, y = g.origin.1 + Double(r) * sp
                    let hu = ctHU(x, y, z)
                    var a: Double = hu < -900 ? 0 : (hu < -500 ? 800 : 4000)
                    if hu == 45 { a = 16000 }     // myocardium
                    if hu == 150 { a = 12000 }    // kidneys
                    if hu == 110 { a = 42000 }    // hot liver lesion
                    f[r * size + c] = a
                    mx = max(mx, a)
                }
            }
            let slope = mx / 32767
            let vals = f.map { UInt16(max(0, min(32767, $0 / slope))) }
            setPixels16(ds, rows: size, cols: size, values: vals, signed: true, bitsStored: 16)
            ds.set(.rescaleSlope, double: [slope])
            ds.set(.rescaleIntercept, double: [0])
            try DICOMWriter.fileData(ds, transferSyntax: .explicitVRLittleEndian).write(to: out.appendingPathComponent(String(format: "PT%04d.dcm", i + 1)))
        }
    }

    static func writeUS(to dir: URL) throws {
        let out = dir.appendingPathComponent("US_CINE")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let study = UIDGenerator.make(), series = UIDGenerator.make()
        let w = 320, h = 240, frames = 30
        let ds = baseDataSet(patient: "PHANTOM^ECHO", pid: "SPC-0002", study: study, studyDesc: "Echo (synthetic)", series: series, seriesNumber: 1, seriesDesc: "Cine loop", modality: "US", sopClass: "1.2.840.10008.5.1.4.1.1.3.1", instance: 1)
        ds.set(.samplesPerPixel, uint16: [3])
        ds.set(.photometricInterpretation, .CS, string: "RGB")
        ds.set(.planarConfiguration, uint16: [0])
        ds.set(.rows, uint16: [UInt16(h)]); ds.set(.columns, uint16: [UInt16(w)])
        ds.set(.bitsAllocated, uint16: [8]); ds.set(.bitsStored, uint16: [8]); ds.set(.highBit, uint16: [7]); ds.set(.pixelRepresentation, uint16: [0])
        ds.set(.numberOfFrames, .IS, string: String(frames))
        ds.set(.frameTime, double: [40])
        ds.set(.frameIncrementPointer, uint16: [0x0018, 0x1063], vr: .AT)
        var px = Data(count: w * h * 3 * frames)
        px.withUnsafeMutableBytes { r in
            let p = r.bindMemory(to: UInt8.self)
            for f in 0..<frames {
                let phase = Double(f) / Double(frames) * 2 * .pi
                let rad = 60 + 18 * sin(phase)
                for y in 0..<h {
                    for x in 0..<w {
                        let dx = Double(x - w / 2), dy = Double(y - h / 2)
                        let d = sqrt(dx * dx + dy * dy)
                        let angle = atan2(dx, -dy)
                        let inFan = abs(angle) < 0.75 && d < 220
                        var g: Double = inFan ? 30 + 20 * sin(d * 0.3 + Double(x) * 0.1) : 0
                        if inFan && abs(d - rad) < 6 { g = 210 }
                        let o = ((f * h + y) * w + x) * 3
                        var rr = g, gg = g, bb = g
                        if inFan && d < rad - 6 && dx > 0 && f % 10 < 5 { rr = 200; gg = 40; bb = 40 } // colour Doppler blob
                        p[o] = UInt8(max(0, min(255, rr))); p[o + 1] = UInt8(max(0, min(255, gg))); p[o + 2] = UInt8(max(0, min(255, bb)))
                    }
                }
            }
        }
        ds.set(.pixelData, .OB, data: px)
        try DICOMWriter.fileData(ds, transferSyntax: .explicitVRLittleEndian).write(to: out.appendingPathComponent("US0001.dcm"))
    }

    static func writeCR(to dir: URL) throws {
        let out = dir.appendingPathComponent("CR_CHEST")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let study = UIDGenerator.make(), series = UIDGenerator.make()
        let size = 1024
        let ds = baseDataSet(patient: "PHANTOM^CHEST XRAY", pid: "SPC-0003", study: study, studyDesc: "Chest PA (synthetic)", series: series, seriesNumber: 1, seriesDesc: "PA", modality: "CR", sopClass: "1.2.840.10008.5.1.4.1.1.1", instance: 1)
        ds.set(.photometricInterpretation, .CS, string: "MONOCHROME1")
        ds.set(.imagerPixelSpacing, double: [0.35, 0.35])
        ds.set(.viewPosition, .CS, string: "PA")
        ds.set(.patientOrientation, .CS, strings: ["L", "F"])
        var vals = [UInt16](repeating: 0, count: size * size)
        for r in 0..<size {
            for c in 0..<size {
                // Project the CT phantom along y (AP) to make a radiograph
                let x = (Double(c) - 512) * 0.35, z = (512 - Double(r)) * 0.35
                var att = 0.0
                var y = -130.0
                while y < 140 { att += max(0, ctHU(x, y, z) + 1000) / 1000; y += 6 }
                vals[r * size + c] = UInt16(max(0, min(4095, 4095 - att * 55)))
            }
        }
        setPixels16(ds, rows: size, cols: size, values: vals, signed: false, bitsStored: 12)
        ds.set(.photometricInterpretation, .CS, string: "MONOCHROME1")
        ds.set(.windowCenter, double: [2400]); ds.set(.windowWidth, double: [3200])
        try DICOMWriter.fileData(ds, transferSyntax: .explicitVRLittleEndian).write(to: out.appendingPathComponent("CR0001.dcm"))
    }

    static func writeXA(to dir: URL) throws {
        let out = dir.appendingPathComponent("XA_DSA")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let study = UIDGenerator.make(), series = UIDGenerator.make()
        let size = 512, frames = 24
        let ds = baseDataSet(patient: "PHANTOM^ANGIO", pid: "SPC-0004", study: study, studyDesc: "Angiography (synthetic)", series: series, seriesNumber: 1, seriesDesc: "Run 1", modality: "XA", sopClass: "1.2.840.10008.5.1.4.1.1.12.1", instance: 1)
        ds.set(.samplesPerPixel, uint16: [1]); ds.set(.photometricInterpretation, .CS, string: "MONOCHROME2")
        ds.set(.rows, uint16: [UInt16(size)]); ds.set(.columns, uint16: [UInt16(size)])
        ds.set(.bitsAllocated, uint16: [8]); ds.set(.bitsStored, uint16: [8]); ds.set(.highBit, uint16: [7]); ds.set(.pixelRepresentation, uint16: [0])
        ds.set(.numberOfFrames, .IS, string: String(frames))
        ds.set(.cineRate, .IS, string: "6")
        ds.set(.frameTime, double: [166.7])
        ds.set(.positionerPrimaryAngle, double: [-12]); ds.set(.positionerSecondaryAngle, double: [8])
        ds.set(.imagerPixelSpacing, double: [0.3, 0.3])
        var px = Data(count: size * size * frames)
        px.withUnsafeMutableBytes { r in
            let p = r.bindMemory(to: UInt8.self)
            for f in 0..<frames {
                let fill = max(0, Double(f - 4)) / Double(frames - 8) // contrast arrival
                let shift = f > 12 ? 2 : 0 // small patient motion for pixel shift tests
                for y in 0..<size {
                    for x in 0..<size {
                        let xs = x - shift
                        var v = 170.0 - 40 * exp(-pow(Double(xs - 256) / 120, 2)) // soft tissue
                        if (xs / 40) % 3 == 0 && abs(y - 300) < 20 { v -= 60 } // bones
                        // vessel tree: main trunk + branches, visible according to fill
                        let trunk = abs(Double(xs) - (256 + 40 * sin(Double(y) / 80)))
                        let along = Double(y) / Double(size)
                        if trunk < 6 && along < fill * 1.3 { v -= 80 }
                        for b in 0..<4 {
                            let by = 120 + b * 90
                            let bx0 = 256 + 40 * sin(Double(by) / 80)
                            let dxv = Double(xs) - bx0, dyv = Double(y - by)
                            let lineDist = abs(dyv - dxv * (b % 2 == 0 ? 0.6 : -0.6)) / 1.17
                            if lineDist < 3.5 && abs(dxv) < 160 && fill > 0.2 + Double(b) * 0.15 { v -= 60 }
                        }
                        p[(f * size + y) * size + x] = UInt8(max(0, min(255, v)))
                    }
                }
            }
        }
        ds.set(.pixelData, .OB, data: px)
        try DICOMWriter.fileData(ds, transferSyntax: .explicitVRLittleEndian).write(to: out.appendingPathComponent("XA0001.dcm"))
    }

    static func writeSR(to dir: URL, study: String) throws {
        let out = dir.appendingPathComponent("SR")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let ds = baseDataSet(patient: "PHANTOM^CHEST ABDOMEN", pid: "SPC-0001", study: study, studyDesc: "CT Chest Abdomen (synthetic)", series: UIDGenerator.make(), seriesNumber: 99, seriesDesc: "Report", modality: "SR", sopClass: "1.2.840.10008.5.1.4.1.1.88.11", instance: 1)
        ds.set(.valueType, .CS, string: "CONTAINER")
        ds.set(.completionFlag, .CS, string: "COMPLETE")
        ds.set(.verificationFlag, .CS, string: "UNVERIFIED")
        func code(_ v: String, _ m: String) -> DataSet { let c = DataSet(); c.set(.codeValue, .SH, string: v); c.set(.codingSchemeDesignator, .SH, string: "DCM"); c.set(.codeMeaning, .LO, string: m); return c }
        ds.set(.conceptNameCodeSequence, sequence: [code("18748-4", "Diagnostic Imaging Report")])
        func text(_ name: String, _ value: String) -> DataSet {
            let t = DataSet(); t.set(.relationshipType, .CS, string: "CONTAINS"); t.set(.valueType, .CS, string: "TEXT")
            t.set(.conceptNameCodeSequence, sequence: [code("121071", name)]); t.set(.textValue, .UT, string: value); return t
        }
        ds.set(.contentSequence, sequence: [
            text("Findings", "Synthetic phantom. 2.8 cm hyperdense lesion in the right hepatic lobe with increased tracer uptake on PET. Kidneys enhance symmetrically."),
            text("Impression", "Test data only. Not a real patient."),
        ])
        try DICOMWriter.fileData(ds, transferSyntax: .explicitVRLittleEndian).write(to: out.appendingPathComponent("SR0001.dcm"))
    }

    static func writeAll(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let study = UIDGenerator.make()
        print("CT 512 x 512 x 200 (explicit LE)…")
        try writeCT(to: dir, slices: 200, size: 512, ts: .explicitVRLittleEndian, folder: "CT_THIN", study: study, seriesNumber: 2, desc: "Thin 1.5 mm (synthetic)")
        print("CT 5mm series (implicit LE)…")
        try writeCT(to: dir, slices: 60, size: 512, ts: .implicitVRLittleEndian, folder: "CT_5MM", study: study, seriesNumber: 3, desc: "Axial 5 mm (synthetic)")
        print("MR, PET, SR…")
        try writeMR(to: dir, study: study)
        try writePET(to: dir, study: study)
        try writeSR(to: dir, study: study)
        print("US, CR, XA…")
        try writeUS(to: dir)
        try writeCR(to: dir)
        try writeXA(to: dir)
        print("Codec variants…")
        let codecStudy = UIDGenerator.make()
        let variants: [(TransferSyntax, String)] = [(.explicitVRBigEndian, "TS_BIG_ENDIAN"), (.deflatedExplicitVRLittleEndian, "TS_DEFLATE"),
                                                     (.rleLossless, "TS_RLE"), (.jpegLosslessSV1, "TS_JPEG_LOSSLESS"), (.jpeg2000Lossless, "TS_J2K")]
        for (i, v) in variants.enumerated() {
            try writeCT(to: dir.appendingPathComponent("Codecs"), slices: 8, size: 256, ts: v.0, folder: v.1, study: codecStudy, seriesNumber: 10 + i, desc: v.0.name)
        }
        print("done: \(dir.path)")
    }
}
