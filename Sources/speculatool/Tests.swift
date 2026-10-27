import Foundation
import DICOMCore
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum Tests {
    static var failures = 0

    static func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : " — " + detail))
        if !ok { failures += 1 }
    }

    static func testImage(_ w: Int, _ h: Int, bits: Int, seed: UInt64 = 7) -> [UInt16] {
        var s = seed
        let maxv = Double((1 << bits) - 1)
        return (0..<(w * h)).map { i in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let x = Double(i % w), y = Double(i / w)
            let smooth = (sin(x / 9) * cos(y / 13) * 0.4 + 0.5) * maxv
            let noise = Double(s >> 54) - 512
            return UInt16(max(0, min(maxv, smooth + noise * maxv / 8000)))
        }
    }

    static func cgImage(gray8 px: [UInt8], _ w: Int, _ h: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func cgImage(rgb px: [UInt8], _ w: Int, _ h: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func encodeJPEG(_ img: CGImage, quality: Double, progressive: Bool) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if progressive { props[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// Reference decode through ImageIO into 8-bit RGBA or gray.
    static func imageIODecode(_ d: Data, gray: Bool) -> [UInt8] {
        let src = CGImageSourceCreateWithData(d as CFData, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let w = img.width, h = img.height
        if gray {
            var px = [UInt8](repeating: 0, count: w * h)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return px
        }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: img.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    static func runAll() throws {
        // JPEG lossless
        for bits in [8, 12, 16] {
            for pred in 1...7 {
                let w = 97, h = 61
                let img = testImage(w, h, bits: bits, seed: UInt64(bits * 10 + pred))
                let enc = JPEGLosslessEncoder.encode(samples: img, width: w, height: h, precision: bits, predictor: pred, restartInterval: pred == 3 ? w : 0)
                do {
                    let dec = try JPEGDecoder.decode(enc)
                    let ok = dec.samples == img
                    if !ok || pred == 1 || pred == 3 {
                        let bad = zip(dec.samples, img).enumerated().first { $0.element.0 != $0.element.1 }
                        check(ok, "JPEG lossless \(bits)-bit predictor \(pred)\(pred == 3 ? " +restart" : "")", ok ? "" : "first mismatch at \(bad?.offset ?? -1)")
                    }
                } catch { check(false, "JPEG lossless \(bits)/\(pred)", "\(error)") }
            }
        }
        // RLE
        for (bits, spp) in [(8, 1), (16, 1), (8, 3)] {
            let w = 123, h = 45
            let img = testImage(w * spp, h, bits: bits)
            let enc = RLECodec.encode(samples: img, width: w, height: h, samplesPerPixel: spp, bitsAllocated: bits)
            let dec = try RLECodec.decode(enc, width: w, height: h, samplesPerPixel: spp, bitsAllocated: bits)
            check(dec.samples == img, "RLE \(bits)-bit x\(spp)")
        }
        // JPEG baseline / progressive vs ImageIO
        let w = 157, h = 93
        let g8 = testImage(w, h, bits: 8).map { UInt8($0) }
        var rgb = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { rgb[i * 4] = g8[i]; rgb[i * 4 + 1] = UInt8((Int(g8[i]) * 3 / 4) & 255); rgb[i * 4 + 2] = UInt8(255 - Int(g8[i])); rgb[i * 4 + 3] = 255 }
        for (progressive, quality) in [(false, 0.9), (true, 0.9), (false, 1.0)] {
            for gray in [true, false] {
                let jpg = encodeJPEG(gray ? cgImage(gray8: g8, w, h) : cgImage(rgb: rgb, w, h), quality: quality, progressive: progressive)
                let sub = JPEGDecoder.frameInfo(jpg).map { "SOF\($0.process)" } ?? "?"
                do {
                    let mine = try JPEGDecoder.decode(jpg)
                    let ref = imageIODecode(jpg, gray: gray)
                    var maxDiff = 0, sum = 0.0
                    let comps = gray ? 1 : 3
                    for i in 0..<(w * h) {
                        for c in 0..<comps {
                            let a = Int(mine.samples[i * mine.components + min(c, mine.components - 1)])
                            let b = Int(ref[gray ? i : i * 4 + c])
                            maxDiff = max(maxDiff, abs(a - b)); sum += Double((a - b) * (a - b))
                        }
                    }
                    let rmse = sqrt(sum / Double(w * h * comps))
                    // Chroma upsampling filters differ between decoders, so colour allows small edge differences.
                    check(rmse < (gray ? 1.0 : 2.0) && maxDiff <= (gray ? 4 : 32), "JPEG \(progressive ? "progressive" : "baseline") q\(quality) \(gray ? "gray" : "colour") vs ImageIO", String(format: "max diff %d, rmse %.2f %@", maxDiff, rmse, sub))
                } catch { check(false, "JPEG \(progressive ? "progressive" : "baseline") \(gray ? "gray" : "colour")", "\(error)") }
            }
        }
        // JPEG 2000 via ImageIO
        for bits in [8] { // ImageIO only encodes 8-bit JPEG 2000
            let img = testImage(64, 48, bits: bits)
            if let j = JPEG2000Codec.encode(samples: img, width: 64, height: 48, bits: bits) {
                let info = JPEG2000Codec.siz(j)
                let dec = try JPEG2000Codec.decode(j)
                let diff = zip(dec.samples, img).map { abs(Int($0) - Int($1)) }.max() ?? -1
                check(diff == 0, "JPEG 2000 \(bits)-bit lossless (ImageIO)", "precision \(info?.precision ?? -1), max diff \(diff)")
            } else { check(false, "JPEG 2000 encode \(bits)") }
        }
        // Parser / writer round trip in every native syntax
        for ts in [TransferSyntax.implicitVRLittleEndian, .explicitVRLittleEndian, .explicitVRBigEndian, .deflatedExplicitVRLittleEndian] {
            let ds = DataSet()
            ds.set(.sopClassUID, .UI, string: "1.2.840.10008.5.1.4.1.1.7")
            ds.set(.sopInstanceUID, .UI, string: UIDGenerator.make())
            ds.set(.patientName, .PN, string: "Test^Round Trip")
            ds.set(.rows, uint16: [3]); ds.set(.columns, uint16: [2])
            ds.set(.pixelSpacing, double: [0.5, 0.25])
            ds.set(.imagePositionPatient, double: [-12.5, 3, 100.125])
            ds.set(Tag(0x0018, 0x9087), double: [1000.5], vr: .FD)
            let item = DataSet(); item.set(.codeValue, .SH, string: "ABC"); item.set(.codeMeaning, .LO, string: "Meaning")
            ds.set(.conceptNameCodeSequence, sequence: [item, item.copy()])
            ds.set(.pixelData, .OW, data: Data([1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 0xFF, 0x7F]))
            let file = DICOMWriter.fileData(ds, transferSyntax: ts)
            let back = try DICOMFile.parse(file)
            let b = back.dataSet
            let ok = b.string(.patientName) == "Test^Round Trip" && b.int(.rows) == 3 && b.doubles(.pixelSpacing) == [0.5, 0.25]
                && b.doubles(.imagePositionPatient) == [-12.5, 3, 100.125] && b.double(Tag(0x0018, 0x9087)) == 1000.5
                && b.sequence(.conceptNameCodeSequence)?.count == 2 && b.sequence(.conceptNameCodeSequence)?[1].string(.codeMeaning) == "Meaning"
                && back.transferSyntax == ts
            let px = try PixelDecoder.decodeFrame(back, frame: 0)
            let pxOK = px.storedValue(x: 1, y: 2) == 32767 && px.storedValue(x: 0, y: 1) == 3
            check(ok && pxOK, "Data set round trip \(ts.name)")
        }
        // Character sets (PS3.5 Annex H/I examples)
        let jp: [UInt8] = [0x59, 0x61, 0x6D, 0x61, 0x64, 0x61, 0x5E, 0x54, 0x61, 0x72, 0x6F, 0x75, 0x3D, 0x1B, 0x24, 0x42, 0x3B, 0x33, 0x45, 0x44, 0x1B, 0x28, 0x42, 0x5E, 0x1B, 0x24, 0x42, 0x42, 0x40, 0x4F, 0x3A, 0x1B, 0x28, 0x42, 0x3D, 0x1B, 0x24, 0x42, 0x24, 0x64, 0x24, 0x5E, 0x24, 0x40, 0x1B, 0x28, 0x42, 0x5E, 0x1B, 0x24, 0x42, 0x24, 0x3F, 0x24, 0x6D, 0x24, 0x26, 0x1B, 0x28, 0x42]
        let jps = DICOMStringDecoder(specificCharacterSet: ["", "ISO 2022 IR 87"]).decode(Data(jp), vr: .PN)
        check(jps == "Yamada^Tarou=山田^太郎=やまだ^たろう", "ISO 2022 IR 87 (Japanese)", jps)
        let kr: [UInt8] = [0x48, 0x6F, 0x6E, 0x67, 0x5E, 0x47, 0x69, 0x6C, 0x64, 0x6F, 0x6E, 0x67, 0x3D, 0x1B, 0x24, 0x29, 0x43, 0xFB, 0xF3, 0x5E, 0x1B, 0x24, 0x29, 0x43, 0xD1, 0xCE, 0xD4, 0xD7, 0x3D, 0x1B, 0x24, 0x29, 0x43, 0xC8, 0xAB, 0x5E, 0x1B, 0x24, 0x29, 0x43, 0xB1, 0xE6, 0xB5, 0xBF]
        let krs = DICOMStringDecoder(specificCharacterSet: ["", "ISO 2022 IR 149"]).decode(Data(kr), vr: .PN)
        check(krs == "Hong^Gildong=洪^吉洞=홍^길동", "ISO 2022 IR 149 (Korean)", krs)
        let utf = DICOMStringDecoder(specificCharacterSet: ["ISO_IR 192"]).decode(Data("Wang^XiaoDong=王^小東".utf8), vr: .PN)
        check(utf == "Wang^XiaoDong=王^小東", "ISO_IR 192 (UTF-8)")
        let latin = DICOMStringDecoder(specificCharacterSet: ["ISO_IR 100"]).decode(Data([0x42, 0x75, 0x63, 0x5E, 0x4A, 0xE9, 0x72, 0xF4, 0x6D, 0x65]), vr: .PN)
        check(latin == "Buc^Jérôme", "ISO_IR 100 (Latin-1)")
        // Dictionary
        check(DataDictionary.name(for: .sopInstanceUID) == "SOP Instance UID", "Dictionary display name", DataDictionary.name(for: .sopInstanceUID))
        check(DataDictionary.vr(for: Tag(0x6002, 0x3000)) == .OW, "Dictionary repeating group 60xx")
        print(failures == 0 ? "\nAll tests passed" : "\n\(failures) failure(s)")
        if failures > 0 { exit(2) }
    }

    /// Investigates how ImageIO presents signed and reduced-precision codestreams.
    static func j2kProbe() throws {
        let img: [UInt16] = (0..<(32 * 32)).map { UInt16($0 * 37 % 4096) }
        guard var j = JPEG2000Codec.encode(samples: img, width: 32, height: 32, bits: 16) else { print("encode failed"); return }
        print("SIZ:", JPEG2000Codec.siz(j).map { "\($0.precision) bits signed=\($0.signed)" } ?? "none")
        // flip the sign bit of Ssiz: decoder should now produce value - 32768 as signed
        let b = [UInt8](j)
        if let i = (0..<(b.count - 1)).first(where: { b[$0] == 0xFF && b[$0 + 1] == 0x51 }) {
            j[j.startIndex + i + 40] |= 0x80
            let dec = try JPEG2000Codec.decode(j)
            let expect = img.map { $0 &- 32768 }
            print("signed patch first values:", Array(dec.samples.prefix(6)), "expected", Array(expect.prefix(6)))
            let ok = dec.samples == expect
            print(ok ? "signed handling OK" : "signed handling MISMATCH")
        }
    }
}
