import Foundation

/// Converts encapsulated (compressed) pixel data to native pixel data.
public enum Transcoder {
    /// A copy of the file's data set with native pixel data, suitable for any uncompressed transfer syntax.
    public static func decompressed(_ file: DICOMFile) throws -> DataSet {
        let ds = file.dataSet.copy()
        guard file.transferSyntax.encapsulated, ds.contains(.pixelData) else { return ds }
        let frames = max(1, ds.int(.numberOfFrames) ?? 1)
        var out = Data()
        var format: PixelFrame.Format = .gray8
        for f in 0..<frames {
            let fr = try PixelDecoder.decodeFrame(file, frame: f)
            format = fr.format
            if fr.format == .rgba8 {
                var rgb = Data(count: fr.width * fr.height * 3)
                fr.pixels.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                    rgb.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                        let s = src.bindMemory(to: UInt8.self), d = dst.bindMemory(to: UInt8.self)
                        for i in 0..<(fr.width * fr.height) {
                            d[i * 3] = s[i * 4]; d[i * 3 + 1] = s[i * 4 + 1]; d[i * 3 + 2] = s[i * 4 + 2]
                        }
                    }
                }
                out.append(rgb)
            } else {
                out.append(fr.pixels)
            }
        }
        switch format {
        case .rgba8:
            ds.set(.samplesPerPixel, uint16: [3])
            ds.set(.photometricInterpretation, .CS, string: "RGB")
            ds.set(.planarConfiguration, uint16: [0])
            ds.set(.bitsAllocated, uint16: [8]); ds.set(.bitsStored, uint16: [8]); ds.set(.highBit, uint16: [7])
            ds.set(.pixelRepresentation, uint16: [0])
            for e: UInt16 in [0x1101, 0x1102, 0x1103, 0x1201, 0x1202, 0x1203] { _ = ds.remove(Tag(0x0028, e)) }
        case .gray8:
            ds.set(.samplesPerPixel, uint16: [1])
            let stored = min(8, ds.int(.bitsStored) ?? 8)
            ds.set(.bitsAllocated, uint16: [8]); ds.set(.bitsStored, uint16: [UInt16(stored)]); ds.set(.highBit, uint16: [UInt16(stored - 1)])
            ds.set(.pixelRepresentation, uint16: [0])
        case .gray16, .gray16Signed:
            ds.set(.samplesPerPixel, uint16: [1])
            let stored = min(16, ds.int(.bitsStored) ?? 16)
            ds.set(.bitsAllocated, uint16: [16]); ds.set(.bitsStored, uint16: [UInt16(stored)]); ds.set(.highBit, uint16: [UInt16(stored - 1)])
            ds.set(.pixelRepresentation, uint16: [format == .gray16Signed ? 1 : 0])
        case .float32:
            throw DICOMError.unsupported("float pixel data cannot be transcoded")
        }
        if out.count % 2 == 1 { out.append(0) }
        ds.set(.pixelData, format == .gray16 || format == .gray16Signed ? .OW : .OB, data: out)
        if file.transferSyntax.lossy { ds.set(.lossyImageCompression, .CS, string: "01") }
        return ds
    }
}
