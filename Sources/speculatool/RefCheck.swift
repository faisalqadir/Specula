import Foundation
import DICOMCore

/// Compares decoded pixels of compressed reference files against their uncompressed twins
/// (pydicom / pydicom-data conformance files).
enum RefCheck {
    struct Result { var ok: Bool; var detail: String }

    static func frames(_ url: URL) throws -> [PixelFrame] {
        let f = try DICOMFile.read(url: url)
        let n = PixelDecoder.availableFrames(f)
        return try (0..<n).map { try PixelDecoder.decodeFrame(f, frame: $0) }
    }

    static func values(_ fr: PixelFrame) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(fr.width * fr.height * (fr.isColor ? 3 : 1))
        fr.pixels.withUnsafeBytes { raw in
            let n = fr.width * fr.height
            switch fr.format {
            case .gray8: let p = raw.bindMemory(to: UInt8.self); for i in 0..<n { out.append(Double(p[i])) }
            case .gray16: let p = raw.bindMemory(to: UInt16.self); for i in 0..<n { out.append(Double(p[i])) }
            case .gray16Signed: let p = raw.bindMemory(to: Int16.self); for i in 0..<n { out.append(Double(p[i])) }
            case .float32: let p = raw.bindMemory(to: Float.self); for i in 0..<n { out.append(Double(p[i])) }
            case .rgba8: let p = raw.bindMemory(to: UInt8.self); for i in 0..<n { out.append(Double(p[i * 4])); out.append(Double(p[i * 4 + 1])); out.append(Double(p[i * 4 + 2])) }
            }
        }
        return out
    }

    static func compare(_ a: URL, _ b: URL, tolerance: Double) -> Result {
        do {
            let fa = try frames(a), fb = try frames(b)
            guard fa.count == fb.count, !fa.isEmpty else { return Result(ok: false, detail: "frame count \(fa.count) vs \(fb.count)") }
            var maxDiff = 0.0, sum = 0.0, n = 0
            for (x, y) in zip(fa, fb) {
                guard x.width == y.width, x.height == y.height else { return Result(ok: false, detail: "size \(x.width)x\(x.height) vs \(y.width)x\(y.height)") }
                let va = values(x), vb = values(y)
                guard va.count == vb.count else { return Result(ok: false, detail: "format \(x.format) vs \(y.format)") }
                for i in va.indices { let d = abs(va[i] - vb[i]); maxDiff = max(maxDiff, d); sum += d * d; n += 1 }
            }
            let rmse = sqrt(sum / Double(max(1, n)))
            let fmt = "\(fa[0].width)x\(fa[0].height)x\(fa.count) \(fa[0].format)/\(fb[0].format)"
            return Result(ok: maxDiff <= tolerance, detail: String(format: "max %.1f rmse %.3f  %@", maxDiff, rmse, fmt))
        } catch {
            return Result(ok: false, detail: "\(error.localizedDescription)")
        }
    }

    static func run(_ dirs: [URL]) {
        func find(_ name: String) -> URL? {
            for d in dirs { let u = d.appendingPathComponent(name); if FileManager.default.fileExists(atPath: u.path) { return u } }
            return nil
        }
        // (reference, test, tolerance)
        let pairs: [(String, String, Double)] = [
            ("MR_small.dcm", "MR_small_RLE.dcm", 0), ("MR_small.dcm", "MR_small_bigendian.dcm", 0), ("MR_small.dcm", "MR_small_expb.dcm", 0),
            ("MR_small.dcm", "MR_small_implicit.dcm", 0), ("MR_small.dcm", "MR_small_jp2klossless.dcm", 0), ("MR_small.dcm", "MR_small_jpeg_ls_lossless.dcm", 0),
            ("MR_small.dcm", "MR_small_padded.dcm", 0),
            ("emri_small.dcm", "emri_small_RLE.dcm", 0), ("emri_small.dcm", "emri_small_big_endian.dcm", 0),
            ("emri_small.dcm", "emri_small_jpeg_2k_lossless.dcm", 0), ("emri_small.dcm", "emri_small_jpeg_ls_lossless.dcm", 0),
            ("JPEG2000_UNC.dcm", "JPEG2000.dcm", 1),
            ("693_UNCR.dcm", "693_J2KR.dcm", 0), ("693_UNCI.dcm", "693_J2KI.dcm", 2),
            ("MR2_UNCR.dcm", "MR2_J2KR.dcm", 0), ("MR2_UNCI.dcm", "MR2_J2KI.dcm", 2),
            ("RG1_UNCR.dcm", "RG1_J2KR.dcm", 0), ("RG1_UNCI.dcm", "RG1_J2KI.dcm", 2),
            ("RG3_UNCR.dcm", "RG3_J2KR.dcm", 0), ("RG3_UNCI.dcm", "RG3_J2KI.dcm", 2),
            ("US1_UNCR.dcm", "US1_J2KR.dcm", 0), ("US1_UNCI.dcm", "US1_J2KI.dcm", 2),
            ("liver.dcm", "liver_deflate.dcm", 0), ("liver.dcm", "liver_expb.dcm", 0), ("liver.dcm", "liver_j2k.dcm", 0), ("liver.dcm", "liver_rle.dcm", 0),
            ("liver_nonbyte_aligned.dcm", "liver_nonbyte_aligned_deflate.dcm", 0), ("liver_nonbyte_aligned.dcm", "liver_nonbyte_aligned_j2k.dcm", 0),
            ("liver_nonbyte_aligned.dcm", "liver_nonbyte_aligned_rle.dcm", 0),
            ("OBXXXX1A.dcm", "OBXXXX1A_expb.dcm", 0), ("OBXXXX1A.dcm", "OBXXXX1A_rle.dcm", 0),
            ("OBXXXX1A_2frame.dcm", "OBXXXX1A_expb_2frame.dcm", 0), ("OBXXXX1A_2frame.dcm", "OBXXXX1A_rle_2frame.dcm", 0),
            ("SC_rgb.dcm", "SC_rgb_expb.dcm", 0), ("SC_rgb.dcm", "SC_rgb_rle.dcm", 0), ("SC_rgb_2frame.dcm", "SC_rgb_rle_2frame.dcm", 0),
            ("SC_rgb_2frame.dcm", "SC_rgb_expb_2frame.dcm", 0),
            ("SC_rgb_16bit.dcm", "SC_rgb_rle_16bit.dcm", 0), ("SC_rgb_16bit.dcm", "SC_rgb_expb_16bit.dcm", 0),
            ("SC_rgb_16bit_2frame.dcm", "SC_rgb_rle_16bit_2frame.dcm", 0),
            ("SC_rgb_32bit.dcm", "SC_rgb_rle_32bit.dcm", 0), ("SC_rgb_32bit.dcm", "SC_rgb_expb_32bit.dcm", 0),
            ("SC_rgb_32bit_2frame.dcm", "SC_rgb_rle_32bit_2frame.dcm", 0),
            ("SC_rgb_small_odd.dcm", "SC_rgb_small_odd_big_endian.dcm", 0), ("SC_rgb_small_odd.dcm", "SC_rgb_small_odd_jpeg.dcm", 12),
            ("SC_rgb_dcmtk_ebcr_dcmd.dcm", "SC_rgb_dcmtk_+eb+cr.dcm", 3), ("SC_rgb_dcmtk_ebcyn1_dcmd.dcm", "SC_rgb_dcmtk_+eb+cy+n1.dcm", 3),
            ("SC_rgb_dcmtk_ebcyn2_dcmd.dcm", "SC_rgb_dcmtk_+eb+cy+n2.dcm", 3), ("SC_rgb_dcmtk_ebcynp_dcmd.dcm", "SC_rgb_dcmtk_+eb+cy+np.dcm", 3),
            ("SC_rgb_dcmtk_ebcys2_dcmd.dcm", "SC_rgb_dcmtk_+eb+cy+s2.dcm", 3), ("SC_rgb_dcmtk_ebcys4_dcmd.dcm", "SC_rgb_dcmtk_+eb+cy+s4.dcm", 3),
            ("SC_rgb_jpeg_dcmd.dcm", "SC_jpeg_no_color_transform.dcm", 3),
            ("SC_rgb_gdcm2k_uncompressed.dcm", "SC_rgb_jpeg_gdcm.dcm", 40),
            ("JLSL_RGB_ILV0.dcm", "JLSL_RGB_ILV1.dcm", 0), ("JLSL_RGB_ILV0.dcm", "JLSL_RGB_ILV2.dcm", 0), ("JLSL_RGB_ILV0.dcm", "JLSN_RGB_ILV0.dcm", 3),
            ("color-pl.dcm", "color-px.dcm", 0),
            ("SC_rgb_dcmtk_ebcyn2_dcmd.dcm", "SC_ybr_full_uncompressed.dcm", 2), ("SC_rgb_dcmtk_ebcyn2_dcmd.dcm", "SC_ybr_full_422_uncompressed.dcm", 12),
            ("JPGExtended.dcm", "JPEG-lossy.dcm", 0),
            ("gdcm-US-ALOKA-16.dcm", "gdcm-US-ALOKA-16_big.dcm", 0),
        ]
        var fails = 0, passes = 0
        for (ref, test, tol) in pairs {
            guard let a = find(ref), let b = find(test) else { print("SKIP \(test) (missing)"); continue }
            let r = compare(a, b, tolerance: tol)
            print((r.ok ? "PASS " : "FAIL ") + test.padding(toLength: 38, withPad: " ", startingAt: 0) + " vs " + ref.padding(toLength: 30, withPad: " ", startingAt: 0) + r.detail)
            if r.ok { passes += 1 } else { fails += 1 }
        }
        // Decode-only files (no reference): report shape and range
        print("\nDecode-only:")
        let all = dirs.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }.filter { $0.pathExtension == "dcm" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let paired = Set(pairs.flatMap { [$0.0, $0.1] })
        for u in all where !paired.contains(u.lastPathComponent) {
            do {
                let f = try DICOMFile.read(url: u)
                let n = PixelDecoder.availableFrames(f)
                if n == 0 { print("  --   \(u.lastPathComponent) (no pixel data) [\(f.transferSyntax.name)]"); continue }
                let fr = try PixelDecoder.decodeFrame(f, frame: 0)
                print("  ok   \(u.lastPathComponent.padding(toLength: 44, withPad: " ", startingAt: 0)) \(fr.width)x\(fr.height)x\(n) \(fr.format) [\(fr.minValue), \(fr.maxValue)] \(f.transferSyntax.name)")
            } catch {
                print("  ERR  \(u.lastPathComponent.padding(toLength: 44, withPad: " ", startingAt: 0)) \(error.localizedDescription)")
            }
        }
        print("\n\(passes) passed, \(fails) failed")
    }
}
