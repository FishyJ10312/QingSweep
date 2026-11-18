import Foundation
import SQLite3
import Darwin

struct IndexedStorageItem: Identifiable {
    var id: String { url.path }
    let url: URL
    let parent: String
    let root: URL
    let title: String
    let bytes: Int64
    let isDirectory: Bool
    let fileCount: Int
    let ownerID: String
    let ownerTitle: String
    let component: StorageComponent
    let state: Int // 0 unread, 1 read, 2 partially read
    var partial: Bool { state != 1 }
}
struct StoragePage {
    var items: [IndexedStorageItem] = []
    var total = 0
    var offset = 0
    var hasMore: Bool { offset + items.count < total }
}
struct StorageIndexInfo: Codable {
    let scannedAt: Date
    let roots: [StorageRoot]
    let visited: Int
    let limited: Bool
    let cancelled: Bool
    let unreadableCount: Int
    let elapsed: TimeInterval
    var partial: Bool { limited || cancelled || unreadableCount > 0 }
}
enum StorageScanScope: String {
    case savedRoots, selectedFolders, allLocations
}
enum StorageIndexError: LocalizedError {
    case invalid, unavailable, failure(String)
    var errorDescription: String? { switch self { case .invalid: return "空间索引需要重建"; case .unavailable: return "空间索引暂时不可用"; case .failure(let reason):
        if reason.localizedCaseInsensitiveContains("full") { return "磁盘空间不足，无法保存空间索引" }
        if reason.localizedCaseInsensitiveContains("locked") { return "空间索引正在使用，请稍后重试" }
        return "空间索引暂时无法更新，请重新分析" } }
}

/// A bounded-memory, metadata-only index. The writer and UI use separate
/// connections; a completed staging database replaces the last snapshot atomically.
final class StorageIndex {
    private var database: OpaquePointer?
    private var insertStatement: OpaquePointer?
    let url: URL
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let columns = "path,parent,root,title,total_bytes,is_dir,file_count,owner_id,owner_title,component,state"
    init(url: URL, create: Bool = false) throws {
        self.url = url
        if let stamp = FileStamp.read(url), !stamp.isRegular || stamp.isSymlink || stamp.links != 1 { throw StorageIndexError.invalid }
        if create { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else { if let database { sqlite3_close(database) }; database = nil; throw StorageIndexError.unavailable }
        sqlite3_busy_timeout(database, 3000)
        do {
            guard sqlite3_create_function_v2(database, "sweep_fold", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
                guard let context, let values, let raw = sqlite3_value_text(values[0]) else { return }
                let value = String(cString: raw).folding(options: [.caseInsensitive,.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                value.withCString { sqlite3_result_text(context, $0, -1, StorageIndex.transient) }
            }, nil, nil, nil) == SQLITE_OK else { throw StorageIndexError.invalid }
            let version = try rows("PRAGMA user_version").first?.first ?? "0"
            if version == "0" && create { try schema() }
            else if version == "1" { try migrate() }
            else if version != "2" { throw StorageIndexError.invalid }
            try execute("PRAGMA cache_size=-8192; PRAGMA temp_store=FILE; PRAGMA case_sensitive_like=ON;")
        } catch { sqlite3_close(database); database = nil; throw StorageIndexError.invalid }
    }
    deinit { sqlite3_finalize(insertStatement); if let database { sqlite3_close_v2(database) } }
    private func schema() throws {
        try execute("""
        CREATE TABLE nodes(path TEXT PRIMARY KEY,parent TEXT NOT NULL,root TEXT NOT NULL,title TEXT NOT NULL,
          own_bytes INTEGER NOT NULL,total_bytes INTEGER NOT NULL,file_count INTEGER NOT NULL,is_dir INTEGER NOT NULL,
          owner_id TEXT NOT NULL,owner_title TEXT NOT NULL,component TEXT NOT NULL,state INTEGER NOT NULL,
          depth INTEGER NOT NULL,search_key TEXT NOT NULL);
        CREATE INDEX node_parent ON nodes(parent);
        CREATE INDEX node_owner ON nodes(owner_id);
        CREATE INDEX node_directory_depth ON nodes(depth) WHERE is_dir=1;
        CREATE TABLE issues(path TEXT,root TEXT,kind TEXT,detail TEXT,PRIMARY KEY(path,kind));
        CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);
        PRAGMA user_version=2;
        """)
    }
    private func migrate() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            // Search the canonical path directly; do not store a second full copy of every path.
            try execute("UPDATE nodes SET search_key=sweep_fold(title || ' ' || owner_title); DROP INDEX IF EXISTS node_path_nocase; CREATE INDEX IF NOT EXISTS node_directory_depth ON nodes(depth) WHERE is_dir=1; PRAGMA user_version=2; COMMIT;")
        } catch { try? execute("ROLLBACK"); throw error }
        try execute("VACUUM; PRAGMA optimize;")
    }
    func compact() throws { try execute("VACUUM; PRAGMA optimize;") }
    func checkpoint() throws -> StorageCheckpoint? {
        guard let raw = try rows("SELECT value FROM metadata WHERE key='checkpoint'").first?.first else { return nil }
        return try? JSONDecoder().decode(StorageCheckpoint.self, from: Data(raw.utf8))
    }
    func saveCheckpoint(_ checkpoint: StorageCheckpoint) throws {
        try write("INSERT OR REPLACE INTO metadata VALUES('checkpoint',?)", [String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self)])
    }
    /// Queue only changed subtrees; nil means the OS journal cannot prove completeness.
    @discardableResult func prepareRefresh(changes: [URL]?, checkpoint: StorageCheckpoint) throws -> Int {
        let previous = try info()
        guard try pendingRoots().isEmpty else { return try pendingRoots().count }
        let jobs = changes.map { refreshJobs(for: $0, in: previous.roots) } ?? previous.roots
        try savePlan(ContinuationPlan(jobs: jobs))
        try saveCheckpoint(checkpoint)
        if jobs.isEmpty { try setInfo(StorageIndexInfo(scannedAt: Date(), roots: previous.roots, visited: previous.visited, limited: false, cancelled: false, unreadableCount: previous.unreadableCount, elapsed: 0)) }
        return jobs.count
    }
    func queueCleanupRefresh(_ roots: [URL]) throws {
        var plan = try continuationPlan()
        let additional = refreshJobs(for: roots, in: try info().roots)
        for job in additional where !plan.jobs.contains(where: { Self.contains(job.url, $0.url) }) {
            plan.jobs.removeAll { Self.contains($0.url, job.url) }
            plan.jobs.append(job)
        }
        try savePlan(plan)
    }
    private func refreshJobs(for changes: [URL], in scopes: [StorageRoot]) -> [StorageRoot] {
        var jobs: [StorageRoot] = []
        for change in changes {
            for scope in scopes where Self.contains(change, scope.url) || Self.contains(scope.url, change) {
                var target = Self.contains(change, scope.url) ? change : scope.url
                while FileStamp.read(target)?.isDirectory != true && target.path != scope.url.path { target.deleteLastPathComponent() }
                if jobs.contains(where: { Self.contains(target, $0.url) }) { continue }
                jobs.removeAll { Self.contains($0.url, target) }
                jobs.append(StorageRoot(url: target, title: target.path == scope.url.path ? scope.title : target.lastPathComponent, kind: scope.kind))
            }
        }
        return jobs
    }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StorageIndexError.failure(String(cString: sqlite3_errmsg(database))) }
    }
    private func statement(_ sql: String, _ bindings: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw StorageIndexError.invalid }
        for (index, value) in bindings.enumerated() { _ = value.withCString { sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, Self.transient) } }
        return stmt
    }
    private func write(_ sql: String, _ bindings: [String] = []) throws {
        let stmt = try statement(sql, bindings); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StorageIndexError.failure(String(cString: sqlite3_errmsg(database))) }
    }
    func rows(_ sql: String, _ bindings: [String] = []) throws -> [[String]] {
        let stmt = try statement(sql, bindings); defer { sqlite3_finalize(stmt) }
        var output: [[String]] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return output }
            guard code == SQLITE_ROW else { throw StorageIndexError.invalid }
            output.append((0..<sqlite3_column_count(stmt)).map { column in sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? "" })
        }
    }
    private static func canonicalPath(_ url: URL) -> String {
        var pieces: [String] = []
        for part in url.pathComponents {
            if part == "/" || part == "." { continue }
            if part == ".." { if !pieces.isEmpty { pieces.removeLast() } } else { pieces.append(part) }
        }
        return "/" + pieces.joined(separator: "/")
    }
    private static func contains(_ url: URL, _ parent: URL) -> Bool {
        let path = canonicalPath(url), root = canonicalPath(parent)
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    private static func noLinks(_ url: URL) -> Bool {
        var cursor = URL(fileURLWithPath: canonicalPath(url))
        while cursor.path != "/" {
            guard let stamp = FileStamp.read(cursor), !stamp.isSymlink else { return false }
            cursor.deleteLastPathComponent()
        }
        return true
    }
    private static func folded(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    private static func escaped(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") }
    private func insert(_ record: StorageRecord, owner: StorageOwner, state: Int = 1) throws {
        if insertStatement == nil {
            insertStatement = try statement("INSERT OR REPLACE INTO nodes VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [])
        }
        let parent = record.isRoot ? "" : record.url.deletingLastPathComponent().path
        let values = [record.url.path,parent,record.root.url.path,record.title,String(record.allocated),String(record.allocated),record.isDirectory ? "0" : "1",record.isDirectory ? "1" : "0",owner.id,owner.title,StorageOwnerResolver.component(for: record.root, url: record.url).rawValue,String(state),String(record.url.pathComponents.count),Self.folded(record.title + " " + owner.title)]
        let stmt = insertStatement!
        sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
        for (index, value) in values.enumerated() { _ = value.withCString { sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, Self.transient) } }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StorageIndexError.failure(String(cString: sqlite3_errmsg(database))) }
    }
    private func addIssue(_ issue: StorageAccessIssue, root: StorageRoot, owner: StorageOwner) throws {
        try write("INSERT OR REPLACE INTO issues VALUES(?,?,?,?)", [issue.url.path,issue.root.path,issue.kind.rawValue,issue.detail])
        let exists = !(try rows("SELECT path FROM nodes WHERE path=?", [issue.url.path])).isEmpty
        if !exists {
            let record = StorageRecord(url: issue.url, root: root, title: issue.url.path == root.url.path ? root.title : issue.url.lastPathComponent, stamp: nil, allocated: 0, isRoot: issue.url.path == root.url.path)
            try insert(record, owner: owner, state: 0)
            try write("UPDATE nodes SET is_dir=1 WHERE path=?", [issue.url.path])
        }
        try write("UPDATE nodes SET state=CASE WHEN ?='incomplete' AND (state>0 OR EXISTS(SELECT 1 FROM nodes c WHERE c.parent=nodes.path)) THEN 2 ELSE 0 END WHERE path=?", [issue.kind.rawValue,issue.url.path])
    }
    private func recalculate() throws {
        let maxDepth = Int(try rows("SELECT COALESCE(MAX(depth),0) FROM nodes").first?.first ?? "0") ?? 0
        if maxDepth > 0 {
            for depth in stride(from: maxDepth, through: 1, by: -1) {
                try execute("""
                UPDATE nodes SET total_bytes=own_bytes+COALESCE((SELECT SUM(c.total_bytes) FROM nodes c WHERE c.parent=nodes.path),0),
                file_count=COALESCE((SELECT SUM(c.file_count) FROM nodes c WHERE c.parent=nodes.path),0),
                state=CASE WHEN state=0 THEN 0 WHEN EXISTS(SELECT 1 FROM issues i WHERE i.path=nodes.path AND i.kind='incomplete') OR EXISTS(SELECT 1 FROM nodes c WHERE c.parent=nodes.path AND c.state<>1) THEN 2 ELSE 1 END
                WHERE is_dir=1 AND depth=\(depth);
                """)
            }
        }
    }
    // Separate scan batches have separate inode sets. Reconcile real hard links
    // when merging snapshots, without reading file contents or changing files.
    private func deduplicateHardlinks() throws {
        let stmt = try statement("SELECT path,own_bytes FROM nodes WHERE is_dir=0 AND own_bytes>0", [])
        defer { sqlite3_finalize(stmt) }
        var seen = Set<String>(), duplicates: [String] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else { throw StorageIndexError.invalid }
            let path = String(cString: raw), bytes = sqlite3_column_int64(stmt, 1)
            guard let stamp = FileStamp.read(URL(fileURLWithPath: path)), stamp.isRegular, stamp.links > 1, stamp.allocated == bytes else { continue }
            if !seen.insert("\(stamp.device):\(stamp.inode)").inserted { duplicates.append(path) }
        }
        for path in duplicates { try write("UPDATE nodes SET own_bytes=0 WHERE path=?", [path]) }
    }
    func validateIntegrity() throws { guard try rows("PRAGMA quick_check(1)").first?.first == "ok" else { throw StorageIndexError.invalid } }
    func info() throws -> StorageIndexInfo {
        guard let raw = try rows("SELECT value FROM metadata WHERE key='scan'").first?.first,
              let data = raw.data(using: .utf8), let info = try? JSONDecoder().decode(StorageIndexInfo.self, from: data) else { throw StorageIndexError.invalid }
        return info
    }
    private func setInfo(_ info: StorageIndexInfo) throws {
        let string = String(data: try JSONEncoder().encode(info), encoding: .utf8)!
        try write("INSERT OR REPLACE INTO metadata VALUES('scan',?)", [string])
    }
    func scanScope() throws -> StorageScanScope {
        let value = try rows("SELECT value FROM metadata WHERE key='scope'").first?.first
        return value.flatMap(StorageScanScope.init(rawValue:)) ?? .savedRoots
    }
    private func setScanScope(_ scope: StorageScanScope) throws {
        try write("INSERT OR REPLACE INTO metadata VALUES('scope',?)", [scope.rawValue])
    }
    private func decode(_ row: [String]) -> IndexedStorageItem {
        IndexedStorageItem(url: URL(fileURLWithPath: row[0]), parent: row[1], root: URL(fileURLWithPath: row[2]), title: row[3], bytes: Int64(row[4]) ?? 0, isDirectory: row[5] == "1", fileCount: Int(row[6]) ?? 0, ownerID: row[7], ownerTitle: row[8], component: StorageComponent(rawValue: row[9]) ?? .data, state: Int(row[10]) ?? 0)
    }
    func item(at url: URL) throws -> IndexedStorageItem? { try rows("SELECT \(Self.columns) FROM nodes WHERE path=?", [url.path]).first.map(decode) }
    private struct ContinuationPlan: Codable {
        var jobs: [StorageRoot] = []
        var containers: [URL] = []
    }
    private func savePlan(_ plan: ContinuationPlan) throws {
        let json = String(data: try JSONEncoder().encode(plan), encoding: .utf8)!
        try write("INSERT OR REPLACE INTO metadata VALUES('continuation',?)", [json])
    }
    private func split(_ root: StorageRoot, plan: inout ContinuationPlan) throws {
        guard Self.noLinks(root.url), FileStamp.read(root.url)?.isDirectory == true else { plan.jobs.append(root); return }
        let base = try info().roots.filter { Self.contains(root.url, $0.url) }.max { $0.url.path.count < $1.url.path.count } ?? root
        guard root.url.pathComponents.count - base.url.pathComponents.count < 64 else {
            try write("UPDATE issues SET kind='unavailable',detail='已到目录深度上限，请选择较小范围' WHERE path=? AND kind='incomplete'", [root.url.path]); return
        }
        do {
            let children = try FileManager.default.contentsOfDirectory(at: root.url, includingPropertiesForKeys: nil).filter { $0.path != "/System/Volumes" }.sorted { $0.path < $1.path }
            guard !children.isEmpty else { plan.jobs.append(root); return }
            plan.containers.append(root.url)
            plan.jobs += children.map { StorageRoot(url: $0, title: $0.lastPathComponent, kind: base.kind) }
        } catch {
            let issue = StorageAccessIssue.make(url: root.url, root: base.url, error: error)
            try write("DELETE FROM issues WHERE path=? AND kind='incomplete'", [root.url.path])
            try addIssue(issue, root: base, owner: StorageOwnerResolver(applications: []).resolve(root.url, root: base))
        }
    }
    private func continuationPlan() throws -> ContinuationPlan {
        if let json = try rows("SELECT value FROM metadata WHERE key='continuation'").first?.first,
           let data = json.data(using: .utf8), var plan = try? JSONDecoder().decode(ContinuationPlan.self, from: data) {
            let count = plan.jobs.count
            plan.jobs.removeAll { $0.url.path == "/System/Volumes" }
            if plan.jobs.count != count { try savePlan(plan) }
            return plan
        }
        let info = try info()
        var plan = ContinuationPlan()
        let partial = try rows("SELECT path,root,state FROM nodes WHERE EXISTS(SELECT 1 FROM issues WHERE issues.path=nodes.path AND kind='incomplete') ORDER BY depth,path")
        for row in partial {
            let url = URL(fileURLWithPath: row[0])
            if plan.containers.contains(where: { Self.contains(url, $0) }) { continue }
            let original = info.roots.first { $0.url.path == row[1] } ?? StorageRoot(url: url, title: url.lastPathComponent, kind: .appData)
            let root = StorageRoot(url: url, title: url == original.url ? original.title : url.lastPathComponent, kind: original.kind)
            if row[2] == "0" { plan.jobs.append(root) } else { try split(root, plan: &plan) }
        }
        try savePlan(plan)
        return plan
    }
    func includeAdditionalRoots(_ additions: [StorageRoot]) throws {
        let old = try info()
        var seen = Set<String>()
        let missing = additions.filter { root in seen.insert(root.url.path).inserted && !old.roots.contains { existing in
            Self.contains(root.url, existing.url) && StorageVolumeUsage.identity(for: root.url) == StorageVolumeUsage.identity(for: existing.url)
        } }
        guard !missing.isEmpty else { return }
        var plan = try continuationPlan()
        try execute("BEGIN IMMEDIATE")
        do {
            for root in missing {
                try insert(StorageRecord(url: root.url, root: root, title: root.title, stamp: nil, allocated: 0, isRoot: true), owner: StorageOwnerResolver(applications: []).resolve(root.url, root: root), state: 0)
                try addIssue(StorageAccessIssue.make(url: root.url, root: root.url, detail: "等待补扫", incomplete: true), root: root, owner: StorageOwnerResolver(applications: []).resolve(root.url, root: root))
                plan.jobs.append(root)
            }
            try savePlan(plan)
            try setInfo(StorageIndexInfo(scannedAt: old.scannedAt, roots: old.roots + missing, visited: old.visited, limited: true, cancelled: old.cancelled, unreadableCount: old.unreadableCount, elapsed: old.elapsed))
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    /// An explicit all-locations request expands the scope and restarts its queue.
    /// Existing nodes remain browsable until each replacement subtree is read.
    func prepareAllLocations(including roots: [StorageRoot], checkpoint: StorageCheckpoint) throws {
        try includeAdditionalRoots(roots)
        let previous = try info()
        try execute("BEGIN IMMEDIATE")
        do {
            try setScanScope(.allLocations)
            try savePlan(ContinuationPlan(jobs: previous.roots))
            try saveCheckpoint(checkpoint)
            try setInfo(StorageIndexInfo(scannedAt: previous.scannedAt, roots: previous.roots,
                visited: previous.visited, limited: !previous.roots.isEmpty, cancelled: false,
                unreadableCount: previous.unreadableCount, elapsed: previous.elapsed))
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func pendingRoots() throws -> [StorageRoot] { Array(try continuationPlan().jobs.prefix(64)) }
    func invalidateContinuation() throws { try write("DELETE FROM metadata WHERE key='continuation'") }
    func visitFiles(ownedBy owner: String, in folder: URL?, _ visit: (URL, URL) -> Bool) throws {
        var sql = "SELECT path,root FROM nodes WHERE owner_id=? AND is_dir=0 AND state=1"
        var bindings = [owner]
        if let folder {
            sql += " AND path LIKE ? ESCAPE '\\'"
            let path = Self.canonicalPath(folder)
            bindings.append(Self.escaped(path == "/" ? path : path + "/") + "%")
        }
        let query = try statement(sql, bindings)
        defer { sqlite3_finalize(query) }
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW, let path = sqlite3_column_text(query, 0),
                  let root = sqlite3_column_text(query, 1) else { throw StorageIndexError.invalid }
            if !visit(URL(fileURLWithPath: String(cString: path)), URL(fileURLWithPath: String(cString: root))) { return }
        }
    }
    func page(parent: URL? = nil, ownerID: String? = nil, search: String = "", searchOwnerTitles: [String] = [], ordering: FileOrdering = .size, offset: Int = 0, limit: Int = 100) throws -> StoragePage {
        var predicates: [String] = [], bindings: [String] = []
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let aliases = Array(Set(searchOwnerTitles).prefix(64))
            let owners = aliases.isEmpty ? "" : " OR owner_title IN (" + Array(repeating: "?", count: aliases.count).joined(separator: ",") + ")"
            predicates.append("(search_key LIKE ? ESCAPE '\\' OR lower(path) LIKE ? ESCAPE '\\'" + owners + ")"); let needle = "%" + Self.escaped(Self.folded(search)) + "%"; bindings += [needle,needle] + aliases
        } else if let parent { predicates.append("parent=?"); bindings.append(parent.path) }
        else if let ownerID {
            predicates.append("NOT EXISTS(SELECT 1 FROM nodes p WHERE p.path=nodes.parent AND p.owner_id=?)"); bindings.append(ownerID)
        } else { predicates.append("parent=''") }
        if let ownerID { predicates.append("owner_id=?"); bindings.append(ownerID) }
        let whereClause = predicates.joined(separator: " AND ")
        let total = Int(try rows("SELECT COUNT(*) FROM nodes WHERE " + whereClause, bindings).first?.first ?? "0") ?? 0
        let order = ordering == .name ? "title COLLATE NOCASE,path" : "total_bytes DESC,path"
        let result = try rows("SELECT \(Self.columns) FROM nodes WHERE \(whereClause) ORDER BY \(order) LIMIT ? OFFSET ?", bindings + [String(min(100,max(1,limit))),String(max(0,offset))])
        return StoragePage(items: result.map(decode), total: total, offset: offset)
    }
    func normalizeAccessIssues(home: URL) throws {
        let fullAccess = StoragePermissionStatus.fullDiskAccess(home: home)
        let probes = StoragePermissionStatus.protectedProbes(home: home)
        for issue in try issues() {
            if probes.contains(issue.url), StoragePermissionStatus.readProbe(issue.url) == true {
                try write("DELETE FROM issues WHERE path=?", [issue.url.path])
                try refresh(urls: [issue.url], applications: [])
                continue
            }
            let original: StorageAccessIssue
            // Import the earlier report's system restriction annotation without trusting its old grant.
            if issue.kind == .unavailable && issue.detail.hasPrefix("系统访问限制") {
                original = StorageAccessIssue(url: issue.url, root: issue.root, kind: .permission, detail: issue.detail)
            } else { original = issue }
            let corrected = StoragePermissionStatus.classified(original, fullAccess: fullAccess, home: home)
            if corrected.kind != issue.kind {
                try write("INSERT OR REPLACE INTO issues VALUES(?,?,?,?)", [corrected.url.path,corrected.root.path,corrected.kind.rawValue,corrected.detail])
                try write("DELETE FROM issues WHERE path=? AND kind=?", [issue.url.path,issue.kind.rawValue])
            }
        }
        let previous = try info()
        if fullAccess == false {
            if let probe = probes.first(where: { StoragePermissionStatus.readProbe($0) == false }), let root = previous.roots.filter({ Self.contains(probe, $0.url) }).max(by: { $0.url.path.count < $1.url.path.count }) {
                try addIssue(StorageAccessIssue(url: probe, root: root.url, kind: .permission, detail: "当前版本尚未通过完全磁盘访问试读；请开启轻扫后重新检查。"), root: root, owner: StorageOwnerResolver(applications: []).resolve(probe, root: root))
            }
        }
        let problems = Int(try rows("SELECT COUNT(*) FROM issues WHERE kind<>'incomplete'").first?.first ?? "0") ?? 0
        try setInfo(StorageIndexInfo(scannedAt: previous.scannedAt, roots: previous.roots, visited: previous.visited, limited: previous.limited, cancelled: previous.cancelled, unreadableCount: problems, elapsed: previous.elapsed))
    }
    func issues() throws -> [StorageAccessIssue] {
        try rows("SELECT path,root,kind,detail FROM issues ORDER BY kind,path").map { StorageAccessIssue(url: URL(fileURLWithPath: $0[0]), root: URL(fileURLWithPath: $0[1]), kind: StorageAccessKind(rawValue: $0[2]) ?? .unavailable, detail: $0[3]) }
    }
    func accountedBytes(onDeviceOf home: URL) throws -> Int64 {
        guard let device = StorageVolumeUsage.identity(for: home) else { return 0 }
        return try rows("SELECT root,SUM(own_bytes) FROM nodes GROUP BY root").reduce(Int64(0)) { total, row in
            guard StorageVolumeUsage.identity(for: URL(fileURLWithPath: row[0])) == device else { return total }
            return total + (Int64(row[1]) ?? 0)
        }
    }
    func summaries(applications: [InstalledApplication] = []) throws -> [AppStorageSummary] {
        var summaries: [String: AppStorageSummary] = [:]
        let apps = StorageOwnerResolver(applications: applications)
        for row in try rows("SELECT owner_id,owner_title,component,SUM(own_bytes),SUM(CASE WHEN state<>1 THEN 1 ELSE 0 END),SUM(CASE WHEN state<>0 THEN 1 ELSE 0 END) FROM nodes GROUP BY owner_id,owner_title,component") {
            var summary = summaries[row[0]] ?? AppStorageSummary(id: row[0], title: row[1], applicationURL: apps.owner(id: row[0], fallback: row[1]).applicationURL)
            let bytes = Int64(row[3]) ?? 0
            switch StorageComponent(rawValue: row[2]) ?? .data { case .program: summary.programBytes += bytes; case .data: summary.dataBytes += bytes; case .cache: summary.cacheBytes += bytes; case .logs: summary.logBytes += bytes }
            summary.unreadableCount += Int(row[4]) ?? 0; summary.readableCount += Int(row[5]) ?? 0
            summaries[row[0]] = summary
        }
        return summaries.values.filter { $0.bytes > 0 || $0.partial }.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }

    static func build(at url: URL, roots: [StorageRoot], auditor: StorageAuditor, applications: [InstalledApplication], cancellation: ScanCancellation, ownershipRoots: [StorageRoot] = [], scope: StorageScanScope = .selectedFolders, progress: @escaping (StorageAuditProgress) -> Void = { _ in }) throws -> StorageAuditResult {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = url.deletingLastPathComponent().appendingPathComponent("index-" + UUID().uuidString + ".sqlite")
        defer { try? manager.removeItem(at: staging) }
        var failure: Error?
        let checkpoint = StorageCheckpoint.current()
        var outcome = StorageAuditResult()
        do {
            let index = try StorageIndex(url: staging, create: true)
            let owners = StorageOwnerResolver(applications: applications)
            let classifier = FileClassifier(policy: SafetyPolicy(home: auditor.home), context: InspectionContext(applications: applications))
            let scopeByRoot = Dictionary(uniqueKeysWithValues: roots.map { root in
                (root.url.path, ownershipRoots.filter { Self.contains(root.url, $0.url) }.max { $0.url.path.count < $1.url.path.count } ?? root)
            })
            func ownerForRecord(_ record: StorageRecord) -> StorageOwner {
                let scope = scopeByRoot[record.root.url.path] ?? record.root
                if scope.url.lastPathComponent == "Downloads", !record.isDirectory, let stamp = record.stamp {
                    let assessment = classifier.assess(record.url, stamp: stamp)
                    if assessment.canBatchSelect { return owners.cleanupOwner(ScanItem(url: record.url, root: record.root.url, stamp: stamp, assessment: assessment)) }
                }
                return owners.resolve(record.url, root: scope)
            }
            try index.execute("BEGIN IMMEDIATE")
            for root in roots {
                try index.insert(StorageRecord(url: root.url, root: root, title: root.title, stamp: nil, allocated: 0, isRoot: true), owner: owners.resolve(root.url, root: root), state: 0)
            }
            var writerAuditor = auditor
            writerAuditor.excludedPaths.formUnion([staging.path, staging.path + "-journal", url.path, url.path + "-journal"])
            outcome = writerAuditor.scanIndexed(roots: roots, cancellation: cancellation, onEntry: { record in
                guard failure == nil else { return }
                do { try index.insert(record, owner: ownerForRecord(record), state: record.isRoot ? 0 : 1) }
                catch { failure = error; cancellation.cancel() }
            }, onIssue: { issue in
                guard failure == nil else { return }
                let root = roots.first { $0.url.path == issue.root.path } ?? StorageRoot(url: issue.root, title: issue.root.lastPathComponent, kind: .appData)
                do { try index.addIssue(issue, root: root, owner: owners.resolve(issue.url, root: root)) }
                catch { failure = error; cancellation.cancel() }
            }, onRootFinished: { root, partial in
                do { try index.write("UPDATE nodes SET state=CASE WHEN state=0 AND EXISTS(SELECT 1 FROM issues WHERE path=? AND kind<>'incomplete') THEN 0 ELSE ? END WHERE path=?", [root.url.path,partial ? "2" : "1",root.url.path]) }
                catch { failure = error; cancellation.cancel() }
            }, progress: progress)
            if let failure { throw failure }
            for row in try index.rows("SELECT path,root FROM nodes WHERE parent='' AND state=0 AND NOT EXISTS(SELECT 1 FROM issues WHERE path=nodes.path)") {
                let scope = roots.first { $0.url.path == row[1] } ?? roots[0]
                try index.addIssue(StorageAccessIssue.make(url: URL(fileURLWithPath: row[0]), root: scope.url, detail: "本轮尚未扫描此位置", incomplete: true), root: scope, owner: owners.resolve(scope.url, root: scope))
            }
            try index.recalculate()
            try index.saveCheckpoint(checkpoint)
            try index.setScanScope(scope)
            try index.setInfo(StorageIndexInfo(scannedAt: outcome.scannedAt, roots: roots, visited: outcome.visited, limited: outcome.limited, cancelled: outcome.cancelled, unreadableCount: outcome.unreadableCount, elapsed: outcome.elapsed))
            try index.execute("COMMIT; PRAGMA optimize;")
        }
        // Use the POSIX atomic replacement; only this app-owned cache is replaced.
        guard rename(staging.path, url.path) == 0 else { throw StorageIndexError.unavailable }
        return outcome
    }

    func refresh(urls: [URL], applications: [InstalledApplication]) throws {
        let info = try self.info(), resolver = StorageOwnerResolver(applications: applications)
        let directories=try urls.filter{let previous=try item(at:$0);return FileStamp.read($0)?.isDirectory==true || previous?.isDirectory==true}
        for url in directories where FileStamp.read(url)?.isDirectory==true {
            guard let root=info.roots.filter({Self.contains(url,$0.url)}).max(by:{$0.url.path.count<$1.url.path.count}) else{continue}
            let temporary=self.url.deletingLastPathComponent().appendingPathComponent("restored-"+UUID().uuidString+".sqlite")
            defer{try? FileManager.default.removeItem(at:temporary)}
            _=try StorageIndex.build(at:temporary,roots:[StorageRoot(url:url,title:url.lastPathComponent,kind:root.kind)],auditor:StorageAuditor(home:FileManager.default.homeDirectoryForCurrentUser),applications:applications,cancellation:ScanCancellation(),ownershipRoots:info.roots)
            try merge(subtree:url,from:StorageIndex(url:temporary))
        }
        try execute("BEGIN IMMEDIATE")
        do {
            for url in urls {
                if FileStamp.read(url)?.isDirectory==true{continue}
                guard let root = info.roots.filter({ Self.contains(url, $0.url) }).max(by: { $0.url.path.count < $1.url.path.count }) else { continue }
                try write("DELETE FROM nodes WHERE path=? OR path LIKE ? ESCAPE '\\'", [url.path,Self.escaped(url.path+"/")+"%"]); try write("DELETE FROM issues WHERE path=? OR path LIKE ? ESCAPE '\\'",[url.path,Self.escaped(url.path+"/")+"%"])
                if let stamp = FileStamp.read(url), stamp.isRegular, stamp.links == 1, !stamp.isDataless, Self.noLinks(url) {
                    let record = StorageRecord(url: url, root: root, title: url.lastPathComponent, stamp: stamp, allocated: stamp.allocated, isRoot: false)
                    let owner: StorageOwner
                    if root.url.lastPathComponent == "Downloads" {
                        let classifier = FileClassifier(policy: SafetyPolicy(home: root.url.deletingLastPathComponent()), context: InspectionContext(applications: applications))
                        let assessment = classifier.assess(url, stamp: stamp)
                        owner = assessment.canBatchSelect
                            ? resolver.cleanupOwner(ScanItem(url: url, root: root.url, stamp: stamp, assessment: assessment))
                            : resolver.resolve(url, root: root)
                    } else { owner = resolver.resolve(url, root: root) }
                    var parents: [URL] = [], cursor = url.deletingLastPathComponent()
                    while cursor.path != root.url.path && Self.contains(cursor, root.url) {
                        if try item(at: cursor) != nil { break }
                        parents.insert(cursor, at: 0); cursor.deleteLastPathComponent()
                    }
                    for parent in parents {
                        guard let directoryStamp = FileStamp.read(parent), directoryStamp.isDirectory else { continue }
                        let parentRecord = StorageRecord(url: parent, root: root, title: parent.lastPathComponent, stamp: directoryStamp, allocated: 0, isRoot: false)
                        try insert(parentRecord, owner: resolver.resolve(parent, root: root), state: 2)
                        try addIssue(StorageAccessIssue.make(url: parent, root: root.url, detail: "文件已恢复，请重新扫描此文件夹", incomplete: true), root: root, owner: resolver.resolve(parent, root: root))
                    }
                    try insert(record, owner: owner)
                }
            }
            try recalculate(); try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func recordAccessCheck(remaining: [StorageAccessIssue], readable: [URL]) throws {
        let previous = try info()
        var plan = try continuationPlan()
        let resolver = StorageOwnerResolver(applications: [])
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM issues")
            for issue in remaining { try write("INSERT OR REPLACE INTO issues VALUES(?,?,?,?)", [issue.url.path,issue.root.path,issue.kind.rawValue,issue.detail]) }
            for url in readable {
                guard let root = previous.roots.filter({ Self.contains(url, $0.url) }).max(by: { $0.url.path.count < $1.url.path.count }) else { continue }
                try addIssue(StorageAccessIssue(url: url, root: root.url, kind: .incomplete, detail: "访问已可用，请重新扫描此文件夹"), root: root, owner: resolver.resolve(url, root: root))
                if !plan.jobs.contains(where: { Self.contains(url, $0.url) }) {
                    plan.jobs.removeAll { Self.contains($0.url, url) }
                    plan.jobs.append(StorageRoot(url: url, title: url.lastPathComponent, kind: root.kind))
                }
            }
            try savePlan(plan)
            let problems = remaining.filter { $0.kind != .incomplete }.count
            try setInfo(StorageIndexInfo(scannedAt: previous.scannedAt, roots: previous.roots, visited: previous.visited, limited: previous.limited || !plan.jobs.isEmpty, cancelled: previous.cancelled, unreadableCount: problems, elapsed: previous.elapsed))
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Replace only a rescanned subtree. Other applications retain their snapshot.
    func merge(subtree url: URL, from other: StorageIndex) throws {
        let sourceInfo = try other.info(), oldInfo = try info()
        guard sourceInfo.roots.count == 1, sourceInfo.roots[0].url.path == url.path else { throw StorageIndexError.invalid }
        try merge(roots: sourceInfo.roots, from: other, oldInfo: oldInfo)
    }
    func mergePending(from other: StorageIndex) throws {
        let plan = try continuationPlan(), pending = Set(plan.jobs.map { $0.url.path }), sourceInfo = try other.info()
        guard !sourceInfo.roots.isEmpty, sourceInfo.roots.allSatisfy({ pending.contains($0.url.path) }) else { throw StorageIndexError.invalid }
        try merge(roots: sourceInfo.roots, from: other, oldInfo: info(), continuation: plan)
    }
    private func merge(roots supplied: [StorageRoot], from other: StorageIndex, oldInfo: StorageIndexInfo, continuation: ContinuationPlan? = nil) throws {
        let unstarted = Set(try other.rows("SELECT path FROM nodes WHERE parent='' AND state=0 AND EXISTS(SELECT 1 FROM issues WHERE issues.path=nodes.path AND kind='incomplete')").compactMap(\.first))
        let roots = supplied.filter { !unstarted.contains($0.url.path) }
        let sourceInfo = try other.info()
        let tablePath = other.url.path.replacingOccurrences(of: "'", with: "''")
        try execute("ATTACH DATABASE '\(tablePath)' AS fresh")
        defer { try? execute("DETACH DATABASE fresh") }
        try execute("BEGIN IMMEDIATE")
        do {
            var parents: [(URL, String)] = []
            for root in roots {
                try write("DELETE FROM issues WHERE path=? AND kind='incomplete'", [root.url.path])
                let url = root.url, pattern = Self.escaped(root.url.path + "/") + "%"
                if !(try rows("SELECT path FROM nodes WHERE path=?", [url.deletingLastPathComponent().path])).isEmpty { parents.append((url, url.deletingLastPathComponent().path)) }
                if try other.item(at: url)?.state == 1 {
                    try write("DELETE FROM nodes WHERE path=? OR path LIKE ? ESCAPE '\\'", [url.path,pattern])
                    try write("DELETE FROM issues WHERE path=? OR path LIKE ? ESCAPE '\\'", [url.path,pattern])
                } else {
                    try write("DELETE FROM issues WHERE kind<>'incomplete' AND path IN (SELECT path FROM fresh.nodes WHERE state=1 AND (path=? OR path LIKE ? ESCAPE '\\'))", [url.path,pattern])
                }
            }
            for root in roots {
                let pattern = Self.escaped(root.url.path + "/") + "%"
                try write("INSERT OR REPLACE INTO nodes SELECT * FROM fresh.nodes WHERE path=? OR path LIKE ? ESCAPE '\\'", [root.url.path,pattern])
                try write("INSERT OR REPLACE INTO issues SELECT * FROM fresh.issues WHERE path=? OR path LIKE ? ESCAPE '\\'", [root.url.path,pattern])
            }
            for (url, parent) in parents { try write("UPDATE nodes SET parent=? WHERE path=?", [parent,url.path]) }
            for root in roots {
                if let original = oldInfo.roots.filter({ Self.contains(root.url, $0.url) }).max(by: { $0.url.path.count < $1.url.path.count }) {
                    try write("UPDATE nodes SET root=? WHERE path=? OR path LIKE ? ESCAPE '\\'", [original.url.path,root.url.path,Self.escaped(root.url.path + "/") + "%"])
                    if original.url.path == root.url.path { try write("UPDATE nodes SET title=?,search_key=? || ' ' || search_key WHERE path=?", [original.title,Self.folded(original.title),root.url.path]) }
                }
            }
            var scopes = oldInfo.roots
            for root in roots where !scopes.contains(where: { Self.contains(root.url, $0.url) }) { scopes.append(root) }
            var plan = continuation
            if plan != nil {
                let finished = Set(roots.map { $0.url.path })
                plan!.jobs.removeAll { finished.contains($0.url.path) }
                let incompletePaths = Set(try other.rows("SELECT path FROM issues WHERE kind='incomplete'").compactMap(\.first))
                for root in roots where incompletePaths.contains(root.url.path) { try split(root, plan: &plan!) }
                for container in plan!.containers where !plan!.jobs.contains(where: { Self.contains($0.url, container) }) {
                    try write("DELETE FROM issues WHERE path=? AND kind='incomplete'", [container.path])
                    try write("UPDATE nodes SET state=1 WHERE path=? AND state=2", [container.path])
                }
                try savePlan(plan!)
            } else { try invalidateContinuation() }
            if plan == nil || plan!.jobs.isEmpty { try deduplicateHardlinks() }
            try recalculate()
            let count = Int(try rows("SELECT COUNT(*) FROM issues WHERE kind<>'incomplete'").first?.first ?? "0") ?? 0
            let incomplete = !(try rows("SELECT path FROM issues WHERE kind='incomplete' LIMIT 1")).isEmpty
            try setInfo(StorageIndexInfo(scannedAt: Date(), roots: scopes, visited: oldInfo.visited + sourceInfo.visited, limited: incomplete, cancelled: sourceInfo.cancelled, unreadableCount: count, elapsed: sourceInfo.elapsed))
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
}
