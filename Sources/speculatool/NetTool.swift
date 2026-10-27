import Foundation
import DICOMCore
import DICOMNet

/// Command-line front end for DICOMNet, used for interoperability tests.
enum NetTool {
    static func node(_ spec: String) -> DICOMNode {
        let p = spec.split(separator: ":").map(String.init)
        return DICOMNode(description: spec, host: p[0], port: Int(p[1]) ?? 104, aeTitle: p.count > 2 ? p[2] : "ANY-SCP")
    }

    static func keys(_ list: ArraySlice<String>) -> DataSet {
        let ds = DataSet()
        for kv in list {
            let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
            guard let tag = Tag(string: parts[0]) else { continue }
            let vr = DataDictionary.entry(for: tag)?.vr ?? .LO
            ds.set(tag, vr, string: parts.count > 1 ? parts[1] : "")
        }
        return ds
    }

    static func run(_ a: [String]) throws {
        let calling = ProcessInfo.processInfo.environment["SPECULA_AE"] ?? "SPECULA"
        switch a.first {
        case "echo":
            let t = try DICOMClient(node: node(a[1]), callingAE: calling).echo()
            print(String(format: "C-ECHO ok (%.1f ms)", t * 1000))
        case "find":
            let level = QueryLevel(rawValue: a[2].uppercased()) ?? .study
            let n = try DICOMClient(node: node(a[1]), callingAE: calling).find(level: level, keys: keys(a.dropFirst(3))) { ds in
                print("---")
                for e in ds.sortedElements { print("  \(e.tag) \(DataDictionary.name(for: e.tag)): \(ds.displayValue(e))") }
            }
            print("\(n) matches")
        case "move":
            // net move host:port:AET DEST level key=value...
            let level = QueryLevel(rawValue: a[3].uppercased()) ?? .study
            let p = try DICOMClient(node: node(a[1]), callingAE: calling).move(level: level, keys: keys(a.dropFirst(4)), destination: a[2]) { p in
                print("  remaining \(p.remaining) completed \(p.completed) failed \(p.failed) warning \(p.warnings) status \(String(format: "%04X", p.status))")
            }
            print("C-MOVE done: \(p.completed) completed, \(p.failed) failed")
        case "get":
            // net get host:port:AET outdir level key=value...
            let out = URL(fileURLWithPath: a[2])
            let level = QueryLevel(rawValue: a[3].uppercased()) ?? .study
            var bytes = 0
            let p = try DICOMClient(node: node(a[1]), callingAE: calling).get(level: level, keys: keys(a.dropFirst(4)), store: { data, cmd, ts, ae in
                let o = try ReceivedObjectWriter.write(data, sopClass: cmd.affectedSOPClass ?? "", sopInstance: cmd.affectedSOPInstance ?? "", transferSyntax: ts, callingAE: ae, under: out)
                bytes += o.byteCount
                print("  stored \(o.url.lastPathComponent) [\(ts.name)]")
            }) { p in
                print("  remaining \(p.remaining) completed \(p.completed) failed \(p.failed) status \(String(format: "%04X", p.status))")
            }
            print("C-GET done: \(p.completed) completed, \(p.failed) failed, \(bytes) bytes")
        case "store":
            var files: [URL] = []
            for path in a.dropFirst(2) {
                let u = URL(fileURLWithPath: path)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil)
                    while let f = e?.nextObject() as? URL { if DICOMFile.looksLikeDICOM(url: f) { files.append(f) } }
                } else { files.append(u) }
            }
            let r = try DICOMClient(node: node(a[1]), callingAE: calling).store(files: files) { i, n in print("  sent \(i)/\(n)") }
            print("C-STORE done: \(r.sent) sent, \(r.failed) failed, \(r.warnings) warnings")
            r.errors.forEach { print("  error: \($0)") }
        case "listen":
            // net listen AET port outdir [seconds]
            var cfg = StorageSCP.Configuration(aeTitle: a[1], port: Int(a[2])!, storageRoot: URL(fileURLWithPath: a[3]))
            cfg.acceptAllContexts = true
            cfg.loopbackOnly = true
            let scp = StorageSCP(configuration: cfg)
            scp.onReceive = { o in print("  received \(o.sopInstanceUID) from \(o.callingAE) (\(o.byteCount) bytes)") }
            scp.onLog = { print("  [scp] \($0)") }
            try scp.start()
            print("listening as \(a[1]) on \(a[2])")
            let secs = a.count > 4 ? Double(a[4])! : 3600
            Thread.sleep(forTimeInterval: secs)
            scp.stop()
        default:
            print("usage: net <echo|find|move|get|store|listen> ...")
        }
    }
}
