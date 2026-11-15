import Darwin
import Foundation
import SQLite3

enum CleanupJournalError: LocalizedError {
    case unavailable, corrupt, unresolved, trashAccess
    var errorDescription: String? {
        switch self {
        case .unavailable: return "操作日志无法保存，已停止后续文件操作。请检查可用空间和访问权限后重开轻扫。"
        case .corrupt: return "操作日志无法完整读取，已保留原文件并暂停清理。请勿删除日志文件。"
        case .unresolved: return "上次操作还有待核对的文件，请先在清理记录中重新核对。"
        case .trashAccess: return "无法读取废纸篓。请在系统设置的「完全磁盘访问」中允许轻扫，重开后重新核对。"
        }
    }
}

enum CleanupJournalCheckpoint { case moveIntent, moveApplied, moveRecorded, restoreIntent, restoreApplied, restoreRecorded }
enum CleanupJournalState: String, Codable { case pending, moved, notMoved, restoring, restored }

struct CleanupJournalEntry: Codable, Identifiable {
    let id: UUID
    let batchID: UUID?
    let original: URL
    let sourceStamp: FileStamp
    let trashDirectory: URL
    let bytes: Int64
    let date: Date
    let contentSHA256: String?
    let managedBundleID: String?
    let treeDigest: String?
    var state: CleanupJournalState
    var record: TrashRecord?
    var issue: String?
}

struct CleanupJournalBatch: Codable {
    let id: UUID
    let date: Date
    let title: String
    let requestedCount: Int
    let freeBefore: Int64
    let retryFiles: [CleanupRetryTarget]?
    let retryManaged: [ManagedRetryTarget]?
    let retryOf: UUID?
    var receipt: CleanupReceipt?
}

struct CleanupJournalSnapshot {
    var entries: [CleanupJournalEntry] = []
    var batches: [CleanupJournalBatch] = []
    var issues: [String] { entries.compactMap(\.issue) }
    var needsReconciliation: Bool {
        entries.contains { $0.state == .pending || $0.state == .restoring || $0.state == .moved } || batches.contains { $0.receipt == nil }
    }
    func merge(history: inout [TrashRecord], receipts: inout [CleanupReceipt]) {
        let owned = Set(entries.map(\.id))
        history.removeAll { owned.contains($0.id) }
        history += entries.filter { $0.state == .moved || $0.state == .restoring }.compactMap(\.record)
        history.sort { $0.date > $1.date }
        for batch in batches {
            guard let receipt = batch.receipt else { continue }
            receipts.removeAll { $0.id == receipt.id }; receipts.append(receipt)
        }
        // Successful retries remain resolved even if JSON summaries were not saved before a crash.
        for batch in batches {
            guard let parent = batch.retryOf, let index = receipts.firstIndex(where: { $0.id == parent }) else { continue }
            let moved = Set(entries.filter { $0.batchID == batch.id && $0.record != nil }.map { $0.original.path })
            receipts[index].retryFiles?.removeAll { moved.contains($0.id) }
            receipts[index].retryManaged?.removeAll { moved.contains($0.id) }
        }
        receipts.sort { $0.date > $1.date }
    }
}

struct CleanupJournalContext {
    let journal: CleanupOperationJournal
    let batchID: UUID
}

/// Authoritative file-operation log. Every event commits before the next filesystem action.
/// JSON history and receipts are projections and can be rebuilt from these immutable events.
final class CleanupOperationJournal: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private var failed = false
    private let checkpoint: ((CleanupJournalCheckpoint, UUID) throws -> Void)?
    let url: URL
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return failed }

    init(url: URL, checkpoint: ((CleanupJournalCheckpoint, UUID) throws -> Void)? = nil) throws {
        self.url = url; self.checkpoint = checkpoint
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard LocalFiles.noLinks(url.deletingLastPathComponent()) else { throw CleanupJournalError.unavailable }
        if let stamp = FileStamp.read(url), !stamp.isRegular || stamp.links != 1 { throw CleanupJournalError.corrupt }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil; throw CleanupJournalError.unavailable
        }
        do {
            sqlite3_busy_timeout(db, 3000)
            try sql("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA secure_delete=ON;")
            guard try values("PRAGMA quick_check") == ["ok"] else { throw CleanupJournalError.corrupt }
            let version = try values("PRAGMA user_version").first
            guard version == "0" || version == "1" else { throw CleanupJournalError.corrupt }
            try sql("CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY, kind TEXT NOT NULL, key TEXT NOT NULL, payload TEXT NOT NULL); CREATE INDEX IF NOT EXISTS event_latest ON events(kind,key,seq); PRAGMA user_version=1;")
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { sqlite3_close(db); db = nil; throw error is CleanupJournalError ? error : CleanupJournalError.corrupt }
    }
    deinit { if let db { sqlite3_close_v2(db) } }

    func hit(_ point: CleanupJournalCheckpoint, id: UUID) throws { try checkpoint?(point, id) }
    private func sql(_ text: String) throws {
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw CleanupJournalError.unavailable }
    }
    private func values(_ query: String, bindings: [String] = []) throws -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw CleanupJournalError.corrupt }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in bindings.enumerated() { _ = value.withCString { sqlite3_bind_text(stmt, Int32(i+1), $0, -1, Self.transient) } }
        var output: [String] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return output }
            guard status == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else { throw CleanupJournalError.corrupt }
            output.append(String(cString: raw))
        }
    }
    private func append<T: Encodable>(_ value: T, kind: String, key: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { throw CleanupJournalError.unavailable }
        do {
            let payload = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO events(kind,key,payload) VALUES(?,?,?)", -1, &stmt, nil) == SQLITE_OK, let stmt else { throw CleanupJournalError.unavailable }
            defer { sqlite3_finalize(stmt) }
            for (i, text) in [kind, key.uuidString, payload].enumerated() { _ = text.withCString { sqlite3_bind_text(stmt, Int32(i+1), $0, -1, Self.transient) } }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw CleanupJournalError.unavailable }
        } catch { failed = true; throw error }
    }
    private func latest<T:Decodable>(_ kind:String,key:UUID,as:T.Type) throws -> T? {
        lock.lock();defer{lock.unlock()}
        guard let payload=try values("SELECT payload FROM events WHERE kind=? AND key=? ORDER BY seq DESC LIMIT 1",bindings:[kind,key.uuidString]).first else{return nil}
        return try JSONDecoder().decode(T.self,from:Data(payload.utf8))
    }
    func snapshot() throws -> CleanupJournalSnapshot {
        lock.lock(); defer { lock.unlock() }
        do {
            func read<T: Decodable>(_ kind: String, _: T.Type) throws -> [T] {
                try values("SELECT payload FROM events WHERE kind=? AND seq IN (SELECT MAX(seq) FROM events WHERE kind=? GROUP BY key) ORDER BY seq", bindings: [kind, kind]).map {
                    guard let data = $0.data(using: .utf8) else { throw CleanupJournalError.corrupt }
                    return try JSONDecoder().decode(T.self, from: data)
                }
            }
            return try CleanupJournalSnapshot(entries: read("item", CleanupJournalEntry.self), batches: read("batch", CleanupJournalBatch.self))
        } catch { failed = true; throw CleanupJournalError.corrupt }
    }
    func begin(_ batch: CleanupJournalBatch) throws { try append(batch, kind: "batch", key: batch.id) }
    func finish(_ receipt: CleanupReceipt) throws {
        guard var batch = try latest("batch",key:receipt.id,as:CleanupJournalBatch.self) else { throw CleanupJournalError.corrupt }
        batch.receipt = receipt; try append(batch, kind: "batch", key: batch.id)
    }
    func prepareMove(original: URL, stamp: FileStamp, bytes: Int64, context: CleanupJournalContext,
                     checksum: String?, bundleID: String? = nil, treeDigest: String? = nil) throws -> CleanupJournalEntry {
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: original, create: true)
        guard ManagedLocations.inTrash(trash.appendingPathComponent("probe"), home: FileManager.default.homeDirectoryForCurrentUser), LocalFiles.noLinks(trash) else { throw CleanupJournalError.unavailable }
        // A move is not started unless its ambiguous crash window can later be reconciled.
        try Self.requireReadableTrash(trash)
        let entry = CleanupJournalEntry(id: UUID(), batchID: context.batchID, original: original, sourceStamp: stamp, trashDirectory: trash, bytes: bytes, date: Date(), contentSHA256: checksum, managedBundleID: bundleID, treeDigest: treeDigest, state: .pending)
        try append(entry, kind: "item", key: entry.id); try hit(.moveIntent, id: entry.id); return entry
    }
    func didMove(_ intent: CleanupJournalEntry, record: TrashRecord) throws {
        var entry = intent; entry.state = .moved; entry.record = record
        try append(entry, kind: "item", key: entry.id); try hit(.moveRecorded, id: entry.id)
    }
    func didNotMove(_ intent:CleanupJournalEntry) throws {
        var entry=intent;entry.state = .notMoved;entry.issue=nil
        try append(entry,kind:"item",key:entry.id)
    }
    func prepareRestore(_ record: TrashRecord) throws -> CleanupJournalEntry {
        guard let stamp = record.stamp else { throw SweepError.changed }
        var entry = try latest("item",key:record.id,as:CleanupJournalEntry.self) ?? CleanupJournalEntry(id: record.id, batchID: record.batchID, original: record.original, sourceStamp: stamp, trashDirectory: record.trashed.deletingLastPathComponent(), bytes: record.bytes, date: record.date, contentSHA256: record.contentSHA256, managedBundleID: record.managedBundleID, treeDigest: record.treeDigest, state: .moved, record: record)
        entry.state = .restoring; entry.issue = nil
        try append(entry, kind: "item", key: entry.id); try hit(.restoreIntent, id: entry.id); return entry
    }
    func didRestore(_ intent: CleanupJournalEntry) throws {
        var entry = intent; entry.state = .restored; entry.issue = nil
        try append(entry, kind: "item", key: entry.id); try hit(.restoreRecorded, id: entry.id)
    }

    /// Read-only filesystem reconciliation. Never moves files and never matches by filename alone.
    func reconcile(policy: SafetyPolicy) throws -> CleanupJournalSnapshot {
        var state = try snapshot()
        var trashCache: [URL: [String: [(URL,FileStamp)]]] = [:]
        for var entry in state.entries where entry.state == .pending || entry.state == .restoring || entry.state == .moved {
            entry.issue = nil
            do {
                let permitted = entry.managedBundleID.map { ManagedLocations.permits(entry.original, id: $0, home: policy.home) } ?? policy.permits(entry.original)
                guard permitted else { throw CleanupJournalError.unresolved }
                if entry.state == .moved {
                    // Finder restores and a power-loss rollback may already have returned the file.
                    // An emptied Trash or a disconnected disk never causes a new file operation.
                    guard let record=entry.record,FileStamp.read(record.trashed)==nil,LocalFiles.noLinks(entry.original),let actual=FileStamp.read(entry.original),try matches(entry.original,stamp:actual,expected:record.stamp ?? entry.sourceStamp,entry:entry) else{continue}
                    entry.state = .restored
                } else if entry.state == .restoring {
                    guard LocalFiles.noLinks(entry.original.deletingLastPathComponent()) else{throw CleanupJournalError.unresolved}
                    guard let record = entry.record, let expected = record.stamp else { throw CleanupJournalError.corrupt }
                    if let source = FileStamp.read(record.trashed) {
                        guard try matches(record.trashed, stamp: source, expected: expected, entry: entry) else { throw SweepError.changed }
                        entry.state = .moved // Retry remains an explicit user action, including occupied original paths.
                    } else if let restored = FileStamp.read(entry.original), try matches(entry.original, stamp: restored, expected: expected, entry: entry) {
                        entry.state = .restored
                    } else { throw CleanupJournalError.unresolved }
                } else if LocalFiles.noLinks(entry.original),FileStamp.read(entry.original) == entry.sourceStamp {
                    entry.state = .notMoved
                } else {
                    guard ManagedLocations.inTrash(entry.trashDirectory.appendingPathComponent("probe"), home: policy.home), LocalFiles.noLinks(entry.trashDirectory) else { throw CleanupJournalError.unresolved }
                    try Self.requireReadableTrash(entry.trashDirectory)
                    let candidates: [(URL,FileStamp)]
                    let identity="\(entry.sourceStamp.device):\(entry.sourceStamp.inode)"
                    if let cached = trashCache[entry.trashDirectory] { candidates = cached[identity] ?? [] }
                    else {
                        // Only direct Trash entries; no user folders or unrelated file contents are scanned.
                        var readError:Error?
                        let iterator = FileManager.default.enumerator(at: entry.trashDirectory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants],errorHandler:{_,error in readError=error;return false})
                        guard let iterator else { throw CleanupJournalError.unresolved }
                        var urls: [String:[(URL,FileStamp)]] = [:];var visited=0; let deadline = Date().addingTimeInterval(5)
                        while let candidate = iterator.nextObject() as? URL {
                            guard visited < 100_000, Date() < deadline else { throw ToolFailure.incomplete };visited += 1
                            if let stamp=FileStamp.read(candidate){urls["\(stamp.device):\(stamp.inode)",default:[]].append((candidate,stamp))}
                        }
                        if readError != nil { throw CleanupJournalError.trashAccess }
                        candidates = urls[identity] ?? []; trashCache[entry.trashDirectory] = urls
                    }
                    var found: [(URL, FileStamp)] = []
                    for (url,_) in candidates {
                        guard let stamp = FileStamp.read(url), stamp.device == entry.sourceStamp.device, stamp.inode == entry.sourceStamp.inode else { continue }
                        if try matches(url, stamp: stamp, expected: entry.sourceStamp, entry: entry) { found.append((url, stamp)) }
                    }
                    guard found.count == 1 else { throw CleanupJournalError.unresolved }
                    var record = TrashRecord(id: entry.id, original: entry.original, trashed: found[0].0, bytes: entry.bytes, date: entry.date, stamp: found[0].1)
                    record.batchID = entry.batchID; record.contentSHA256 = entry.contentSHA256; record.managedBundleID = entry.managedBundleID; record.treeDigest = entry.treeDigest
                    entry.record = record; entry.state = .moved
                }
            } catch { entry.issue = entry.original.lastPathComponent + "：" + error.localizedDescription }
            try append(entry, kind: "item", key: entry.id)
        }
        state = try snapshot()
        for batch in state.batches where batch.receipt == nil {
            let entries = state.entries.filter { $0.batchID == batch.id }
            let moved = entries.compactMap(\.record)
            let completed = Set(moved.map { $0.original.path })
            var receipt = CleanupReceipt(id: batch.id, date: batch.date, title: batch.title, requestedCount: batch.requestedCount, movedCount: moved.count, movedBytes: moved.map(\.bytes).reduce(0,boundedBytes), freeBefore: batch.freeBefore, freeAfter: batch.freeBefore, errors: ["上次操作意外中断；已核对的文件可在此恢复，未处理项需重新确认。"] + entries.compactMap(\.issue), cancelled: true)
            receipt.interrupted = true; receipt.retryOf = batch.retryOf
            receipt.retryFiles = batch.retryFiles?.filter { !completed.contains($0.id) }
            receipt.retryManaged = batch.retryManaged?.filter { !completed.contains($0.id) }
            try finish(receipt)
        }
        // Rebuild interrupted summaries again when a disconnected disk or permission is later resolved.
        state = try snapshot()
        for batch in state.batches where batch.receipt?.interrupted == true {
            let entries = state.entries.filter { $0.batchID == batch.id }, records = state.entries.filter { $0.batchID == batch.id }.compactMap(\.record)
            let completed = Set(records.map { $0.original.path })
            var receipt = batch.receipt!
            receipt = CleanupReceipt(id: receipt.id, date: receipt.date, title: receipt.title, requestedCount: receipt.requestedCount, movedCount: records.count, movedBytes: records.map(\.bytes).reduce(0,boundedBytes), freeBefore: receipt.freeBefore, freeAfter: receipt.freeAfter, errors: ["上次操作意外中断；已核对的文件可在此恢复，未处理项需重新确认。"] + entries.compactMap(\.issue), cancelled: true, retryFiles: batch.retryFiles?.filter { !completed.contains($0.id) }, retryManaged: batch.retryManaged?.filter { !completed.contains($0.id) }, retryOf: batch.retryOf, interrupted: true)
            try finish(receipt)
        }
        return try snapshot()
    }
    private func matches(_ url: URL, stamp: FileStamp, expected: FileStamp, entry: CleanupJournalEntry) throws -> Bool {
        guard LocalFiles.noLinks(url), !stamp.isDataless else { return false }
        if expected.isDirectory {
            guard stamp.isDirectory, stamp.device == expected.device, stamp.inode == expected.inode, let proof = entry.treeDigest else { return false }
            return try FileTree.read(url).digest == proof
        }
        guard stamp.isRegular, stamp.sameContentIdentity(expected), let proof = entry.contentSHA256 else { return false }
        return try LocalFiles.digest(url, expected: stamp) == proof
    }
    private static func requireReadableTrash(_ url:URL) throws {
        guard let directory=opendir(url.path) else {
            if errno == EPERM || errno == EACCES {throw CleanupJournalError.trashAccess}
            throw ToolFailure.unreadable(url.path)
        }
        defer{closedir(directory)}
        errno=0;_ = readdir(directory)
        if errno == EPERM || errno == EACCES {throw CleanupJournalError.trashAccess}
        guard errno == 0 else{throw ToolFailure.unreadable(url.path)}
    }
}
