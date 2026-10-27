import Foundation
import DICOMCore
import DICOMNet
import ImageIO
import CoreGraphics

extension Array { subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil } }

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("""
    usage: speculatool <command> [args]
      dump <file>                 print data set
      decode <file>...            decode every frame and report value ranges
      roundtrip                   codec self tests
      phantom <dir>               write synthetic test studies
      j2kprobe                    probe ImageIO JPEG 2000 behaviour
      icon <dir>                  render the app icon PNG set
      net <echo|find|move|get|store|listen> host:port:AET [args]   DICOM network SCU/SCP
    """)
    exit(1)
}

func dump(_ ds: DataSet, indent: String = "") {
    for e in ds.sortedElements {
        let name = DataDictionary.name(for: e.tag)
        switch e.value {
        case .sequence(let items):
            print("\(indent)\(e.tag) SQ \(name) (\(items.count) items)")
            for (i, it) in items.enumerated() {
                print("\(indent)  > Item \(i + 1)")
                dump(it, indent: indent + "    ")
            }
        default:
            var v = ds.displayValue(e, maxValues: 16)
            if v.count > 100 { v = String(v.prefix(100)) + "…" }
            print("\(indent)\(e.tag) \(e.vr.rawValue) \(name.padding(toLength: 36, withPad: " ", startingAt: 0)) [\(v)]")
        }
    }
}

switch args[1] {
case "dump":
    let f = try DICOMFile.read(url: URL(fileURLWithPath: args[2]))
    print("# Transfer syntax: \(f.transferSyntax.name)")
    dump(f.fileMeta)
    dump(f.dataSet)

case "decode":
    for path in args.dropFirst(2) {
        let t0 = Date()
        do {
            let f = try DICOMFile.read(url: URL(fileURLWithPath: path))
            let n = PixelDecoder.availableFrames(f)
            var desc = ""
            for i in 0..<n {
                let fr = try PixelDecoder.decodeFrame(f, frame: i)
                if i == 0 { desc = "\(fr.width)x\(fr.height) \(fr.format) min \(fr.minValue) max \(fr.maxValue)" }
            }
            print(String(format: "%@: %@ frames=%d %.0f ms [%@]", (path as NSString).lastPathComponent, desc, n, Date().timeIntervalSince(t0) * 1000, f.transferSyntax.name))
        } catch {
            print("\((path as NSString).lastPathComponent): ERROR \(error.localizedDescription)")
        }
    }

case "roundtrip":
    try Tests.runAll()

case "phantom":
    try Phantom.writeAll(to: URL(fileURLWithPath: args[2]))

case "j2kprobe":
    try Tests.j2kProbe()

case "post":
    // Sends an automation command to a running debug build and prints the reply.
    let cmd = args.dropFirst(2).joined(separator: " ")
    var reply: String?
    let obs = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("app.specula.automation.reply"), object: nil, queue: nil) { n in reply = n.object as? String ?? "" }
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("app.specula.automation"), object: cmd, userInfo: nil, deliverImmediately: true)
    let deadline = Date().addingTimeInterval(20)
    while reply == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    DistributedNotificationCenter.default().removeObserver(obs)
    print(reply ?? "(no reply)")

case "pix":
    // pix <file> <frame> <x> <y> <count>
    let f = try DICOMFile.read(url: URL(fileURLWithPath: args[2]))
    let fr = try PixelDecoder.decodeFrame(f, frame: Int(args[3]) ?? 0)
    let x0 = Int(args[4]) ?? 0, y0 = Int(args[5]) ?? 0, cnt = Int(args[6]) ?? 8
    var line: [String] = []
    for k in 0..<cnt {
        if fr.isColor, let (r, g, b) = fr.rgb(x: x0 + k, y: y0) { line.append("(\(r),\(g),\(b))") }
        else if let v = fr.storedValue(x: x0 + k, y: y0) { line.append(DataSet.formatDS(v)) }
    }
    print(line.joined(separator: " "))
    if let c = f.dataSet.string(.photometricInterpretation) { print("PI:", c, "TS:", f.transferSyntax.name) }

case "j2kinfo":
    for path in args.dropFirst(2) {
        let f = try DICOMFile.read(url: URL(fileURLWithPath: path))
        guard let enc = f.dataSet[.pixelData]?.encapsulated, let first = enc.fragments.first else { continue }
        print("== \((path as NSString).lastPathComponent) (\(enc.fragments.count) fragments)")
        print(JPEG2000Decoder.describe(first))
    }

case "diff":
    // diff <ref> <test> [frame]: mismatch map statistics
    let fa = try PixelDecoder.decodeFrame(try DICOMFile.read(url: URL(fileURLWithPath: args[2])), frame: Int(args[safe: 4] ?? "0") ?? 0)
    let fb = try PixelDecoder.decodeFrame(try DICOMFile.read(url: URL(fileURLWithPath: args[3])), frame: Int(args[safe: 4] ?? "0") ?? 0)
    var rows = [Int](repeating: 0, count: fa.height), cols = [Int](repeating: 0, count: fa.width)
    var shown = 0
    for y in 0..<fa.height { for x in 0..<fa.width {
        let a = fa.storedValue(x: x, y: y) ?? 0, b = fb.storedValue(x: x, y: y) ?? 0
        if a != b { rows[y] += 1; cols[x] += 1; if shown < 12 { print("(\(x),\(y)) ref \(a) got \(b)"); shown += 1 } }
    } }
    print("rows with errors:", rows.enumerated().filter { $0.element > 0 }.map { "\($0.offset):\($0.element)" }.prefix(40).joined(separator: " "))
    print("cols with errors:", cols.enumerated().filter { $0.element > 0 }.map { "\($0.offset):\($0.element)" }.prefix(40).joined(separator: " "))

case "extract":
    // extract <dicom> <out-prefix>: write each encapsulated frame stream to a file
    let f = try DICOMFile.read(url: URL(fileURLWithPath: args[2]))
    if let enc = f.dataSet[.pixelData]?.encapsulated {
        let frames = PixelDecoder.frameFragments(enc, numberOfFrames: max(1, f.dataSet.int(.numberOfFrames) ?? 1), codec: f.transferSyntax.codec)
        for (i, fr) in frames.enumerated() {
            var d = Data(); fr.forEach { d.append($0) }
            try d.write(to: URL(fileURLWithPath: "\(args[3])\(i).j2k"))
        }
        print("\(frames.count) frames")
    }

case "rawcmp":
    // rawcmp <dicom> <frame> <raw16 file> <signed 0/1>: compare decoded frame against a raw little-endian 16-bit dump
    let f = try DICOMFile.read(url: URL(fileURLWithPath: args[2]))
    let fr = try PixelDecoder.decodeFrame(f, frame: Int(args[3]) ?? 0)
    let raw = try Data(contentsOf: URL(fileURLWithPath: args[4]))
    let signed = args[safe: 5] == "1"
    var maxd = 0.0, n = 0
    raw.withUnsafeBytes { r in
        for i in 0..<min(fr.width * fr.height, r.count / 2) {
            let v = r.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)
            let ref = signed ? Double(Int16(bitPattern: v)) : Double(v)
            let mine = fr.storedValue(x: i % fr.width, y: i / fr.width) ?? 0
            if ref != mine { n += 1; maxd = max(maxd, abs(ref - mine)) }
        }
    }
    print("mismatches \(n) max \(maxd)")

case "j2kcmp":
    // j2kcmp <codestream> <raw16 reference> <signed 0/1>
    let cs = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let img = try JPEG2000Decoder.decode(cs)
    let raw = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    var n = 0, maxd = 0, first = ""
    raw.withUnsafeBytes { r in
        let count = min(img.samples.count, r.count / 2)
        for i in 0..<count {
            let v = r.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)
            let a = img.signed ? Int(Int16(bitPattern: v)) : Int(v)
            let b = img.signed ? Int(Int16(bitPattern: img.samples[i])) : Int(img.samples[i])
            if a != b { n += 1; maxd = max(maxd, abs(a - b)); if first.isEmpty { first = "first at \(i % img.width),\(i / img.width / img.components): ref \(a) got \(b)" } }
        }
    }
    print("\((args[2] as NSString).lastPathComponent): \(img.width)x\(img.height)x\(img.components) mismatches \(n) max \(maxd) \(first)")

case "j2kdump":
    // j2kdump <codestream> <reduce>: print decoded values of a reduced-resolution image
    let img = try JPEG2000Decoder.decode(try Data(contentsOf: URL(fileURLWithPath: args[2])), reduce: Int(args[3]) ?? 0)
    print(img.width, img.height, img.samples.prefix(64).map { img.signed ? String(Int16(bitPattern: $0)) : String($0) }.joined(separator: " "))

case "refcheck":
    RefCheck.run(args.dropFirst(2).map { URL(fileURLWithPath: $0) })

case "icon":
    try IconRenderer.renderSet(to: URL(fileURLWithPath: args[2]))

case "net":
    try NetTool.run(Array(args.dropFirst(2)))

default:
    print("unknown command \(args[1])")
    exit(1)
}
