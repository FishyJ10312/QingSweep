import Foundation
import AppKit

struct FixtureEnvironment16: CleanupApplicationEnvironment {
    func usage(for items: [ScanItem]) async throws -> CleanupUsage { CleanupUsage() }
    func requestQuit(_ app: CleanupApplication) -> Bool { false }
}
@main struct Release16Tests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: "/Users/Shared").appendingPathComponent("qingsweep-release16-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) {
            guard (try? value()) == true else { fputs("FAIL: \(message)\n",stderr); exit(1) }
            checks += 1; print("PASS: \(message)")
        }
        @discardableResult func file(_ name: String, size: Int = 8192) throws -> URL {
            let url = home.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x31, count: size).write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -12 * 86400)], ofItemAtPath: url.path)
            return url
        }
        let movies = home.appendingPathComponent("Movies")
        let changed = try file("Movies/changed/a.mov"), kept = try file("Movies/unchanged/b.mov")
        let root = StorageRoot(url: movies, title: "素材", kind: .project)
        let db = home.appendingPathComponent("index.sqlite"), stage = home.appendingPathComponent("stage.sqlite")
        _ = try StorageIndex.build(at: db, roots: [root], auditor: StorageAuditor(home: home), applications: [], cancellation: ScanCancellation())
        let index = try StorageIndex(url: db)
        check(try index.checkpoint() != nil, "initial scan saves an OS journal checkpoint")
        check(try index.rows("SELECT SUM(length(search_key)) < SUM(length(path)) FROM nodes").first?.first == "1", "search index avoids duplicating full paths")
        check(try index.page(search: "unchanged/b.mov").total == 1, "path search still covers canonical paths")
        let original = try index.item(at: kept)!
        _ = try file("Movies/changed/a.mov", size: 24576)
        try index.prepareRefresh(changes: [changed.deletingLastPathComponent()], checkpoint: .current())
        let jobs = try index.pendingRoots()
        check(jobs.count == 1 && jobs[0].url == changed.deletingLastPathComponent(), "incremental scan queues only the changed subtree")
        _ = try StorageIndex.build(at: stage, roots: jobs, auditor: StorageAuditor(home: home), applications: [], cancellation: ScanCancellation(), ownershipRoots: [root])
        try index.mergePending(from: StorageIndex(url: stage))
        check(try index.item(at: changed)?.bytes == FileStamp.read(changed)?.allocated, "incremental scan replaces changed file metadata")
        check(try index.item(at: kept)?.bytes == original.bytes, "unchanged subtree preserves its known metadata")
        try fm.removeItem(at: changed); let added = try file("Movies/changed/new.mov")
        try index.prepareRefresh(changes: [changed.deletingLastPathComponent()], checkpoint: .current())
        _ = try StorageIndex.build(at: stage, roots: index.pendingRoots(), auditor: StorageAuditor(home: home), applications: [], cancellation: ScanCancellation(), ownershipRoots: [root])
        try index.mergePending(from: StorageIndex(url: stage))
        check(try index.item(at: changed) == nil && index.item(at: added) != nil, "incremental scan reconciles removals and additions")
        check(try index.prepareRefresh(changes: [], checkpoint: .current()) == 0 && index.pendingRoots().isEmpty, "unchanged snapshot schedules no recursive scan")
        check(try index.prepareRefresh(changes: nil, checkpoint: .current()) == 1, "missing journal falls back to complete original scopes")
        let cursor = try index.checkpoint()!.eventID
        try index.prepareRefresh(changes: [], checkpoint: .current())
        check(try index.checkpoint()!.eventID == cursor && index.pendingRoots().count == 1, "pending scans retain their start checkpoint")
        try index.recordAccessCheck(remaining: index.issues(), readable: [])
        check(try index.pendingRoots().count == 1, "permission recheck preserves already queued incremental work")
        let replayCursor = StorageCheckpoint.current()
        _ = try file("Movies/changed/journal.mov")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let replay = StorageJournal.changes(since: replayCursor, roots: [root], home: home)
        check(replay == nil || replay!.contains { SafetyPolicy.within(added, $0) || SafetyPolicy.within($0, movies) }, "OS event replay reports the change or safely requests a full scan")
        print("Journal replay:", replay?.map(\.path) as Any)
        let unknown = StorageCheckpoint(eventID: .max, volumes: [])
        check(StorageJournal.changes(since: unknown, roots: [root], home: home) == nil, "invalid event cursor cannot skip files")

        let migrationURL = home.appendingPathComponent("v1.sqlite")
        try fm.copyItem(at: db, to: migrationURL)
        do { let legacy = try StorageIndex(url: migrationURL); try legacy.execute("UPDATE nodes SET search_key=title || ' ' || path || ' ' || owner_title; PRAGMA user_version=1;") }
        let migrated = try StorageIndex(url: migrationURL)
        check(try migrated.rows("PRAGMA user_version").first?.first == "2" && migrated.page(search: "new.mov").total == 1, "v1 index migrates while retaining every searchable file")
        check(try migrated.rows("SELECT SUM(length(search_key)) < SUM(length(path)) FROM nodes").first?.first == "1", "migration removes duplicated path text")
        let updateModel = AppModel(home: home, loadSavedScan: false, startTimer: false)
        updateModel.storageIndexURL = db; updateModel.storageInfo = try index.info(); updateModel.storagePendingRoots = try index.pendingRoots()
        updateModel.continueStorageAnalysis()
        for _ in 0..<200 { if !updateModel.analyzing && updateModel.storagePendingRoots.isEmpty { break }; try await Task.sleep(nanoseconds: 30_000_000) }
        check(!updateModel.analyzing && updateModel.storageUpdateStatus == "更新完成", "completed update cannot keep a running status label")
        let policy = SafetyPolicy(home: home), classifier = FileClassifier(policy: policy, context: InspectionContext())
        let firefox = try file("Library/Caches/Firefox/Profiles/test.default/cache2/entries/" + String(repeating: "A", count: 40))
        let fx = classifier.assess(firefox, stamp: FileStamp.read(firefox)!)
        check(fx.ruleID == "cache-firefox" && fx.disposition == .conditional && fx.blockingAppIDs == ["org.mozilla.firefox"], "Firefox rule is scoped to cache entry format and process checks")
        let session = try file("Library/Caches/Firefox/Profiles/test.default/sessionstore.jsonlz4")
        check(!classifier.assess(session, stamp: FileStamp.read(session)!).canBatchSelect, "Firefox sessions never inherit the cache rule")
        let render = try file("Movies/CacheClip/abc/render.dvcc")
        let proxy = try file("Movies/ProxyMedia/clip.mov")
        let project = try file("Documents/Projects/film.drp")
        check(classifier.assess(render, stamp: FileStamp.read(render)!).ruleID == "resolve-render-cache", "render cache has a specific purpose and effect")
        check(classifier.assess(proxy, stamp: FileStamp.read(proxy)!).requiresIndividualConfirmation, "proxy classification still requires manual confirmation")
        check(classifier.assess(project, stamp: FileStamp.read(project)!).category == .project, "project priority survives expanded cleanup rules")
        let projectItem = ScanItem(url: project, root: home.appendingPathComponent("Documents"), stamp: FileStamp.read(project)!, assessment: classifier.assess(project, stamp: FileStamp.read(project)!))
        check(StorageOwnerResolver(applications: []).cleanupOwner(projectItem).id.hasPrefix("personal:"), "identified personal files do not appear as unidentified app resources")
        let availableProbe = try file("permission-probe")
        let absentProbe = home.appendingPathComponent("absent-permission-probe")
        check(StoragePermissionStatus.fullDiskAccess(home: home, probes: [absentProbe,availableProbe]) == true, "permission probe falls back when the user-level location is absent")
        check(StoragePermissionStatus.fullDiskAccess(home: home, probes: [absentProbe]) == nil, "missing probe locations do not falsely claim permission denial")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: availableProbe.path)
        check(StoragePermissionStatus.fullDiskAccess(home: home, probes: [availableProbe]) == false, "permission read failure is verified by an actual failed open")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: availableProbe.path)
        let protectedFile = try file("Library/Application Support/com.apple.TCC/TCC.db")
        let permissionDB = home.appendingPathComponent("permission-state.sqlite")
        let permissionScope = StorageRoot(url: home.appendingPathComponent("Library/Application Support"), title: "应用数据", kind: .appData)
        _ = try StorageIndex.build(at: permissionDB, roots: [permissionScope], auditor: StorageAuditor(home: home), applications: [], cancellation: ScanCancellation())
        let permissionIndex = try StorageIndex(url: permissionDB)
        let protectedIssue = StorageAccessIssue(url: protectedFile, root: permissionScope.url, kind: .permission, detail: "fixture denial")
        try permissionIndex.recordAccessCheck(remaining: [protectedIssue], readable: [])
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: protectedFile.path)
        let permissionModel = AppModel(home: home, loadSavedScan: false, startTimer: false)
        permissionModel.storageIndexURL = permissionDB; permissionModel.storageInfo = try permissionIndex.info(); permissionModel.storageAccessIssues = [protectedIssue]
        permissionModel.recheckStorageAccess()
        for _ in 0..<200 { if !permissionModel.accessCheckRunning { break }; try await Task.sleep(nanoseconds: 30_000_000) }
        check(permissionModel.storageAccessIssues.contains { $0.kind == .permission } && permissionModel.storagePendingRoots.isEmpty, "metadata access cannot falsely restore a denied protected read")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: protectedFile.path)
        let fakeSystem = StorageAccessIssue(url: URL(fileURLWithPath: "/private/var/locked"), root: URL(fileURLWithPath: "/private"), kind: .permission, detail: "fixture")
        check(StoragePermissionStatus.classified(fakeSystem, fullAccess: true, home: home).kind == .restricted, "verified FDA separates system restrictions from authorization")
        check(StoragePermissionStatus.classified(fakeSystem, fullAccess: false, home: home).kind == .permission, "unverified permission remains actionable")
        let fakeUser = StorageAccessIssue(url: movies, root: home, kind: .permission, detail: "fixture")
        check(StoragePermissionStatus.classified(fakeUser, fullAccess: true, home: home).kind == .permission, "user directory denial is never hidden as a system restriction")

        let model = AppModel(home: home, loadSavedScan: false, startTimer: false)
        model.cleanupEnvironment = FixtureEnvironment16()
        var entries: [ScanItem] = []
        for n in 0..<205 {
            let url = try file("Downloads/manual-\(n).mov")
            entries.append(ScanItem(url: url, root: home.appendingPathComponent("Downloads"), stamp: FileStamp.read(url)!, assessment: classifier.assess(url, stamp: FileStamp.read(url)!)))
        }
        let catalogURL = home.appendingPathComponent("cleanup-catalog.sqlite")
        let archived = ScanArchive(scannedAt: Date(), label: "全部素材", result: ScanResult(items: entries), configuration: ScanConfiguration(roots: [home.appendingPathComponent("Downloads")], label: "全部素材", minimumBytes: 0))
        try CleanupCatalog.save(archived, to: catalogURL)
        let catalog = try CleanupCatalog(url: catalogURL)
        check(try catalog.page(offset: 200).count == 5 && catalog.archive().result.items.count == 205, "complete catalog persists every row and reads later pages")
        check(try catalog.archive().configuration?.minimumBytes == 0, "catalog preserves exact cleanup scope and threshold")
        let brokenCatalog = home.appendingPathComponent("broken-catalog.sqlite")
        try Data([0x11,0x22]).write(to: brokenCatalog)
        do { _ = try CleanupCatalog(url: brokenCatalog); check(false, "corrupt cleanup catalog rejected") } catch { check(true, "corrupt cleanup catalog rejected") }
        model.items = entries; model.selectCleanupScope(.protected); model.presentation = .files
        check(model.selected.isEmpty && model.filtered.count == 205 && model.displayedCleanupFiles.count == 100, "full result count and visible page are separate; media starts deselected")
        model.loadMoreCleanup(); check(model.displayedCleanupFiles.count == 200, "next page adds 100 rows without dropping earlier items")
        model.toggleVisible(); check(model.selectedItems.count == 205, "select all covers the full current filter, including unloaded rows")
        model.search = "manual-204.mov"; check(model.displayedCleanupFiles.count == 1 && model.selectedItems.count == 205, "search resets the page while preserving manual choices")
        model.search = ""; model.selected.removeAll()
        model.preview(entries[0].url); check(model.previewURL == entries[0].url && model.selected.isEmpty, "preview does not select or delete media")
        let link = home.appendingPathComponent("Downloads/link.mov"); try fm.createSymbolicLink(at: link, withDestinationURL: entries[0].url)
        model.previewURL = nil; model.preview(link); check(model.previewURL == nil, "preview refuses symlink targets")
        model.message = nil
        let first = entries[0], second = entries[1]
        model.toggle(first, on: true); model.toggle(second, on: true); model.prepareReview(); model.requestReviewedMove()
        check(model.showingManualConfirmation && !model.mutating && fm.fileExists(atPath: first.url.path), "manual selection cannot bypass second confirmation")
        model.manualReviewAcknowledged = true; model.confirmManualCleanup()
        for _ in 0..<200 { if !model.mutating { break }; try await Task.sleep(nanoseconds: 30_000_000) }
        check(model.history.count == 2 && model.cleanupReceipts.count == 1, "confirmed fixture move records files and one operation receipt")
        check(model.history.allSatisfy { $0.batchID == model.cleanupReceipts[0].id }, "moved files share a persisted operation identity")
        check(model.cleanupReceipts[0].movedCount == 2 && model.cleanupReceipts[0].requestedCount == 2, "receipt distinguishes requested and completed counts")
        model.message = nil; model.refresh()
        for _ in 0..<200 { if !model.sampling { break }; try await Task.sleep(nanoseconds: 30_000_000) }
        let batch = model.historyBatches[0]
        check(model.restorableRecords(in: batch).count == 2, "batch restoration validates current Trash identities")
        try Data([0x77]).write(to: first.url)
        model.restoreBatch(batch.records)
        for _ in 0..<200 { if !model.mutating { break }; try await Task.sleep(nanoseconds: 30_000_000) }
        let occupiedData = try Data(contentsOf: first.url)
        check(model.history.count == 1 && occupiedData == Data([0x77]), "batch restore skips occupied originals without overwriting them")
        try fm.removeItem(at: first.url); model.message = nil; model.restoreBatch(model.history)
        for _ in 0..<200 { if !model.mutating { break }; try await Task.sleep(nanoseconds: 30_000_000) }
        check(model.history.isEmpty && fm.fileExists(atPath: first.url.path) && fm.fileExists(atPath: second.url.path), "batch restore returns every remaining fixture and preserves receipt")
        let reloaded = AppModel(home: home, loadSavedScan: false, startTimer: false)
        check(reloaded.cleanupReceipts.count == 1 && reloaded.history.isEmpty, "batch receipt survives restart after recovery")
        check(ScanConfiguration(roots: [movies], label: "Movies", minimumBytes: 0).isValid(policy: policy), "zero-byte threshold scopes survive restart")
        let lifecycle = QingSweepApplicationDelegate(); lifecycle.model = model
        model.showingStorageIssues = true
        check(lifecycle.applicationShouldTerminate(NSApplication.shared) == .terminateNow, "access assistant does not prevent a normal macOS Quit")
        model.showingStorageIssues = false; model.mutating = true
        var didReply = false; lifecycle.terminationReplyForTesting = { didReply = $0 }
        let decision = lifecycle.applicationShouldTerminate(NSApplication.shared)
        check(decision == .terminateLater && !didReply, "Quit waits for active file operations to persist their results")
        model.mutating = false
        for _ in 0..<50 { if didReply { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        check(didReply, "Quit resumes after the file-operation completion boundary")
        print("\(checks) release 1.6 checks passed; only temporary fixture files moved and restored")
    }
}
