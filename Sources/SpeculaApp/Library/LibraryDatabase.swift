import Foundation
import SQLite3
import DICOMCore

/// Minimal SQLite wrapper.
final class SQLiteDB {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "specula.sqlite")
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw DICOMError.io("Database could not be opened: \(path)")
        }
        _ = try? exec("PRAGMA journal_mode=WAL")
        _ = try? exec("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    func exec(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        try queue.sync {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw DICOMError.io(String(cString: sqlite3_errmsg(db))) }
            defer { sqlite3_finalize(st) }
            bind(st, args)
            let rc = sqlite3_step(st)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DICOMError.io(String(cString: sqlite3_errmsg(db))) }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func query(_ sql: String, _ args: [Any?] = []) -> [[Any?]] {
        queue.sync {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(st) }
            bind(st, args)
            var rows: [[Any?]] = []
            while sqlite3_step(st) == SQLITE_ROW {
                var r: [Any?] = []
                for i in 0..<sqlite3_column_count(st) {
                    switch sqlite3_column_type(st, i) {
                    case SQLITE_INTEGER: r.append(sqlite3_column_int64(st, i))
                    case SQLITE_FLOAT: r.append(sqlite3_column_double(st, i))
                    case SQLITE_TEXT: r.append(String(cString: sqlite3_column_text(st, i)))
                    case SQLITE_BLOB:
                        let n = Int(sqlite3_column_bytes(st, i))
                        r.append(n > 0 ? Data(bytes: sqlite3_column_blob(st, i), count: n) : Data())
                    default: r.append(nil)
                    }
                }
                rows.append(r)
            }
            return rows
        }
    }

    func transaction(_ body: () throws -> Void) rethrows {
        _ = try? exec("BEGIN")
        do { try body(); _ = try? exec("COMMIT") } catch { _ = try? exec("ROLLBACK"); throw error }
    }

    private func bind(_ st: OpaquePointer?, _ args: [Any?]) {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(st, idx)
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, idx, v)
            case let v as Double: sqlite3_bind_double(st, idx, v)
            case let v as String: sqlite3_bind_text(st, idx, v, -1, SQLiteDB.transient)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(st, idx, $0.baseAddress, Int32(v.count), SQLiteDB.transient) }
            default: sqlite3_bind_text(st, idx, "\(a!)", -1, SQLiteDB.transient)
            }
        }
    }
}

struct LibraryStudy: Identifiable, Hashable {
    let id: Int64
    var uid: String
    var patientName: String
    var patientID: String
    var birthDate: String
    var sex: String
    var studyDate: String
    var studyTime: String
    var description: String
    var accession: String
    var modalities: String
    var referring: String
    var institution: String
    var images: Int
    var size: Int64
    var added: Date
    var opened: Date?
    var keywords: String
}

struct LibrarySeries: Identifiable, Hashable {
    let id: Int64
    var number: Int?
    var description: String
    var modality: String
    var images: Int
    var thumbnail: Data?
}

/// Local study archive (SQLite index + optional copy of the files).
final class LibraryDatabase {
    static let shared: LibraryDatabase? = try? LibraryDatabase(folder: URL(fileURLWithPath: Preferences.shared.libraryPath))

    let folder: URL
    let storage: URL
    let db: SQLiteDB

    init(folder: URL) throws {
        self.folder = folder
        storage = folder.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        db = try SQLiteDB(path: folder.appendingPathComponent("Specula Library.sqlite").path)
        try migrate()
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS studies(id INTEGER PRIMARY KEY, uid TEXT UNIQUE, patientname TEXT, patientid TEXT, birthdate TEXT, sex TEXT,
          studydate TEXT, studytime TEXT, description TEXT, accession TEXT, modalities TEXT, referring TEXT, institution TEXT,
          images INTEGER DEFAULT 0, size INTEGER DEFAULT 0, added REAL, opened REAL)
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS series(id INTEGER PRIMARY KEY, studyid INTEGER REFERENCES studies(id) ON DELETE CASCADE, uid TEXT, number INTEGER,
          description TEXT, modality TEXT, images INTEGER DEFAULT 0, thumbnail BLOB, UNIQUE(studyid, uid))
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS images(id INTEGER PRIMARY KEY, seriesid INTEGER REFERENCES series(id) ON DELETE CASCADE, sopuid TEXT, path TEXT,
          copied INTEGER, size INTEGER, instance INTEGER, UNIQUE(seriesid, sopuid))
        """)
        try db.exec("CREATE TABLE IF NOT EXISTS keywords(id INTEGER PRIMARY KEY, text TEXT UNIQUE COLLATE NOCASE)")
        try db.exec("CREATE TABLE IF NOT EXISTS keywordmap(kid INTEGER REFERENCES keywords(id) ON DELETE CASCADE, sid INTEGER REFERENCES studies(id) ON DELETE CASCADE, UNIQUE(kid, sid))")
        try db.exec("CREATE INDEX IF NOT EXISTS images_series ON images(seriesid)")
        try db.exec("CREATE INDEX IF NOT EXISTS series_study ON series(studyid)")
    }

    // MARK: Import

    /// Imports parsed instances. `copy` copies files into the library folder.
    func importInstances(_ instances: [Instance], copy: Bool) {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        db.transaction {
            var studyIDs: [String: Int64] = [:]
            var seriesIDs: [String: Int64] = [:]
            for inst in instances {
                let h = inst.header
                let sid: Int64
                if let s = studyIDs[inst.studyUID] { sid = s } else if let row = db.query("SELECT id FROM studies WHERE uid=?", [inst.studyUID]).first, let s = row[0] as? Int64 {
                    sid = s; studyIDs[inst.studyUID] = s
                } else {
                    sid = (try? db.exec("""
                    INSERT INTO studies(uid, patientname, patientid, birthdate, sex, studydate, studytime, description, accession, modalities, referring, institution, added)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [inst.studyUID, h.string(.patientName) ?? "", h.string(.patientID) ?? "", h.string(.patientBirthDate) ?? "", h.string(.patientSex) ?? "",
                          h.string(.studyDate) ?? "", h.string(.studyTime) ?? "", h.string(.studyDescription) ?? "", h.string(.accessionNumber) ?? "", inst.modality,
                          h.string(.referringPhysicianName) ?? "", h.string(.institutionName) ?? "", now])) ?? 0
                    studyIDs[inst.studyUID] = sid
                }
                let skey = "\(sid)|\(inst.seriesUID)"
                let serid: Int64
                if let s = seriesIDs[skey] { serid = s } else if let row = db.query("SELECT id FROM series WHERE studyid=? AND uid=?", [sid, inst.seriesUID]).first, let s = row[0] as? Int64 {
                    serid = s; seriesIDs[skey] = s
                } else {
                    serid = (try? db.exec("INSERT INTO series(studyid, uid, number, description, modality) VALUES(?,?,?,?,?)",
                                          [sid, inst.seriesUID, h.int(.seriesNumber), h.string(.seriesDescription) ?? h.string(.protocolName) ?? "", inst.modality])) ?? 0
                    seriesIDs[skey] = serid
                }
                if !db.query("SELECT id FROM images WHERE seriesid=? AND sopuid=?", [serid, inst.sopInstanceUID]).isEmpty { continue }
                var path = inst.url.path
                if copy {
                    let dir = storage.appendingPathComponent(safe(inst.studyUID)).appendingPathComponent(safe(inst.seriesUID))
                    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(safe(inst.sopInstanceUID) + ".dcm")
                    if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: inst.url, to: dest) }
                    path = dest.path
                }
                _ = try? db.exec("INSERT INTO images(seriesid, sopuid, path, copied, size, instance) VALUES(?,?,?,?,?,?)",
                                 [serid, inst.sopInstanceUID, path, copy ? 1 : 0, inst.fileSize, inst.instanceNumber])
            }
            for (_, sid) in studyIDs { refreshCounts(study: sid) }
        }
    }

    private func safe(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" }) }

    func refreshCounts(study sid: Int64) {
        _ = try? db.exec("UPDATE series SET images=(SELECT COUNT(*) FROM images WHERE seriesid=series.id) WHERE studyid=?", [sid])
        _ = try? db.exec("""
        UPDATE studies SET images=(SELECT COUNT(*) FROM images JOIN series ON images.seriesid=series.id WHERE series.studyid=studies.id),
          size=(SELECT COALESCE(SUM(images.size),0) FROM images JOIN series ON images.seriesid=series.id WHERE series.studyid=studies.id),
          modalities=(SELECT GROUP_CONCAT(DISTINCT modality) FROM series WHERE studyid=studies.id) WHERE id=?
        """, [sid])
    }

    func setThumbnail(seriesUID: String, png: Data) {
        _ = try? db.exec("UPDATE series SET thumbnail=? WHERE uid=? AND thumbnail IS NULL", [png, seriesUID])
    }

    // MARK: Queries

    func studies(search: String, since: Date?) -> [LibraryStudy] {
        var sql = """
        SELECT s.id, s.uid, s.patientname, s.patientid, s.birthdate, s.sex, s.studydate, s.studytime, s.description, s.accession, s.modalities,
          s.referring, s.institution, s.images, s.size, s.added, s.opened,
          (SELECT GROUP_CONCAT(k.text, ', ') FROM keywordmap m JOIN keywords k ON k.id=m.kid WHERE m.sid=s.id)
        FROM studies s WHERE 1=1
        """
        var args: [Any?] = []
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            sql += " AND (s.patientname LIKE ? OR s.patientid LIKE ? OR s.description LIKE ? OR s.accession LIKE ? OR s.modalities LIKE ? OR s.referring LIKE ? OR EXISTS (SELECT 1 FROM keywordmap m JOIN keywords k ON k.id=m.kid WHERE m.sid=s.id AND k.text LIKE ?))"
            let like = "%\(q.replacingOccurrences(of: " ", with: "%"))%"
            args += Array(repeating: like, count: 7)
        }
        if let since { sql += " AND s.studydate >= ?"; args.append(DICOMDate.dicomDate(since)) }
        sql += " ORDER BY s.studydate DESC, s.studytime DESC"
        return db.query(sql, args).map { r in
            LibraryStudy(id: r[0] as? Int64 ?? 0, uid: r[1] as? String ?? "", patientName: PersonName.display(r[2] as? String), patientID: r[3] as? String ?? "",
                         birthDate: r[4] as? String ?? "", sex: r[5] as? String ?? "", studyDate: r[6] as? String ?? "", studyTime: r[7] as? String ?? "",
                         description: r[8] as? String ?? "", accession: r[9] as? String ?? "", modalities: (r[10] as? String ?? "").replacingOccurrences(of: ",", with: "/"),
                         referring: PersonName.display(r[11] as? String), institution: r[12] as? String ?? "", images: Int(r[13] as? Int64 ?? 0),
                         size: r[14] as? Int64 ?? 0, added: Date(timeIntervalSince1970: r[15] as? Double ?? 0), opened: (r[16] as? Double).map { Date(timeIntervalSince1970: $0) },
                         keywords: r[17] as? String ?? "")
        }
    }

    func series(study: Int64) -> [LibrarySeries] {
        db.query("SELECT id, number, description, modality, images, thumbnail FROM series WHERE studyid=? ORDER BY number", [study]).map { r in
            LibrarySeries(id: r[0] as? Int64 ?? 0, number: (r[1] as? Int64).map(Int.init), description: r[2] as? String ?? "", modality: r[3] as? String ?? "",
                          images: Int(r[4] as? Int64 ?? 0), thumbnail: r[5] as? Data)
        }
    }

    func files(studies: [Int64]) -> [URL] {
        guard !studies.isEmpty else { return [] }
        let list = studies.map(String.init).joined(separator: ",")
        for s in studies { _ = try? db.exec("UPDATE studies SET opened=? WHERE id=?", [Date().timeIntervalSince1970, s]) }
        return db.query("SELECT images.path FROM images JOIN series ON images.seriesid=series.id WHERE series.studyid IN (\(list))").compactMap { ($0[0] as? String).map { URL(fileURLWithPath: $0) } }
    }

    func files(series: Int64) -> [URL] {
        db.query("SELECT path FROM images WHERE seriesid=?", [series]).compactMap { ($0[0] as? String).map { URL(fileURLWithPath: $0) } }
    }

    func delete(studies: [Int64]) {
        let fm = FileManager.default
        for s in studies {
            for r in db.query("SELECT images.path, images.copied FROM images JOIN series ON images.seriesid=series.id WHERE series.studyid=?", [s]) {
                if (r[1] as? Int64) == 1, let p = r[0] as? String { try? fm.removeItem(atPath: p) }
            }
            _ = try? db.exec("DELETE FROM studies WHERE id=?", [s])
        }
    }

    func addKeyword(_ text: String, to studies: [Int64]) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        _ = try? db.exec("INSERT OR IGNORE INTO keywords(text) VALUES(?)", [t])
        guard let kid = db.query("SELECT id FROM keywords WHERE text=?", [t]).first?[0] as? Int64 else { return }
        for s in studies { _ = try? db.exec("INSERT OR IGNORE INTO keywordmap(kid, sid) VALUES(?,?)", [kid, s]) }
    }

    func removeKeywords(from studies: [Int64]) {
        for s in studies { _ = try? db.exec("DELETE FROM keywordmap WHERE sid=?", [s]) }
    }

    var allKeywords: [String] { db.query("SELECT text FROM keywords ORDER BY text").compactMap { $0[0] as? String } }

    var summary: (studies: Int, images: Int, size: Int64) {
        let r = db.query("SELECT COUNT(*), COALESCE(SUM(images),0), COALESCE(SUM(size),0) FROM studies").first ?? []
        return (Int(r[safe: 0].flatMap { $0 as? Int64 } ?? 0), Int(r[safe: 1].flatMap { $0 as? Int64 } ?? 0), r[safe: 2].flatMap { $0 as? Int64 } ?? 0)
    }

    func optimize() -> Bool { (try? db.exec("VACUUM")) != nil }
}
