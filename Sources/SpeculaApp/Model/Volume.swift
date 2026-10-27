import Foundation
import Metal
import simd
import DICOMCore

/// A 3D voxel grid built from a stack of parallel images, uploaded as a 3D texture.
final class Volume {
    let series: Series
    let width: Int, height: Int, depth: Int
    let origin: Vec3          // centre of voxel (0,0,0)
    let rowDir: Vec3          // +i
    let colDir: Vec3          // +j
    let sliceDir: Vec3        // +k (may be oblique for gantry tilt)
    let spacing: Vec3         // (dx = column spacing, dy = row spacing, dz = slice step)
    let texture: MTLTexture
    let valueScale: Float     // texel (snorm) -> modality value
    let minValue: Double
    let maxValue: Double
    let modality: String
    let irregular: Bool
    let tilted: Bool
    let voxels: [Int16]       // CPU copy (scaled), used for statistics, STL export
    let scale: Double         // voxel int -> modality value
    let images: [ImageRef]
    let isColor = false
    var units: String { modality == "CT" ? "HU" : "" }

    var dims: SIMD3<Int> { SIMD3(width, height, depth) }
    var extentMM: Vec3 { Vec3(Double(width) * spacing.x, Double(height) * spacing.y, Double(depth) * spacing.z) }

    /// Voxel index (fractional) -> patient coordinate.
    func patient(i: Double, j: Double, k: Double) -> Vec3 {
        origin + rowDir * (i * spacing.x) + colDir * (j * spacing.y) + sliceDir * (k * spacing.z)
    }

    /// Patient coordinate -> fractional voxel index.
    func voxel(of p: Vec3) -> Vec3 {
        let m = simd_double3x3(columns: (rowDir * spacing.x, colDir * spacing.y, sliceDir * spacing.z))
        return m.inverse * (p - origin)
    }

    var center: Vec3 { patient(i: Double(width - 1) / 2, j: Double(height - 1) / 2, k: Double(depth - 1) / 2) }

    /// 4x4 mapping patient mm -> normalised texture coordinates.
    var patientToTex: simd_float4x4 {
        let m = simd_double3x3(columns: (rowDir * spacing.x, colDir * spacing.y, sliceDir * spacing.z)).inverse
        // tex = (m * (p - origin) + 0.5) / dims
        let inv = Vec3(1 / Double(width), 1 / Double(height), 1 / Double(depth))
        var r = matrix_identity_double4x4
        for c in 0..<3 {
            r[c] = SIMD4<Double>(m[c].x * inv.x, m[c].y * inv.y, m[c].z * inv.z, 0)
        }
        let t = -(m * origin)
        r[3] = SIMD4<Double>((t.x + 0.5) * inv.x, (t.y + 0.5) * inv.y, (t.z + 0.5) * inv.z, 1)
        return simd_float4x4(columns: (SIMD4<Float>(r[0]), SIMD4<Float>(r[1]), SIMD4<Float>(r[2]), SIMD4<Float>(r[3])))
    }

    func value(atVoxel i: Int, _ j: Int, _ k: Int) -> Double? {
        guard i >= 0, j >= 0, k >= 0, i < width, j < height, k < depth else { return nil }
        return Double(voxels[(k * height + j) * width + i]) * scale
    }

    func value(atPatient p: Vec3) -> Double? {
        let v = voxel(of: p)
        return value(atVoxel: Int(v.x.rounded()), Int(v.y.rounded()), Int(v.z.rounded()))
    }

    private init(series: Series, images: [ImageRef], width: Int, height: Int, depth: Int, origin: Vec3, rowDir: Vec3, colDir: Vec3, sliceDir: Vec3, spacing: Vec3,
                 texture: MTLTexture, valueScale: Float, scale: Double, minValue: Double, maxValue: Double, irregular: Bool, tilted: Bool, voxels: [Int16]) {
        self.series = series
        self.images = images
        self.width = width; self.height = height; self.depth = depth
        self.origin = origin; self.rowDir = rowDir; self.colDir = colDir; self.sliceDir = sliceDir; self.spacing = spacing
        self.texture = texture; self.valueScale = valueScale; self.scale = scale
        self.minValue = minValue; self.maxValue = maxValue
        self.modality = series.modality
        self.irregular = irregular; self.tilted = tilted
        self.voxels = voxels
    }

    enum BuildError: Error, LocalizedError {
        case notAVolume, decode(String), tooLarge
        var errorDescription: String? {
            switch self {
            case .notAVolume: return "This series cannot be used for 3D reconstruction (it needs at least 3 parallel slices of equal size)."
            case .decode(let s): return "The volume could not be loaded: \(s)"
            case .tooLarge: return "The volume is too large for GPU memory."
            }
        }
    }

    private static var cache: [ObjectIdentifier: Volume] = [:]
    private static let cacheLock = NSLock()

    static func cached(for series: Series) -> Volume? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let v = cache[ObjectIdentifier(series)], v.images.count == series.images.count { return v }
        return nil
    }

    /// Builds asynchronously; progress is reported on the main thread (0...1).
    static func build(series: Series, progress: @escaping (Double) -> Void, completion: @escaping (Result<Volume, Error>) -> Void) {
        if let v = cached(for: series) { completion(.success(v)); return }
        let images = series.images
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let v = try make(series: series, images: images, progress: { p in DispatchQueue.main.async { progress(p) } })
                cacheLock.lock(); cache[ObjectIdentifier(series)] = v; cacheLock.unlock()
                DispatchQueue.main.async { completion(.success(v)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    static func make(series: Series, images input: [ImageRef], progress: (Double) -> Void) throws -> Volume {
        let refs = input.filter { $0.plane != nil }
        guard refs.count >= 3, let p0 = refs.first?.plane else { throw BuildError.notAVolume }
        let normal = p0.normal
        guard refs.allSatisfy({ ($0.plane!.normal.dot(normal)) > 0.99 && $0.plane!.rows == p0.rows && $0.plane!.columns == p0.columns }) else { throw BuildError.notAVolume }
        // Sort along the normal, drop duplicates (same position, e.g. multiple phases keep first)
        var sorted = refs.sorted { $0.plane!.position.dot(normal) < $1.plane!.position.dot(normal) }
        var unique: [ImageRef] = []
        for r in sorted {
            if let last = unique.last, abs(last.plane!.position.dot(normal) - r.plane!.position.dot(normal)) < 1e-3 { continue }
            unique.append(r)
        }
        sorted = unique
        guard sorted.count >= 3 else { throw BuildError.notAVolume }
        let w = p0.columns, h = p0.rows, d = sorted.count
        guard Double(w * h * d) * 2 < 3.5e9 else { throw BuildError.tooLarge }
        let positions = sorted.map { $0.plane!.position.dot(normal) }
        let diffs = zip(positions.dropFirst(), positions).map { $0 - $1 }
        let mean = (positions.last! - positions.first!) / Double(d - 1)
        let irregular = diffs.contains { abs($0 - mean) > max(0.1 * mean, 0.05) }
        let first = sorted.first!.plane!, last = sorted.last!.plane!
        let span = last.position - first.position
        let sliceDir = span.normalized
        let tilted = sliceDir.dot(normal) < 0.999
        let dz = span.length / Double(d - 1)

        // Decode and convert to modality values
        var floatSlices = [[Float]](repeating: [], count: d)
        var errorMessage: String?
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: d) { k in
            let ref = sorted[k]
            do {
                let f = try FrameCache.shared.decode(ref)
                var v = f.floatValues()
                let a = ref.attributes
                let s = Float(a.rescaleSlope), b = Float(a.rescaleIntercept)
                if s != 1 || b != 0 { for i in v.indices { v[i] = v[i] * s + b } }
                if v.count != w * h { v = [Float](repeating: 0, count: w * h) }
                lock.lock(); floatSlices[k] = v; done += 1; let p = Double(done) / Double(d); lock.unlock()
                if k % 8 == 0 { progress(p * 0.9) }
            } catch {
                lock.lock(); errorMessage = error.localizedDescription; lock.unlock()
            }
        }
        if let e = errorMessage, floatSlices.contains(where: { $0.isEmpty }) { throw BuildError.decode(e) }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        var integral = true
        for s in floatSlices {
            for v in s {
                if v < lo { lo = v }
                if v > hi { hi = v }
                if integral && v != v.rounded() { integral = false }
            }
        }
        let maxAbs = max(abs(lo), abs(hi), 1)
        let scale: Double = (integral && maxAbs <= 32767) ? 1 : Double(maxAbs) / 32767
        var voxels = [Int16](repeating: 0, count: w * h * d)
        voxels.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: d) { k in
                let base = k * w * h
                let inv = Float(1 / scale)
                let s = floatSlices[k]
                for i in 0..<(w * h) { buf[base + i] = Int16(max(-32767, min(32767, (s[i] * inv).rounded()))) }
            }
        }
        progress(0.95)
        let td = MTLTextureDescriptor()
        td.textureType = .type3D
        td.pixelFormat = .r16Snorm
        td.width = w; td.height = h; td.depth = d
        td.usage = [.shaderRead]
        td.storageMode = .shared
        guard let tex = MetalContext.shared.device.makeTexture(descriptor: td) else { throw BuildError.tooLarge }
        voxels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake3D(0, 0, 0, w, h, d), mipmapLevel: 0, slice: 0, withBytes: raw.baseAddress!, bytesPerRow: w * 2, bytesPerImage: w * h * 2)
        }
        progress(1)
        let sp = Vec3(first.columnSpacing, first.rowSpacing, dz)
        return Volume(series: series, images: sorted, width: w, height: h, depth: d, origin: first.position, rowDir: first.rowDirection, colDir: first.columnDirection,
                      sliceDir: sliceDir, spacing: sp, texture: tex, valueScale: Float(32767 * scale), scale: scale,
                      minValue: Double(lo), maxValue: Double(hi), irregular: irregular, tilted: tilted, voxels: voxels)
    }
}
