import Foundation
import SQLite3
import Darwin

/// Complete cleanup snapshots. Repeated roots and assessments are stored once;
/// rows are decoded in pages rather than loading a single enormous JSON document.
final class CleanupCatalog {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL, create: Bool = false) throws {
        if let stamp = FileStamp.read(url), !stamp.isRegular || stamp.isSymlink || stamp.links != 1 { throw StorageIndexError.invalid }
        let flags = SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY)
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; db = nil; throw StorageIndexError.unavailable }
        sqlite3_busy_timeout(db, 3000)
        do {
        if create {
            try execute("CREATE TABLE roots(id INTEGER PRIMARY KEY,url TEXT); CREATE TABLE rules(id INTEGER PRIMARY KEY,value TEXT); CREATE TABLE files(path TEXT PRIMARY KEY,root INTEGER,rule INTEGER,stamp TEXT); CREATE TABLE metadata(value TEXT); PRAGMA user_version=1;")
        }
        guard try scalar("PRAGMA user_version") == "1" else { throw StorageIndexError.invalid }
        } catch { if let db { sqlite3_close(db) }; db = nil; throw error }
    }
    deinit { if let db { sqlite3_close_v2(db) } }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StorageIndexError.unavailable }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw StorageIndexError.invalid }
        return stmt
    }
    private func scalar(_ sql: String) throws -> String {
        let stmt = try statement(sql); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else { throw StorageIndexError.invalid }
        return String(cString: raw)
    }
    private func insert(_ stmt: OpaquePointer, _ values: [String]) throws {
        sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
        for (i,value) in values.enumerated() { _ = value.withCString { sqlite3_bind_text(stmt, Int32(i+1), $0, -1, Self.transient) } }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StorageIndexError.unavailable }
    }
    static func save(_ archive: ScanArchive, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard SafetyPolicy(home: url.deletingLastPathComponent()).hasNoSymlinkComponents(url.deletingLastPathComponent()) else { throw StorageIndexError.invalid }
        if let stamp = FileStamp.read(url), !stamp.isRegular || stamp.isSymlink || stamp.links != 1 { throw StorageIndexError.invalid }
        let temporary = url.deletingLastPathComponent().appendingPathComponent("catalog-" + UUID().uuidString + ".sqlite")
        defer { try? fm.removeItem(at: temporary) }
        do {
            let catalog = try CleanupCatalog(url: temporary, create: true)
            let roots = try catalog.statement("INSERT INTO roots VALUES(?,?)"), rules = try catalog.statement("INSERT INTO rules VALUES(?,?)"), files = try catalog.statement("INSERT INTO files VALUES(?,?,?,?)"), meta = try catalog.statement("INSERT INTO metadata VALUES(?)")
            defer { sqlite3_finalize(roots); sqlite3_finalize(rules); sqlite3_finalize(files); sqlite3_finalize(meta) }
            try catalog.execute("BEGIN IMMEDIATE")
            var rootIDs: [String:Int] = [:], ruleIDs: [String:Int] = [:]
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            for item in archive.result.items {
                let root: Int
                if let existing = rootIDs[item.root.path] { root = existing }
                else { root = rootIDs.count + 1; rootIDs[item.root.path] = root; try catalog.insert(roots,[String(root),item.root.path]) }
                let assessment = String(decoding: try encoder.encode(item.assessment), as: UTF8.self)
                let rule: Int
                if let existing = ruleIDs[assessment] { rule = existing }
                else { rule = ruleIDs.count + 1; ruleIDs[assessment] = rule; try catalog.insert(rules,[String(rule),assessment]) }
                try catalog.insert(files,[item.url.path,String(root),String(rule),String(decoding: try encoder.encode(item.stamp), as: UTF8.self)])
            }
            var result = archive.result; result.items = []
            let summary = ScanArchive(schemaVersion: archive.schemaVersion, scannedAt: archive.scannedAt, label: archive.label, result: result, configuration: archive.configuration)
            try catalog.insert(meta,[String(decoding: try encoder.encode(summary),as: UTF8.self)])
            try catalog.execute("COMMIT; PRAGMA optimize;")
        }
        guard rename(temporary.path,url.path) == 0 else { throw StorageIndexError.unavailable }
    }
    func page(offset: Int, limit: Int = 100) throws -> [ScanItem] {
        let stmt = try statement("SELECT f.path,r.url,a.value,f.stamp FROM files f JOIN roots r ON r.id=f.root JOIN rules a ON a.id=f.rule ORDER BY f.path LIMIT \(min(1000,max(1,limit))) OFFSET \(max(0,offset))")
        defer { sqlite3_finalize(stmt) }
        var output: [ScanItem] = []; let decoder = JSONDecoder()
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw StorageIndexError.invalid }
            let values = (0..<4).compactMap { column -> String? in guard let raw = sqlite3_column_text(stmt,Int32(column)) else { return nil }; return String(cString: raw) }
            guard values.count == 4 else { throw StorageIndexError.invalid }
            output.append(ScanItem(url: URL(fileURLWithPath: values[0]), root: URL(fileURLWithPath: values[1]), stamp: try decoder.decode(FileStamp.self, from: Data(values[3].utf8)), assessment: try decoder.decode(FileAssessment.self, from: Data(values[2].utf8))))
        }
        return output
    }
    func archive() throws -> ScanArchive {
        let raw = try scalar("SELECT value FROM metadata LIMIT 1")
        let saved = try JSONDecoder().decode(ScanArchive.self, from: Data(raw.utf8))
        var result = saved.result
        while true {
            let next = try page(offset: result.items.count, limit: 1000)
            if next.isEmpty { break }
            result.items += next
        }
        return ScanArchive(schemaVersion: saved.schemaVersion, scannedAt: saved.scannedAt, label: saved.label, result: result, configuration: saved.configuration)
    }
}
