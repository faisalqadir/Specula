import Foundation
import CommonCrypto

/// Read-only ZIP archive support: stored / deflate, ZIP64, traditional PKWARE and WinZip AES encryption.
public final class ZipArchive {
    public struct Entry {
        public let path: String
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let method: UInt16
        public let crc32: UInt32
        public let localHeaderOffset: UInt64
        public let encrypted: Bool
        public let aesStrength: Int?      // 1/2/3 = 128/192/256 bit
        public let aesMethod: UInt16?
        public let dosTime: UInt16
        public var isDirectory: Bool { path.hasSuffix("/") }
    }

    public enum ZipError: Error, LocalizedError {
        case notZip, corrupt, unsupportedMethod(UInt16), passwordRequired, wrongPassword, checksum
        public var errorDescription: String? {
            switch self {
            case .notZip: return "Not a ZIP archive"
            case .corrupt: return "The ZIP archive is damaged"
            case .unsupportedMethod(let m): return "Unsupported ZIP compression method \(m)"
            case .passwordRequired: return "The archive is password protected"
            case .wrongPassword: return "Wrong password"
            case .checksum: return "CRC check failed"
            }
        }
    }

    public let url: URL
    public private(set) var entries: [Entry] = []
    private let data: Data

    public init(url: URL) throws {
        self.url = url
        data = try Data(contentsOf: url, options: .alwaysMapped)
        try readDirectory()
    }

    public var isEncrypted: Bool { entries.contains { $0.encrypted } }

    private func u16(_ o: Int) -> UInt16 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian } }
    private func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian } }
    private func u64(_ o: Int) -> UInt64 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self).littleEndian } }

    private func readDirectory() throws {
        let n = data.count
        guard n >= 22 else { throw ZipError.notZip }
        // End of central directory
        var eocd = -1
        var i = n - 22
        let stop = max(0, n - 65557)
        while i >= stop {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        var count = UInt64(u16(eocd + 10))
        var cdOffset = UInt64(u32(eocd + 16))
        // ZIP64 locator
        if eocd >= 20, u32(eocd - 20) == 0x0706_4B50 {
            let z64 = Int(u64(eocd - 12))
            if z64 + 56 <= n, u32(z64) == 0x0606_4B50 {
                count = u64(z64 + 32)
                cdOffset = u64(z64 + 48)
            }
        }
        var p = Int(cdOffset)
        for _ in 0..<count {
            guard p + 46 <= n, u32(p) == 0x0201_4B50 else { throw ZipError.corrupt }
            let flags = u16(p + 8)
            let method = u16(p + 10)
            let time = u16(p + 12)
            let crc = u32(p + 16)
            var csize = UInt64(u32(p + 20)), usize = UInt64(u32(p + 24))
            let nameLen = Int(u16(p + 28)), extraLen = Int(u16(p + 30)), commentLen = Int(u16(p + 32))
            var lho = UInt64(u32(p + 42))
            guard p + 46 + nameLen + extraLen <= n else { throw ZipError.corrupt }
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLen))
            let name = (flags & 0x800 != 0 ? String(data: nameData, encoding: .utf8) : String(data: nameData, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))))) ?? String(decoding: nameData, as: UTF8.self)
            var aesStrength: Int? = nil, aesMethod: UInt16? = nil
            var e = p + 46 + nameLen
            let eEnd = e + extraLen
            while e + 4 <= eEnd {
                let id = u16(e), sz = Int(u16(e + 2))
                if id == 0x0001 {
                    var q = e + 4
                    if usize == 0xFFFF_FFFF { usize = u64(q); q += 8 }
                    if csize == 0xFFFF_FFFF { csize = u64(q); q += 8 }
                    if lho == 0xFFFF_FFFF { lho = u64(q); q += 8 }
                } else if id == 0x9901, sz >= 7 {
                    aesStrength = Int(data[data.startIndex + e + 8])
                    aesMethod = u16(e + 9)
                }
                e += 4 + sz
            }
            entries.append(Entry(path: name, compressedSize: csize, uncompressedSize: usize, method: method, crc32: crc,
                                 localHeaderOffset: lho, encrypted: flags & 1 != 0, aesStrength: aesStrength, aesMethod: aesMethod, dosTime: time))
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    /// Extracts one entry. `password` is required for encrypted entries.
    public func extract(_ entry: Entry, password: String? = nil) throws -> Data {
        let lh = Int(entry.localHeaderOffset)
        guard lh + 30 <= data.count, u32(lh) == 0x0403_4B50 else { throw ZipError.corrupt }
        let start = lh + 30 + Int(u16(lh + 26)) + Int(u16(lh + 28))
        let end = start + Int(entry.compressedSize)
        guard end <= data.count else { throw ZipError.corrupt }
        var payload = data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
        var method = entry.method
        if entry.encrypted {
            guard let password, !password.isEmpty else { throw ZipError.passwordRequired }
            if method == 99, let strength = entry.aesStrength {
                payload = try decryptAES(payload, password: password, strength: strength)
                method = entry.aesMethod ?? 8
            } else {
                payload = try decryptTraditional(payload, password: password, entry: entry)
            }
        }
        let out: Data
        switch method {
        case 0: out = payload
        case 8:
            guard let d = Inflate.raw(payload, expectedSize: Int(entry.uncompressedSize)) else { throw ZipError.corrupt }
            out = d
        default: throw ZipError.unsupportedMethod(method)
        }
        if entry.aesStrength == nil || entry.crc32 != 0 {
            if ZipArchive.crc32(out) != entry.crc32 {
                throw entry.encrypted ? ZipError.wrongPassword : ZipError.checksum
            }
        }
        return out
    }

    // MARK: - CRC

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        d.withUnsafeBytes { raw in
            for b in raw { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: - Traditional PKWARE encryption

    private func decryptTraditional(_ d: Data, password: String, entry: Entry) throws -> Data {
        var k0: UInt32 = 0x1234_5678, k1: UInt32 = 0x2345_6789, k2: UInt32 = 0x3456_7890
        func update(_ c: UInt8) {
            k0 = ZipArchive.crcTable[Int((k0 ^ UInt32(c)) & 0xFF)] ^ (k0 >> 8)
            k1 = (k1 &+ (k0 & 0xFF)) &* 134_775_813 &+ 1
            k2 = ZipArchive.crcTable[Int((k2 ^ (k1 >> 24)) & 0xFF)] ^ (k2 >> 8)
        }
        for c in password.utf8 { update(c) }
        var out = [UInt8](repeating: 0, count: d.count)
        d.withUnsafeBytes { raw in
            for (i, b) in raw.enumerated() {
                let t = UInt16(truncatingIfNeeded: k2 | 2)
                let p = b ^ UInt8(truncatingIfNeeded: (UInt32(t) &* UInt32(t ^ 1)) >> 8)
                update(p)
                out[i] = p
            }
        }
        guard out.count >= 12 else { throw ZipError.corrupt }
        let check = out[11]
        if check != UInt8(entry.crc32 >> 24) && check != UInt8(entry.dosTime >> 8) { throw ZipError.wrongPassword }
        return Data(out[12...])
    }

    // MARK: - WinZip AES

    private func decryptAES(_ d: Data, password: String, strength: Int) throws -> Data {
        let keyLen = [1: 16, 2: 24, 3: 32][strength] ?? 32
        let saltLen = keyLen / 2
        guard d.count >= saltLen + 2 + 10 else { throw ZipError.corrupt }
        let salt = d.prefix(saltLen)
        let verify = d.subdata(in: (d.startIndex + saltLen)..<(d.startIndex + saltLen + 2))
        let body = d.subdata(in: (d.startIndex + saltLen + 2)..<(d.endIndex - 10))
        let mac = d.suffix(10)
        var derived = [UInt8](repeating: 0, count: 2 * keyLen + 2)
        let pw = Array(password.utf8)
        _ = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, saltLen, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000, &derived, derived.count)
        }
        guard Data(derived[(2 * keyLen)...]) == verify else { throw ZipError.wrongPassword }
        let encKey = Array(derived[0..<keyLen]), authKey = Array(derived[keyLen..<(2 * keyLen)])
        // Authenticate
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        body.withUnsafeBytes { b in CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), authKey, authKey.count, b.baseAddress, b.count, &hmac) }
        guard Data(hmac.prefix(10)) == Data(mac) else { throw ZipError.wrongPassword }
        // AES-CTR with little-endian counter starting at 1
        var out = [UInt8](repeating: 0, count: body.count)
        var counter = [UInt8](repeating: 0, count: 16)
        var keystream = [UInt8](repeating: 0, count: 16)
        var cryptor: CCCryptorRef?
        CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), encKey, keyLen, nil, &cryptor)
        defer { CCCryptorRelease(cryptor) }
        body.withUnsafeBytes { raw in
            var i = 0
            var ctr: UInt64 = 1
            while i < raw.count {
                withUnsafeBytes(of: ctr.littleEndian) { for k in 0..<8 { counter[k] = $0[k] } }
                var moved = 0
                CCCryptorUpdate(cryptor, counter, 16, &keystream, 16, &moved)
                let n = min(16, raw.count - i)
                for k in 0..<n { out[i + k] = raw[i + k] ^ keystream[k] }
                i += 16
                ctr += 1
            }
        }
        return Data(out)
    }
}

/// DICOMDIR reader: returns referenced file URLs relative to the DICOMDIR location.
public enum DICOMDIRReader {
    public static func referencedFiles(dicomdir url: URL) -> [URL] {
        guard let f = try? DICOMFile.read(url: url, options: .full),
              let records = f.dataSet.sequence(.directoryRecordSequence) else { return [] }
        let base = url.deletingLastPathComponent()
        var out: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for r in records {
            let comps = r.strings(.referencedFileID).filter { !$0.isEmpty }
            guard !comps.isEmpty else { continue }
            var u = base
            for c in comps { u.appendPathComponent(c) }
            var path = u.path
            if !fm.fileExists(atPath: path) {
                // Resolve case differences on case-sensitive volumes
                var cur = base
                var ok = true
                for c in comps {
                    let items = (try? fm.contentsOfDirectory(atPath: cur.path)) ?? []
                    if let m = items.first(where: { $0.caseInsensitiveCompare(c) == .orderedSame || $0.caseInsensitiveCompare(c + ".") == .orderedSame }) {
                        cur.appendPathComponent(m)
                    } else { ok = false; break }
                }
                if ok { path = cur.path; u = cur } else { continue }
            }
            if seen.insert(path).inserted { out.append(u) }
        }
        return out
    }
}
