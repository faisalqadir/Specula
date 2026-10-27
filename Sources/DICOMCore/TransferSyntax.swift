import Foundation

public enum PixelCodec: Sendable {
    case native
    case rle
    case jpegProcess1      // baseline 8-bit
    case jpegProcess2_4    // extended 12-bit
    case jpegLossless      // process 14 / SV1
    case jpegLS
    case jpeg2000
    case htj2k
    case mpeg2
    case h264
    case hevc
    case deflatedFrame
    case encapsulatedUncompressed
    case jpegXL
    case unknown
}

public struct TransferSyntax: Hashable, Sendable, CustomStringConvertible {
    public let uid: String
    public let name: String
    public let explicitVR: Bool
    public let bigEndian: Bool
    public let deflated: Bool
    public let encapsulated: Bool
    public let codec: PixelCodec
    public let lossy: Bool

    public static func == (a: TransferSyntax, b: TransferSyntax) -> Bool { a.uid == b.uid }
    public func hash(into h: inout Hasher) { h.combine(uid) }
    public var description: String { name }

    public static let implicitVRLittleEndian = TransferSyntax(uid: "1.2.840.10008.1.2", name: "Implicit VR Little Endian", explicitVR: false, bigEndian: false, deflated: false, encapsulated: false, codec: .native, lossy: false)
    public static let explicitVRLittleEndian = TransferSyntax(uid: "1.2.840.10008.1.2.1", name: "Explicit VR Little Endian", explicitVR: true, bigEndian: false, deflated: false, encapsulated: false, codec: .native, lossy: false)
    public static let deflatedExplicitVRLittleEndian = TransferSyntax(uid: "1.2.840.10008.1.2.1.99", name: "Deflated Explicit VR Little Endian", explicitVR: true, bigEndian: false, deflated: true, encapsulated: false, codec: .native, lossy: false)
    public static let explicitVRBigEndian = TransferSyntax(uid: "1.2.840.10008.1.2.2", name: "Explicit VR Big Endian", explicitVR: true, bigEndian: true, deflated: false, encapsulated: false, codec: .native, lossy: false)
    public static let rleLossless = TransferSyntax(uid: "1.2.840.10008.1.2.5", name: "RLE Lossless", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .rle, lossy: false)
    public static let jpegBaseline = TransferSyntax(uid: "1.2.840.10008.1.2.4.50", name: "JPEG Baseline (Process 1)", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .jpegProcess1, lossy: true)
    public static let jpegExtended = TransferSyntax(uid: "1.2.840.10008.1.2.4.51", name: "JPEG Extended (Process 2 & 4)", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .jpegProcess2_4, lossy: true)
    public static let jpegLosslessP14 = TransferSyntax(uid: "1.2.840.10008.1.2.4.57", name: "JPEG Lossless, Non-Hierarchical (Process 14)", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .jpegLossless, lossy: false)
    public static let jpegLosslessSV1 = TransferSyntax(uid: "1.2.840.10008.1.2.4.70", name: "JPEG Lossless, First-Order Prediction (Process 14 SV1)", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .jpegLossless, lossy: false)
    public static let jpegLSLossless = TransferSyntax(uid: "1.2.840.10008.1.2.4.80", name: "JPEG-LS Lossless", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .jpegLS, lossy: false)
    public static let jpegLSNearLossless = TransferSyntax(uid: "1.2.840.10008.1.2.4.81", name: "JPEG-LS Near-Lossless", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .jpegLS, lossy: true)
    public static let jpeg2000Lossless = TransferSyntax(uid: "1.2.840.10008.1.2.4.90", name: "JPEG 2000 (Lossless Only)", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .jpeg2000, lossy: false)
    public static let jpeg2000 = TransferSyntax(uid: "1.2.840.10008.1.2.4.91", name: "JPEG 2000", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .jpeg2000, lossy: true)
    public static let jpeg2000MCLossless = TransferSyntax(uid: "1.2.840.10008.1.2.4.92", name: "JPEG 2000 Part 2 Multi-component (Lossless Only)", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .jpeg2000, lossy: false)
    public static let jpeg2000MC = TransferSyntax(uid: "1.2.840.10008.1.2.4.93", name: "JPEG 2000 Part 2 Multi-component", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .jpeg2000, lossy: true)
    public static let htj2kLossless = TransferSyntax(uid: "1.2.840.10008.1.2.4.201", name: "High-Throughput JPEG 2000 (Lossless Only)", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .htj2k, lossy: false)
    public static let htj2kLosslessRPCL = TransferSyntax(uid: "1.2.840.10008.1.2.4.202", name: "High-Throughput JPEG 2000 with RPCL Options (Lossless Only)", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .htj2k, lossy: false)
    public static let htj2k = TransferSyntax(uid: "1.2.840.10008.1.2.4.203", name: "High-Throughput JPEG 2000", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .htj2k, lossy: true)
    public static let mpeg2MPML = TransferSyntax(uid: "1.2.840.10008.1.2.4.100", name: "MPEG2 Main Profile @ Main Level", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .mpeg2, lossy: true)
    public static let mpeg2MPHL = TransferSyntax(uid: "1.2.840.10008.1.2.4.101", name: "MPEG2 Main Profile @ High Level", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .mpeg2, lossy: true)
    public static let mpeg4HP41 = TransferSyntax(uid: "1.2.840.10008.1.2.4.102", name: "MPEG-4 AVC/H.264 High Profile / Level 4.1", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .h264, lossy: true)
    public static let mpeg4HP41BD = TransferSyntax(uid: "1.2.840.10008.1.2.4.103", name: "MPEG-4 AVC/H.264 BD-compatible High Profile / Level 4.1", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .h264, lossy: true)
    public static let mpeg4HP42_2D = TransferSyntax(uid: "1.2.840.10008.1.2.4.104", name: "MPEG-4 AVC/H.264 High Profile / Level 4.2 For 2D Video", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .h264, lossy: true)
    public static let mpeg4HP42_3D = TransferSyntax(uid: "1.2.840.10008.1.2.4.105", name: "MPEG-4 AVC/H.264 High Profile / Level 4.2 For 3D Video", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .h264, lossy: true)
    public static let mpeg4StereoHP42 = TransferSyntax(uid: "1.2.840.10008.1.2.4.106", name: "MPEG-4 AVC/H.264 Stereo High Profile / Level 4.2", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .h264, lossy: true)
    public static let hevcMP51 = TransferSyntax(uid: "1.2.840.10008.1.2.4.107", name: "HEVC/H.265 Main Profile / Level 5.1", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .hevc, lossy: true)
    public static let hevcM10P51 = TransferSyntax(uid: "1.2.840.10008.1.2.4.108", name: "HEVC/H.265 Main 10 Profile / Level 5.1", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .hevc, lossy: true)

    public static let deflatedImageFrame = TransferSyntax(uid: "1.2.840.10008.1.2.8.1", name: "Deflated Image Frame Compression", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .deflatedFrame, lossy: false)
    public static let encapsulatedUncompressed = TransferSyntax(uid: "1.2.840.10008.1.2.1.98", name: "Encapsulated Uncompressed Explicit VR Little Endian", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .encapsulatedUncompressed, lossy: false)
    public static let jpegXLLossless = TransferSyntax(uid: "1.2.840.10008.1.2.4.110", name: "JPEG XL Lossless", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .jpegXL, lossy: false)
    public static let jpegXLRecompression = TransferSyntax(uid: "1.2.840.10008.1.2.4.111", name: "JPEG XL JPEG Recompression", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .jpegXL, lossy: true)
    public static let jpegXL = TransferSyntax(uid: "1.2.840.10008.1.2.4.112", name: "JPEG XL", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .jpegXL, lossy: true)

    public static let all: [TransferSyntax] = [
        .implicitVRLittleEndian, .explicitVRLittleEndian, .deflatedExplicitVRLittleEndian, .explicitVRBigEndian,
        .rleLossless, .jpegBaseline, .jpegExtended, .jpegLosslessP14, .jpegLosslessSV1, .jpegLSLossless, .jpegLSNearLossless,
        .jpeg2000Lossless, .jpeg2000, .jpeg2000MCLossless, .jpeg2000MC, .htj2kLossless, .htj2kLosslessRPCL, .htj2k,
        .mpeg2MPML, .mpeg2MPHL, .mpeg4HP41, .mpeg4HP41BD, .mpeg4HP42_2D, .mpeg4HP42_3D, .mpeg4StereoHP42, .hevcMP51, .hevcM10P51,
        .deflatedImageFrame, .encapsulatedUncompressed, .jpegXLLossless, .jpegXLRecompression, .jpegXL,
    ]

    private static let byUID: [String: TransferSyntax] = Dictionary(uniqueKeysWithValues: all.map { ($0.uid, $0) })

    public static func lookup(_ uid: String) -> TransferSyntax? { byUID[uid.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))] }

    /// Returns a known syntax or an unknown encapsulated one (explicit LE) for an unrecognised UID.
    public static func resolve(_ uid: String) -> TransferSyntax {
        if let ts = lookup(uid) { return ts }
        let clean = uid.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return TransferSyntax(uid: clean, name: "Unknown (\(clean))", explicitVR: true, bigEndian: false, deflated: false, encapsulated: true, codec: .unknown, lossy: false)
    }

    public var isVideo: Bool { codec == .mpeg2 || codec == .h264 || codec == .hevc }
}
