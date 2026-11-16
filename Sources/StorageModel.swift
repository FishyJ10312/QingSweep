import SwiftUI
import AppKit

enum StoragePresentation: String, CaseIterable { case applications = "按应用", folders = "按文件夹" }

extension AppModel {
    var storageHasPersonalCoverage: Bool {
        guard let info = storageInfo else { return false }
        return ["Documents", "Pictures", "Movies", "Desktop", "Music"].allSatisfy { folder in
            info.roots.contains { SafetyPolicy.within(policy.home.appendingPathComponent(folder), $0.url) }
        }
    }
    var storageUnaccountedBytes: Int64 { max(0, snapshot.diskTotal - snapshot.diskFree - storageCountedBytes) }
    var storageSystemBytes: Int64 { storageVolumes.reduce(0) { $0 + $1.bytes } }
    var storageRemainingBytes: Int64 { max(0, storageUnaccountedBytes - storageSystemBytes) }
    var storagePermissionCount: Int { storageAccessIssues.filter { $0.kind == .permission }.count }
    var storageHasMore: Bool { storageItems.count < storageTotalMatches }
    var displayedAppSummaries: [AppStorageSummary] {
        var candidates: [String: Int64] = [:]
        for item in items where item.assessment.canBatchSelect && !preferences.isIgnored(item.url) { candidates[ownerResolver.cleanupOwner(item).id, default: 0] += item.bytes }
        let query = storageSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return appSummaries.map { app in var value = app; value.candidateBytes = candidates[app.id] ?? 0; return value }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || L($0.title).localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }
    var reviewGroups: [CleanupAppGroup] {
        Dictionary(grouping: review, by: { ownerResolver.cleanupOwner($0).id }).map { key, files in
            CleanupAppGroup(id: key, title: ownerResolver.cleanupOwner(files[0]).title, items: files)
        }.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }
    var storageBreadcrumbs: [URL] {
        guard let folder = storageFolder, let info = storageInfo,
              let scope = info.roots.filter({ SafetyPolicy.within(folder, $0.url) }).min(by: { $0.url.path.count < $1.url.path.count }) else { return [] }
        var urls: [URL] = [folder], cursor = folder
        while cursor.path != scope.url.path { cursor.deleteLastPathComponent(); urls.insert(cursor, at: 0) }
        return urls
    }
    func loadStorageIndex() {
        let file = storageIndexURL!, home = policy.home
        loadingStorageIndex = FileManager.default.fileExists(atPath: file.path)
        storageQueue.async {
            let apps = InspectionContext.collect().applications
            let volumes = StorageVolumeUsage.collect(home: home)
            do {
                guard FileManager.default.fileExists(atPath: file.path) else {
                    DispatchQueue.main.async { self.storageApplications = apps; self.ownerResolver = StorageOwnerResolver(applications: apps); self.loadingStorageIndex = false }; return
                }
                let index = try StorageIndex(url: file); try index.validateIntegrity(); try index.normalizeAccessIssues(home: home)
                try index.includeAdditionalRoots(StorageRoot.additionalDataRoots)
                if try index.item(at: file)?.bytes != FileStamp.read(file)?.allocated { try index.refresh(urls: [file], applications: apps) }
                let info = try index.info(), summaries = try index.summaries(applications: apps), issues = try index.issues()
                let counted = try index.accountedBytes(onDeviceOf: home), pending = try index.pendingRoots()
                DispatchQueue.main.async {
                    self.loadingStorageIndex = false
                    self.storageApplications = apps; self.ownerResolver = StorageOwnerResolver(applications: apps)
                    self.storageVolumes = volumes; self.storageInfo = info; self.storageCountedBytes = counted; self.storagePendingRoots = pending; self.appSummaries = summaries; self.storageAccessIssues = issues; self.storageIndexUnavailable = false; self.captureGrowth()
                    self.scheduleStorageQuery()
                    self.refreshReconciledStorage()
                    self.storageAutoContinue = true
                    if issues.contains(where: { $0.kind == .permission }) { self.showingStorageIssues = true; self.recheckStorageAccess() }
                    else if !pending.isEmpty { self.scheduleAutomaticStorageContinuation() }
                }
            } catch { DispatchQueue.main.async { self.storageApplications = apps; self.ownerResolver = StorageOwnerResolver(applications: apps); self.storageIndexUnavailable = true; self.loadingStorageIndex = false } }
        }
    }
    func scheduleAutomaticStorageContinuation() {
        guard storageAutoContinue, !storagePendingRoots.isEmpty else { return }
        if busy { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.scheduleAutomaticStorageContinuation() }; return }
        runStorageAnalysis(navigate: false, remainingRoots: storagePendingRoots, automatically: true)
    }
    func continueStorageAnalysis() {
        guard !storagePendingRoots.isEmpty else { return }
        runStorageAnalysis(remainingRoots: storagePendingRoots)
    }
    func analyzeAllStorageLocations(defaultRoots: [StorageRoot]? = nil) {
        guard !busy else { return }
        // The optional roots are the filesystem-scope boundary; the UI uses the
        // real defaults while verification supplies only disposable locations.
        let roots = defaultRoots ?? StorageRoot.defaults(home: policy.home)
        if storageInfo == nil || storageIndexUnavailable {
            runStorageAnalysis(requestedRoots: roots)
            return
        }
        section = .storage; analyzing = true; storageAutoContinue = true
        storageUpdateStatus = "正在补齐扫描范围"
        let token = ScanCancellation(); auditCancellation = token
        let file = storageIndexURL!, apps = storageApplications
        storageQueue.async {
            do {
                let index = try StorageIndex(url: file)
                if !token.isCancelled {
                    try index.prepareAllLocations(including: roots, checkpoint: StorageCheckpoint.current())
                }
                let info = try index.info(), pending = try index.pendingRoots()
                let summaries = try index.summaries(applications: apps), issues = try index.issues()
                DispatchQueue.main.async {
                    self.analyzing = false; self.auditCancellation = nil
                    self.storageInfo = info; self.storagePendingRoots = pending
                    self.appSummaries = summaries; self.storageAccessIssues = issues
                    guard !token.isCancelled && self.storageAutoContinue else {
                        self.storageUpdateStatus = "更新已停止"; return
                    }
                    if pending.isEmpty { self.storageUpdateStatus = "没有需要更新的文件夹"; self.scheduleStorageQuery() }
                    else { self.runStorageAnalysis(navigate: false, remainingRoots: pending, automatically: true) }
                }
            } catch {
                DispatchQueue.main.async {
                    self.analyzing = false; self.auditCancellation = nil
                    self.message = error.localizedDescription
                }
            }
        }
    }
    func runStorageAnalysis(navigate: Bool = true, subtree: URL? = nil, remainingRoots: [StorageRoot]? = nil, automatically: Bool = false, full: Bool = false, requestedRoots: [StorageRoot]? = nil) {
        guard !analyzing, !mutating, !loadingReport, !showingReview else { return }
        if requestedRoots == nil && subtree == nil && remainingRoots == nil && storageInfo != nil && !storageIndexUnavailable {
            prepareIncrementalAnalysis(navigate: navigate, forceFull: full); return
        }
        if !automatically { storageAutoContinue = true }
        if navigate { section = .storage }
        analyzing = true; storageProgress = StorageAuditProgress()
        let cancellation = ScanCancellation(); auditCancellation = cancellation
        let indexURL = storageIndexURL!, fixtureHome = policy.home
        let mergeExisting = (subtree != nil || remainingRoots != nil) && storageInfo != nil && !storageIndexUnavailable
        let ownershipRoots = mergeExisting ? storageInfo?.roots ?? [] : []
        storageQueue.async {
            let apps = InspectionContext.collect(home: fixtureHome).applications
            var roots = remainingRoots ?? requestedRoots ?? StorageRoot.defaults(home: fixtureHome)
            var seen = Set<String>()
            roots = roots.filter { seen.insert($0.url.path).inserted }
            if let subtree { roots = [ownershipRoots.first { $0.url.path == subtree.path } ?? StorageRoot(url: subtree, title: subtree.lastPathComponent, kind: subtree.pathComponents.contains("Caches") || subtree.pathComponents.contains("Logs") ? .cache : .appData)] }
            let staging = indexURL.deletingLastPathComponent().appendingPathComponent("subtree-" + UUID().uuidString + ".sqlite")
            defer { if mergeExisting { try? FileManager.default.removeItem(at: staging) } }
            do {
                let result = try StorageIndex.build(at: mergeExisting ? staging : indexURL, roots: roots, auditor: StorageAuditor(home: fixtureHome), applications: apps, cancellation: cancellation, ownershipRoots: ownershipRoots) { update in DispatchQueue.main.async { self.storageProgress = update } }
                if mergeExisting, let subtree {
                    let current = try StorageIndex(url: indexURL), fresh = try StorageIndex(url: staging)
                    try current.merge(subtree: subtree, from: fresh)
                } else if mergeExisting, remainingRoots != nil {
                    let current = try StorageIndex(url: indexURL), fresh = try StorageIndex(url: staging)
                    try current.mergePending(from: fresh)
                }
                let index = try StorageIndex(url: indexURL)
                try index.normalizeAccessIssues(home: fixtureHome)
                let info = try index.info(), summaries = try index.summaries(applications: apps), issues = try index.issues()
                let counted = try index.accountedBytes(onDeviceOf: fixtureHome), pending = try index.pendingRoots()
                DispatchQueue.main.async {
                    self.storageApplications = apps; self.ownerResolver = StorageOwnerResolver(applications: apps)
                    self.storageResult = result; self.storageInfo = info; self.storageCountedBytes = counted; self.storagePendingRoots = pending; self.appSummaries = summaries; self.storageAccessIssues = issues; self.captureGrowth()
                    self.analyzing = false; self.auditCancellation = nil; self.storageIndexUnavailable = false
                    self.storageUpdateStatus = result.cancelled ? "更新已停止" : pending.isEmpty ? "更新完成" : "正在接续更新"
                    self.scheduleStorageQuery()
                    if self.shouldRecheckAccessOnActivation {
                        self.recheckStorageAccess()
                    } else if self.storageAutoContinue && !result.cancelled && !pending.isEmpty {
                        DispatchQueue.main.async { self.scheduleAutomaticStorageContinuation() }
                    } else if !result.cancelled && issues.contains(where: { $0.kind == .permission }) {
                        self.storageAccessStatus = "已扫描可读取位置；剩余位置请查看访问状态"
                        self.showingStorageIssues = true
                    }
                }
            } catch { let reason = error.localizedDescription; DispatchQueue.main.async { self.analyzing = false; self.auditCancellation = nil; self.message = reason; self.storageIndexUnavailable = self.storageInfo == nil } }
        }
    }
    func prepareIncrementalAnalysis(navigate: Bool, forceFull: Bool = false) {
        guard !busy else { return }
        if navigate { section = .storage }
        analyzing = true; storageAutoContinue = true; storageUpdateStatus = "正在检查变化"
        let token = ScanCancellation(); auditCancellation = token
        let file = storageIndexURL!, home = policy.home
        storageQueue.async {
            do {
                let index = try StorageIndex(url: file)
                let info = try index.info(), cursor = StorageCheckpoint.current()
                if try index.pendingRoots().isEmpty {
                    let changes = forceFull ? nil : StorageJournal.changes(since: try index.checkpoint(), roots: info.roots, home: home)
                    if token.isCancelled { DispatchQueue.main.async { self.analyzing = false; self.auditCancellation = nil; self.storageUpdateStatus = "更新已停止" }; return }
                    try index.prepareRefresh(changes: changes, checkpoint: cursor)
                    DispatchQueue.main.async { self.storageUpdateStatus = changes == nil ? "变更记录不可用，正在完整检查" : "正在更新变化的文件夹" }
                }
                let pending = try index.pendingRoots(), updated = try index.info()
                DispatchQueue.main.async {
                    self.analyzing = false; self.auditCancellation = nil; self.storageInfo = updated; self.storagePendingRoots = pending
                    guard !token.isCancelled && self.storageAutoContinue else { self.storageUpdateStatus = "更新已停止"; return }
                    if pending.isEmpty { self.storageUpdateStatus = "没有需要更新的文件夹"; self.scheduleStorageQuery() }
                    else { self.runStorageAnalysis(navigate: false, remainingRoots: pending, automatically: true) }
                }
            } catch { DispatchQueue.main.async { self.analyzing = false; self.auditCancellation = nil; self.message = error.localizedDescription } }
        }
    }
    func scheduleStorageQuery() {
        storageDebounce?.cancel(); storageQueryGeneration += 1
        let generation = storageQueryGeneration
        let work = DispatchWorkItem { Task { @MainActor in if self.storageQueryGeneration == generation { self.queryStoragePage(append: false) } } }
        storageDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (storageSearch.isEmpty ? 0 : 0.25), execute: work)
    }
    func queryStoragePage(append: Bool) {
        guard storageInfo != nil, !analyzing else { return }
        let generation = storageQueryGeneration, file = storageIndexURL!, folder = storageFolder, owner = storageOwnerFilter, query = storageSearch, ordering = storageOrdering
        let aliases = Localization.catalog.sourceTitles(matchingEnglish: query, language: .current)
        let offset = append ? storageItems.count : 0
        queryingStorage = true
        storageQueue.async {
            do {
                let page = try StorageIndex(url: file).page(parent: folder, ownerID: owner, search: query, searchOwnerTitles: aliases, ordering: ordering, offset: offset)
                DispatchQueue.main.async {
                    guard generation == self.storageQueryGeneration else { return }
                    if append { self.storageItems.append(contentsOf: page.items) } else { self.storageItems = page.items }
                    self.storageTotalMatches = page.total; self.queryingStorage = false
                }
            } catch { DispatchQueue.main.async { guard generation == self.storageQueryGeneration else { return }; self.queryingStorage = false; self.storageIndexUnavailable = true } }
        }
    }
    func browseStorage(_ url: URL?, owner: AppStorageSummary? = nil) {
        storageTrail.append(storageLocation)
        if let owner { storageOwnerFilter = owner.id; storageOwnerTitle = owner.title }
        storageMode = .folders; storageFolder = url; storageSearch = ""; storageItems = []; storageTotalMatches = 0; scheduleStorageQuery()
    }
    func browseAllStorage() {
        storageTrail.append(storageLocation); storageOwnerFilter = nil; storageOwnerTitle = nil; storageMode = .folders; storageFolder = nil; storageSearch = ""; storageItems = []; storageTotalMatches = 0; scheduleStorageQuery()
    }
    func showAppCleanup(_ app: AppStorageSummary) {
        guard !busy else { return }
        let maintenance = ["Downloads", "Library/Caches", "Library/Logs"].map { policy.home.appendingPathComponent($0) }
        let covered = currentScanConfiguration.map { config in config.minimumBytes <= 1_000_000 && maintenance.allSatisfy { location in config.roots.contains { SafetyPolicy.within(location, $0) } } } ?? false
        if !covered { quickScan() }
        showDisposition(nil); cleanupOwnerFilter = app.id; cleanupOwnerTitle = app.title
        selectCleanupScope(scopeItems(.recommended).isEmpty ? .optional : .recommended); section = .results
    }
    func rescanCleanupOwner() {
        let owner = cleanupOwnerFilter, title = cleanupOwnerTitle
        guard !busy else { return }
        quickScan(); cleanupOwnerFilter = owner; cleanupOwnerTitle = title; section = .results
    }
    func clearCleanupOwner() { cleanupOwnerFilter = nil; cleanupOwnerTitle = nil; showDisposition(nil); selectCleanupScope(.recommended) }
    func removeReviewGroup(_ group: CleanupAppGroup) {
        let paths = Set(group.items.map(\.id)); review.removeAll { paths.contains($0.id) }; selected.subtract(paths);workbench.unselect(paths)
    }
    func refreshStorageIndex(paths: [URL]) {
        guard !paths.isEmpty, storageInfo != nil else { return }
        let file = storageIndexURL!, apps = storageApplications, home = policy.home
        storageQueue.async {
            do {
                let index = try StorageIndex(url: file); try index.refresh(urls: paths, applications: apps)
                let summaries = try index.summaries(applications: apps), counted = try index.accountedBytes(onDeviceOf: home)
                DispatchQueue.main.async { self.storageCountedBytes = counted; self.appSummaries = summaries; self.scheduleStorageQuery() }
            } catch { DispatchQueue.main.async { self.storageIndexUnavailable = true } }
        }
    }
    func inspectCleanupFolder(_ url: URL) {
        guard !busy, policy.permits(url), policy.hasNoSymlinkComponents(url) else { return }
        scan(roots: [url], label: url.lastPathComponent, minimum: 0)
        selectCleanupScope(.protected); section = .results
    }
    func chooseStorageFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = L("选择要分析的文件夹"); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = L("分析文件夹")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The selected scope is read-only and never changes cleanup eligibility.
        runStorageAnalysis(subtree: url)
    }
    func openFileAccessSettings() {
        shouldRecheckAccessOnActivation = true
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }
    func recheckStorageAccess() {
        guard !accessCheckRunning, !analyzing, !mutating else { return }
        shouldRecheckAccessOnActivation = false
        accessCheckRunning = true
        let issues = storageAccessIssues, indexURL = storageIndexURL!, home = policy.home
        storageQueue.async {
            let fullAccess = StoragePermissionStatus.fullDiskAccess(home: home)
            let protectedProbes = StoragePermissionStatus.protectedProbes(home: home)
            var remaining: [StorageAccessIssue] = [], readable: [URL] = []
            for issue in issues {
                if issue.kind == .incomplete { remaining.append(issue); continue }
                if protectedProbes.contains(issue.url), StoragePermissionStatus.readProbe(issue.url) != true {
                    remaining.append(StorageAccessIssue(url: issue.url, root: issue.root, kind: .permission, detail: "完全磁盘访问试读仍被拒绝，请开启当前版本的轻扫后重新检查。")); continue
                }
                if let problem = StorageAccessProbe.problem(at: issue.url, root: issue.root) { remaining.append(StoragePermissionStatus.classified(problem, fullAccess: fullAccess, home: home)) }
                else { readable.append(issue.url) }
            }
            do {
                let index = try StorageIndex(url: indexURL)
                try index.recordAccessCheck(remaining: remaining, readable: readable)
                let issues = try index.issues(), info = try index.info(), pending = try index.pendingRoots()
                DispatchQueue.main.async {
                    self.storageAccessIssues = issues; self.storageInfo = info; self.accessCheckRunning = false
                    self.storagePendingRoots = pending
                    self.storageAccessStatus = readable.isEmpty ? (issues.contains(where: { $0.kind == .permission }) ? "仍有位置无法读取，请检查权限、磁盘连接或系统限制" : "访问检查完成") : "访问已恢复，正在补扫"
                    if !readable.isEmpty && !pending.isEmpty { self.showingStorageIssues = false; self.storageAutoContinue = true; self.scheduleAutomaticStorageContinuation() }
                    else if !pending.isEmpty && self.storageAutoContinue { self.scheduleAutomaticStorageContinuation() }
                }
            } catch { DispatchQueue.main.async { self.accessCheckRunning = false; self.storageIndexUnavailable = true; self.message = "访问检查已完成，空间索引需要重建" } }
        }
    }
}
