import Foundation
import Darwin

enum StorageKind: String, CaseIterable, Codable, Identifiable {
    case cache, appData, system, project
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cache: return "缓存"
        case .appData: return "应用数据"
        case .system: return "系统资源"
        case .project: return "项目资料"
        }
    }
    var symbol: String {
        switch self {
        case .cache: return "internaldrive"
        case .appData: return "square.stack.3d.up"
        case .system: return "gearshape.2"
        case .project: return "folder"
        }
    }
}

struct StorageRoot: Codable {
    let url: URL
    let title: String
    let kind: StorageKind
    static var additionalDataRoots: [StorageRoot] {
        [("/System/Volumes/Data/System", "系统数据目录"), ("/System/Volumes/Data/usr", "本机工具数据")].compactMap { path, title in
            guard FileStamp.read(URL(fileURLWithPath: path))?.isDirectory == true else { return nil }
            return StorageRoot(url: URL(fileURLWithPath: path), title: title, kind: .system)
        }
    }
    static func defaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [StorageRoot] {
        // Space analysis includes personal files and hidden workspaces. Cleanup
        // eligibility is deliberately decided elsewhere by SafetyPolicy/classification.
        let manager = FileManager.default
        let known: [(String, String, StorageKind)] = [
            ("Documents", "文稿与项目", .project), ("Pictures", "照片与图库", .project),
            ("Movies", "视频与素材", .project), ("Downloads", "下载文件", .project),
            ("Desktop", "桌面文件", .project), ("Music", "音乐与音频", .project),
            ("Library/Application Support", "应用支持数据", .appData),
            ("Library/Group Containers", "应用共享数据", .appData),
            ("Library/Containers", "应用独立数据", .appData),
            ("Library/Caches", "应用缓存", .cache), ("Library/Logs", "应用日志", .cache)
        ]
        var roots = known.map { StorageRoot(url: home.appendingPathComponent($0.0), title: $0.1, kind: $0.2) }
        func children(_ url: URL) -> [URL] {
            (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?.sorted { $0.path < $1.path } ?? []
        }
        let knownHome = Set(known.map { $0.0.split(separator: "/").first.map(String.init)! })
        for url in children(home) where !knownHome.contains(url.lastPathComponent) {
            roots.append(StorageRoot(url: url, title: url.lastPathComponent, kind: .project))
        }
        let library = home.appendingPathComponent("Library")
        let knownLibrary = Set(known.filter { $0.0.hasPrefix("Library/") }.map { home.appendingPathComponent($0.0).path })
        for url in children(library) where !knownLibrary.contains(url.path) {
            roots.append(StorageRoot(url: url, title: "资料库 / " + url.lastPathComponent, kind: .appData))
        }
        // Keep root scopes disjoint, so a large directory cannot hide later roots
        // behind a parent scan's time limit. External mounts remain opt-in.
        for path in ["/Applications", "/Library", "/private", "/System", "/usr", "/opt", "/bin", "/sbin"] {
            roots.append(StorageRoot(url: URL(fileURLWithPath: path), title: ["/Applications": "应用程序", "/Library": "共享资料库", "/private": "系统与临时数据", "/System": "macOS 系统" ][path] ?? path, kind: .system))
        }
        for url in children(URL(fileURLWithPath: "/Users")) where url.path != home.path {
            roots.append(StorageRoot(url: url, title: "用户 / " + url.lastPathComponent, kind: .project))
        }
        return roots + additionalDataRoots
    }
}

struct StorageEntry: Identifiable, Codable {
    var id: String { url.path }
    let title: String
    let subtitle: String
    let url: URL
    let bytes: Int64
    let kind: StorageKind
    let children: [StorageEntry]
    let fileCount: Int
    let unreadableCount: Int
    let omittedChildCount: Int
    var hasMoreChildren: Bool { omittedChildCount > 0 }
}

struct StorageAuditResult: Codable {
    var entries: [StorageEntry] = []
    var visited = 0
    var files = 0
    var skipped = 0
    var issues: [String] = []
    var unreadableCount = 0
    var cancelled = false
    var limited = false
    var elapsed: TimeInterval = 0
    var scannedAt = Date()
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
}

struct StorageAuditProgress {
    var visited = 0
    var files = 0
    var bytes: Int64 = 0
    var current = ""
}

enum StorageAccessKind: String, Codable { case permission, restricted, missing, disconnected, unavailable, incomplete
    var title: String { switch self { case .permission: return "需要访问权限"; case .restricted: return "系统访问限制"; case .missing: return "位置不存在"; case .disconnected: return "磁盘未连接"; case .unavailable: return "暂时无法读取"; case .incomplete: return "扫描未完成" } }
}
struct StorageAccessIssue: Identifiable, Codable {
    var id: String { url.path + "|" + kind.rawValue }
    let url: URL
    let root: URL
    let kind: StorageAccessKind
    let detail: String
    static func make(url: URL, root: URL, error: Error? = nil, detail: String = "", incomplete: Bool = false) -> StorageAccessIssue {
        let e = error as NSError?
        let missing = FileStamp.read(url) == nil
        let statError = errno
        let volume = url.pathComponents.count > 2 && url.pathComponents[1] == "Volumes" ? URL(fileURLWithPath: "/Volumes/" + url.pathComponents[2]) : nil
        let kind: StorageAccessKind
        if incomplete { kind = .incomplete }
        else if let volume, FileStamp.read(volume) == nil { kind = .disconnected }
        else if missing && [EACCES, EPERM].contains(statError) { kind = .permission }
        else if e?.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(e!.code) || e?.domain == NSCocoaErrorDomain && e?.code == NSFileReadNoPermissionError { kind = .permission }
        else if missing { kind = .missing }
        else { kind = .unavailable }
        return StorageAccessIssue(url: url, root: root, kind: kind, detail: error?.localizedDescription ?? detail)
    }
}
struct StorageRecord {
    let url: URL
    let root: StorageRoot
    let title: String
    let stamp: FileStamp?
    let allocated: Int64
    let isRoot: Bool
    var isDirectory: Bool { stamp?.isDirectory ?? isRoot }
}

/// Metadata-only space accounting. Its totals describe the specified directories,
/// not the private category calculation shown in macOS Storage settings.
struct StorageAuditor {
    let home: URL
    var entryLimit: Int
    var childLimit: Int
    var timeLimit: TimeInterval
    var rootTimeLimit: TimeInterval
    var maximumDepth = 64
    var excludedPaths = Set<String>()
    private let detailDepth = 3
    private let nodeLimit = 25_000

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         entryLimit: Int = 1_200_000, childLimit: Int = 16,
         timeLimit: TimeInterval = 120, rootTimeLimit: TimeInterval = 35) {
        self.home = Self.lexicalURL(home)
        self.entryLimit = max(1, entryLimit)
        self.childLimit = max(1, childLimit)
        self.timeLimit = max(0.01, timeLimit)
        self.rootTimeLimit = max(0.01, rootTimeLimit)
    }

    func scan(roots suppliedRoots: [StorageRoot]? = nil, cancellation: ScanCancellation,
              progress: @escaping (StorageAuditProgress) -> Void = { _ in }) -> StorageAuditResult {
        scanIndexed(roots: suppliedRoots, cancellation: cancellation, onEntry: { _ in }, onIssue: { _ in }, onRootFinished: { _, _ in }, progress: progress)
    }

    func scanIndexed(roots suppliedRoots: [StorageRoot]? = nil, cancellation: ScanCancellation,
                     onEntry: @escaping (StorageRecord) -> Void, onIssue: @escaping (StorageAccessIssue) -> Void,
                     onRootFinished: (StorageRoot, Bool) -> Void,
                     progress: @escaping (StorageAuditProgress) -> Void = { _ in }) -> StorageAuditResult {
        let started = Date()
        var result = StorageAuditResult()
        var activeRoot = URL(fileURLWithPath: "/")
        var seen = Set<StorageIdentity>()
        var bytes: Int64 = 0
        var lastUpdate = Date.distantPast
        var nodesCreated = 0
        let keys: Set<URLResourceKey> = [.isAliasFileKey, .isUbiquitousItemKey]
        let manager = FileManager.default
        let roots = uniqueRoots(suppliedRoots ?? StorageRoot.defaults(home: home))
        let titles = StorageTitleResolver(applications: cancellation.isCancelled ? [] : InspectionContext.collect(home: home).applications)

        func issue(_ url: URL, _ reason: String, error: Error? = nil) {
            onIssue(StorageAccessIssue.make(url: url, root: activeRoot, error: error, detail: reason))
            result.unreadableCount += 1
            if result.issues.count < 80 { result.issues.append(url.path + "：" + reason) }
        }
        func stopped() -> Bool {
            if cancellation.isCancelled { return true }
            if result.visited >= entryLimit || Date().timeIntervalSince(started) >= timeLimit {
                result.limited = true
                return true
            }
            return false
        }
        func update(_ path: @autoclosure () -> String, force: Bool = false) {
            if force || Date().timeIntervalSince(lastUpdate) > 0.15 {
                lastUpdate = Date()
                progress(StorageAuditProgress(visited: result.visited, files: result.files, bytes: bytes, current: path()))
            }
        }

        for root in roots {
            if stopped() { break }
            activeRoot = root.url
            let beforeRootIssues = result.unreadableCount
            var rootLimited = false, completedFile = false
            defer {
                let truncated = !completedFile && (rootLimited || cancellation.isCancelled || result.visited >= entryLimit || Date().timeIntervalSince(started) >= timeLimit)
                if truncated { onIssue(StorageAccessIssue.make(url: root.url, root: root.url, detail: cancellation.isCancelled ? "扫描已停止" : "本轮扫描未完成", incomplete: true)) }
                onRootFinished(root, truncated || result.unreadableCount > beforeRootIssues)
            }
            update(root.url.path, force: true)
            onEntry(StorageRecord(url: root.url, root: root, title: root.title, stamp: FileStamp.read(root.url), allocated: 0, isRoot: true))
            guard noSymlinkComponents(root.url), let rootStamp = FileStamp.read(root.url),
                  (rootStamp.isDirectory || rootStamp.isRegular), !rootStamp.isDataless else {
                issue(root.url, "位置不存在或无法读取")
                continue
            }
            guard let rootValues = try? root.url.resourceValues(forKeys: keys), rootValues.isAliasFile != true,
                  rootValues.isUbiquitousItem != true else {
                result.skipped += 1
                issue(root.url, "云端目录或别名未展开")
                continue
            }
            if rootStamp.isRegular {
                completedFile = true
                let occupied = seen.insert(StorageIdentity(device: rootStamp.device, inode: rootStamp.inode)).inserted ? max(0, rootStamp.allocated) : 0
                bytes += occupied; result.visited += 1; result.files += 1
                onEntry(StorageRecord(url: root.url, root: root, title: root.title, stamp: rootStamp, allocated: occupied, isRoot: true))
                result.entries.append(StorageEntry(title: root.title, subtitle: root.url.path, url: root.url, bytes: occupied, kind: root.kind, children: [], fileCount: 1, unreadableCount: 0, omittedChildCount: 0))
                continue
            }
            let rootVolume = StorageVolumeUsage.identity(for: root.url)
            let rootStarted = Date()
            let rootPath = root.url.path
            let rootPrefix = rootPath == "/" ? "/" : rootPath + "/"
            let node = StorageNode(url: root.url, title: root.title, kind: root.kind, titles: titles)
            nodesCreated += 1
            let beforeIssues = result.unreadableCount
            // Foundation does not descend into symbolic links. We also validate every
            // entry with lstat, and refuse directories on a different device.
            guard let enumerator = manager.enumerator(at: root.url, includingPropertiesForKeys: nil, options: [], errorHandler: { url, error in
                issue(url, error.localizedDescription, error: error)
                node.addIssue(url: url, root: root.url, detailDepth: detailDepth, nodeLimit: nodeLimit, nodesCreated: &nodesCreated)
                return !cancellation.isCancelled
            }) else {
                issue(root.url, "无法列出文件夹")
                continue
            }
            while !stopped(), let url = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
                if Date().timeIntervalSince(rootStarted) >= rootTimeLimit {
                    result.limited = true; rootLimited = true
                    onIssue(StorageAccessIssue.make(url: root.url, root: root.url, detail: "达到本轮扫描时间上限", incomplete: true))
                    if result.issues.count < 80 { result.issues.append(root.url.path + "：仅显示本次已读取的内容") }
                    break
                }
                result.visited += 1
                autoreleasepool {
                    let path = url.path
                    if (root.url.path == "/System" && path == "/System/Volumes") || excludedPaths.contains(path) {
                        if FileStamp.read(url)?.isDirectory == true { enumerator.skipDescendants() }
                        result.skipped += 1; return
                    }
                    guard let stamp = FileStamp.read(url) else {
                        issue(url, "无法读取文件信息")
                        node.addIssue(url: url, root: root.url, detailDepth: detailDepth, nodeLimit: nodeLimit, nodesCreated: &nodesCreated)
                        return
                    }
                    guard path.hasPrefix(rootPrefix), !stamp.isSymlink, !stamp.isDataless, stamp.device == rootStamp.device else {
                        if stamp.isDirectory { enumerator.skipDescendants() }
                        result.skipped += 1
                        return
                    }
                    if enumerator.level > maximumDepth {
                        if stamp.isDirectory { enumerator.skipDescendants() }
                        result.skipped += 1
                        result.limited = true; rootLimited = true
                        onIssue(StorageAccessIssue.make(url: url, root: root.url, detail: "达到目录深度上限", incomplete: true))
                        return
                    }
                    // A regular file needs only lstat accounting. In particular,
                    // aliases are counted as small local files, never resolved;
                    // cloud placeholders are skipped above without opening them.
                    // Query URL resource state only before descending a directory.
                    if stamp.isDirectory {
                        if let rootVolume, let volume = StorageVolumeUsage.identity(for: url), volume != rootVolume { enumerator.skipDescendants(); result.skipped += 1; return }
                        guard let values = try? url.resourceValues(forKeys: keys) else {
                            enumerator.skipDescendants()
                            issue(url, "无法读取文件信息")
                            node.addIssue(url: url, root: root.url, detailDepth: detailDepth, nodeLimit: nodeLimit, nodesCreated: &nodesCreated)
                            return
                        }
                        guard values.isAliasFile != true, values.isUbiquitousItem != true else {
                            enumerator.skipDescendants()
                            result.skipped += 1
                            issue(url, "云端目录或别名未展开")
                            return
                        }
                    }
                    guard stamp.isRegular || stamp.isDirectory else { result.skipped += 1; return }
                    guard seen.insert(StorageIdentity(device: stamp.device, inode: stamp.inode)).inserted else {
                        if stamp.isDirectory { enumerator.skipDescendants() }
                        if stamp.isRegular { onEntry(StorageRecord(url: url, root: root, title: url.lastPathComponent, stamp: stamp, allocated: 0, isRoot: false)) }
                        result.skipped += 1
                        return
                    }
                    let occupied = max(0, stamp.allocated)
                    bytes += occupied
                    onEntry(StorageRecord(url: url, root: root, title: enumerator.level <= 2 ? titles.title(for: url, allowContainerIdentity: true) : url.lastPathComponent, stamp: stamp, allocated: occupied, isRoot: false))
                    if stamp.isRegular { result.files += 1 }
                    node.add(relativePath: path.dropFirst(rootPrefix.count), bytes: occupied, file: stamp.isRegular,
                             detailDepth: detailDepth, nodeLimit: nodeLimit, nodesCreated: &nodesCreated)
                }
                update(url.deletingLastPathComponent().path)
            }
            // Missing child nodes due to a bounded display tree do not change the
            // measured root totals. Unreadable content is always reported separately.
            node.unreadableCount = result.unreadableCount - beforeIssues
            result.entries.append(node.entry(home: home, childLimit: childLimit))
        }
        result.entries.sort(by: StorageNode.ordered)
        result.cancelled = cancellation.isCancelled
        result.elapsed = Date().timeIntervalSince(started)
        result.scannedAt = Date()
        update("", force: true)
        return result
    }

    private func noSymlinkComponents(_ url: URL) -> Bool {
        var cursor = Self.lexicalURL(url)
        while cursor.path != "/" {
            guard let stamp = FileStamp.read(cursor), !stamp.isSymlink else { return false }
            cursor.deleteLastPathComponent()
        }
        return true
    }
    private func uniqueRoots(_ roots: [StorageRoot]) -> [StorageRoot] {
        let normalized = roots.map { StorageRoot(url: Self.lexicalURL($0.url), title: $0.title, kind: $0.kind) }
        return normalized.enumerated().filter { index, root in
            !normalized.enumerated().contains { otherIndex, other in
                if other.url.path == root.url.path { return otherIndex < index }
                let prefix = other.url.path == "/" ? "/" : other.url.path + "/"
                return root.url.path.hasPrefix(prefix) && StorageVolumeUsage.identity(for: root.url) == StorageVolumeUsage.identity(for: other.url)
            }
        }.map { $0.element }
    }
    // Foundation's standardizedFileURL may rewrite /private/var as /var on
    // macOS. Keep the physical spelling so validation does not reject it as a
    // symbolic-link ancestor; only remove lexical dot components here.
    private static func lexicalURL(_ url: URL) -> URL {
        var parts: [String] = []
        for part in url.pathComponents {
            if part == "/" || part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part) }
        }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"))
    }
}

private struct StorageIdentity: Hashable {
    let device: Int32
    let inode: UInt64
}

private final class StorageNode {
    let url: URL
    let title: String
    let kind: StorageKind
    var bytes: Int64 = 0
    var fileCount = 0
    var unreadableCount = 0
    var children: [String: StorageNode] = [:]
    var omitted = Set<String>()
    private let titles: StorageTitleResolver
    private let depth: Int
    init(url: URL, title: String? = nil, kind: StorageKind, titles: StorageTitleResolver, depth: Int = 0) {
        self.url = url
        self.title = title ?? titles.title(for: url, allowContainerIdentity: depth <= 2)
        self.kind = kind
        self.titles = titles
        self.depth = depth
    }
    func add(relativePath: Substring, bytes: Int64, file: Bool, detailDepth: Int, nodeLimit: Int, nodesCreated: inout Int) {
        self.bytes += bytes
        if file { fileCount += 1 }
        var node = self
        for component in relativePath.split(separator: "/", maxSplits: detailDepth).prefix(detailDepth) {
            guard let child = node.child(String(component), limit: nodeLimit, nodesCreated: &nodesCreated) else { break }
            child.bytes += bytes
            if file { child.fileCount += 1 }
            node = child
        }
    }
    func addIssue(url: URL, root: URL, detailDepth: Int, nodeLimit: Int, nodesCreated: inout Int) {
        guard SafetyPolicy.within(url, root) else { return }
        var node = self
        for component in url.pathComponents.dropFirst(root.pathComponents.count).prefix(detailDepth) {
            guard let child = node.child(component, limit: nodeLimit, nodesCreated: &nodesCreated) else { break }
            child.unreadableCount += 1
            node = child
        }
    }
    private func child(_ name: String, limit: Int, nodesCreated: inout Int) -> StorageNode? {
        if let child = children[name] { return child }
        guard nodesCreated < limit else { omitted.insert(name); return nil }
        let child = StorageNode(url: url.appendingPathComponent(name), kind: kind, titles: titles, depth: depth + 1)
        children[name] = child
        nodesCreated += 1
        return child
    }
    func entry(home: URL, childLimit: Int) -> StorageEntry {
        let sorted = children.values.sorted { $0.bytes == $1.bytes ? $0.url.path < $1.url.path : $0.bytes > $1.bytes }
        let path = SafetyPolicy.within(url, home) ? "~" + url.path.dropFirst(home.path.count) : url.path
        return StorageEntry(title: title, subtitle: String(path), url: url, bytes: bytes, kind: kind,
                            children: sorted.prefix(childLimit).map { $0.entry(home: home, childLimit: childLimit) },
                            fileCount: fileCount, unreadableCount: unreadableCount,
                            omittedChildCount: max(0, sorted.count - childLimit) + omitted.count)
    }
    static func ordered(_ lhs: StorageEntry, _ rhs: StorageEntry) -> Bool {
        lhs.bytes == rhs.bytes ? lhs.id < rhs.id : lhs.bytes > rhs.bytes
    }
}

/// Reads only installed-app identity and the OS container identity plist. No
/// chat databases, documents or files inside application data are inspected.
private final class StorageTitleResolver {
    private let applicationNames: [String: String]
    private var resolved: [String: String] = [:]
    init(applications: [InstalledApplication]) {
        var names: [String: String] = [:]
        for app in applications.sorted(by: { $0.version.compare($1.version, options: .numeric) == .orderedDescending }) {
            let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, names[app.id] == nil { names[app.id] = name }
        }
        applicationNames = names
    }
    func title(for url: URL, allowContainerIdentity: Bool) -> String {
        if let known = resolved[url.path] { return known }
        let name = url.lastPathComponent
        let title: String
        if let known = Self.commonNames[name] { title = known }
        else if let installed = appName(for: name) { title = installed }
        else if allowContainerIdentity, ["Containers", "Group Containers"].contains(url.deletingLastPathComponent().lastPathComponent),
                let identifier = containerIdentifier(url),
                let installed = Self.commonNames[identifier] ?? appName(for: identifier) { title = installed }
        else { title = name }
        resolved[url.path] = title
        return title
    }
    private func appName(for identifier: String) -> String? {
        if let exact = applicationNames[identifier] { return exact }
        if identifier.hasPrefix("group."), let grouped = applicationNames[String(identifier.dropFirst(6))] { return grouped }
        if identifier.hasSuffix(".ShipIt"), let app = applicationNames[String(identifier.dropLast(7))] { return app + " 更新缓存" }
        return nil
    }
    private func containerIdentifier(_ directory: URL) -> String? {
        guard let directoryStamp = FileStamp.read(directory), directoryStamp.isDirectory, !directoryStamp.isDataless else { return nil }
        let metadata = directory.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let stamp = FileStamp.read(metadata), stamp.isRegular, stamp.links == 1, !stamp.isDataless,
              stamp.size > 0, stamp.size <= 1_000_000,
              let values = try? metadata.resourceValues(forKeys: [.isUbiquitousItemKey]), values.isUbiquitousItem != true,
              let data = try? Data(contentsOf: metadata),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["MCMMetadataIdentifier"] as? String
    }
    private static let commonNames: [String: String] = [
            "group.com.apple.coreservices.useractivityd": "跨设备剪贴板",
            "shared-pasteboard": "共享剪贴板",
            "archives": "归档文件",
            "vm_bundles": "虚拟机运行资源",
            "com.tencent.xinWeChat": "微信",
            "com.netease.163music": "网易云音乐",
            "com.baidu.netdisk": "百度网盘",
            "com.apple.Safari": "Safari",
            "com.netease.macmail": "网易邮箱",
            "com.microsoft.teams2": "Microsoft Teams",
            "UBF8T346G9.Office": "Microsoft Office",
            "group.com.apple.UserNotifications": "系统通知",
            "Adobe Camera Raw 2": "Camera Raw 图像缓存",
            "com.microsoft.VSCode.ShipIt": "Visual Studio Code 更新缓存"
        ]
}

/// Rechecks access without reading file contents or resolving linked paths.
enum StorageAccessProbe {
    static func problem(at url: URL, root: URL) -> StorageAccessIssue? {
        var cursor = url
        while cursor.path != "/" {
            guard let stamp = FileStamp.read(cursor), !stamp.isSymlink, !stamp.isDataless else { return StorageAccessIssue.make(url: url, root: root, detail: "位置不可用或包含链接") }
            cursor.deleteLastPathComponent()
        }
        guard let stamp = FileStamp.read(url) else { return StorageAccessIssue.make(url: url, root: root, detail: "无法读取文件信息") }
        if !stamp.isDirectory { return stamp.isRegular ? nil : StorageAccessIssue.make(url: url, root: root, detail: "此位置无法分析") }
        do { _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []); return nil }
        catch { return StorageAccessIssue.make(url: url, root: root, error: error) }
    }
    static func rescanFolder(for issue: StorageAccessIssue) -> URL {
        var cursor = issue.url
        while cursor.path != issue.root.path && cursor.path != "/" {
            if FileStamp.read(cursor)?.isDirectory == true { return cursor }
            cursor.deleteLastPathComponent()
        }
        return issue.root
    }
}

struct StoragePermissionStatus {
    static func protectedProbes(home: URL) -> [URL] {
        [home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"), URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")]
    }
    // Open and close only: no database tables or private permission records are read.
    static func readProbe(_ probe: URL) -> Bool? {
        guard probe.isFileURL else { return nil }
        let descriptor = probe.withUnsafeFileSystemRepresentation { raw in
            raw.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { return [EACCES,EPERM].contains(errno) ? false : nil }
        defer { Darwin.close(descriptor) }
        var stamp = stat()
        guard fstat(descriptor, &stamp) == 0, stamp.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG) else { return nil }
        return true
    }
    static func fullDiskAccess(home: URL, probes: [URL]? = nil) -> Bool? {
        var denied = false
        for probe in probes ?? protectedProbes(home: home) {
            if let readable = readProbe(probe) {
                if readable { return true }
                denied = true
            }
        }
        return denied ? false : nil
    }
    static func classified(_ issue: StorageAccessIssue, fullAccess: Bool?, home: URL) -> StorageAccessIssue {
        guard issue.kind == .permission || issue.kind == .restricted else { return issue }
        let system = ["/private", "/System", "/Library"].contains { SafetyPolicy.within(issue.url, URL(fileURLWithPath: $0)) } || issue.url.path == "/usr/sbin/authserver"
        if system && !SafetyPolicy.within(issue.url, home) && fullAccess == true {
            return StorageAccessIssue(url: issue.url, root: issue.root, kind: .restricted, detail: issue.detail)
        }
        return issue.kind == .restricted ? StorageAccessIssue(url: issue.url, root: issue.root, kind: .permission, detail: issue.detail) : issue
    }
}
