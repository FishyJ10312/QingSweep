import AppKit
import Foundation

@main struct ScopeAndReviewTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: "/Users/Shared").appendingPathComponent("qingsweep-workflow-" + UUID().uuidString)
        defer { try? fm.removeItem(at: directory) }
        var checks = 0

        func check(_ description: String, _ passed: Bool) throws {
            guard passed else { throw Failure(description: description) }
            checks += 1
            print("PASS: " + description)
        }
        func wait(_ name: String, until finished: () -> Bool) async throws {
            let limit = Date().addingTimeInterval(45)
            while !finished() && Date() < limit { try await Task.sleep(nanoseconds: 20_000_000) }
            guard finished() else { throw Failure(description: "Timed out waiting for " + name) }
        }
        func fixture(_ relativePath: String, bytes: Int = 1_024_000, old: Bool = true) throws -> URL {
            let url = directory.appendingPathComponent(relativePath)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x63, count: bytes).write(to: url)
            if old { try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -20 * 86400)], ofItemAtPath: url.path) }
            return url
        }

        let video = try fixture("Downloads/Clip.mov")
        let project = try fixture("Downloads/Edit.drp")
        let log = try fixture("Library/Logs/Example/old-session.log")
        let unknown = try fixture("Library/Caches/Example/unknown.data", bytes: 4096)
        let oldWheels = try (0..<4).map { try fixture("Library/Caches/pip/wheels/old\($0)-1-py3-none-any.whl", bytes: 524288) }
        let newWheel = try fixture("Library/Caches/pip/wheels/new-1-py3-none-any.whl", bytes: 524288, old: false)
        let wheels = oldWheels[0].deletingLastPathComponent()
        let downloads = video.deletingLastPathComponent()
        let model = AppModel(home: directory, loadSavedScan: false, startTimer: false)

        model.quickScan()
        try await wait("common scan") { !model.scanning }
        let recommendationIDs = Set(model.scopeItems(.recommended).map(\.id))
        try check("known small caches are grouped in common cleanup", recommendationIDs == Set(oldWheels.map(\.path)) && model.groups.count == 1)
        try check("recent or unidentified small caches stay out of recommendations", !model.items.contains { $0.id == newWheel.path || $0.id == unknown.path })
        let creative = model.scopeItems(.protected)
        try check("video and project classify as manual and start unchecked", Set(creative.map(\.id)) == Set([video.path, project.path]) && model.selected.isEmpty)
        try check("recommended group includes the full allocated total", model.groups.first?.bytes == 2_097_152)
        guard let logItem = model.items.first(where: { $0.id == log.path }) else { throw Failure(description: "Expected cleanup log") }
        model.selectCleanupScope(.optional)
        model.toggle(logItem, on: true)
        let completedDate = model.scannedAt
        let completedScope = model.currentScanConfiguration
        model.analyzeStorageFolder(downloads)
        try await wait("selected folder index") { !model.analyzing }
        try check("new chosen analysis records exactly the chosen root", model.storageInfo?.roots.map(\.url.path) == [downloads.path] && model.storageScanScope == .selectedFolders)
        guard let owner = model.appSummaries.first(where: { $0.id.hasPrefix("personal:") }) else { throw Failure(description: "Expected a personal-folder card") }
        let index = try StorageIndex(url: model.storageIndexURL)
        guard let projectEntry = try index.item(at: project) else { throw Failure(description: "Expected indexed project") }
        model.browseStorage(downloads, owner: owner)
        model.storageSearch = "Clip"
        model.showAppCleanup(owner)
        try await wait("application handoff") { !model.scanning }
        try check("application cleanup respects the indexed folder and excludes unrelated logs", Set(model.cleanupItems.map(\.id)) == Set([video.path, project.path]))
        try check("application cleanup chooses the first populated category", model.cleanupScope == .protected && model.filtered.count == 2)
        try check("scoped scan keeps the saved global list and prior explicit selections", model.currentScanConfiguration == completedScope && model.scannedAt == completedDate && Set(model.selectedItems.map(\.id)) == [log.path])
        guard let videoItem = model.cleanupItems.first(where: { $0.id == video.path }) else { throw Failure(description: "Expected video candidate") }
        model.toggle(videoItem, on: true)
        model.prepareCurrentReview()
        try check("current-scope review contains only the explicitly chosen video", model.review.map(\.id) == [video.path])
        model.showingReview = false
        model.prepareReview()
        try check("global review includes both scopes exactly once", Set(model.review.map(\.id)) == Set([video.path, log.path]) && model.review.count == 2)
        model.requestReviewedMove()
        try check("mixed review requires a manual acknowledgment", model.showingManualConfirmation && !model.manualReviewAcknowledged && model.manualReviewItems.map(\.id) == [video.path])
        model.showingReview = false
        model.returnCleanup()
        try check("back restores the same storage folder and search", model.section == .storage && model.storageFolder?.path == downloads.path && model.storageSearch == "Clip")

        model.addIndexedFileForReview(projectEntry)
        try await wait("index detail action") { !model.addingIndexedFile }
        try check("direct addition queues only the clicked project without replacing the report", model.selectedItems.count == 3 && model.selectedItems.contains { $0.id == project.path } && model.currentScanConfiguration == completedScope)
        try check("adding a file leaves the same storage view and query", model.section == .storage && model.storageSearch == "Clip")
        model.prepareReview()
        try check("directly added project still requires manual confirmation", Set(model.manualReviewItems.map(\.id)) == Set([video.path, project.path]))
        model.removeReviewedItem(model.manualReviewItems.first { $0.id == project.path }!)
        try check("deselect from review removes the direct entry", !model.selectedItems.contains { $0.id == project.path })
        model.showingReview = false

        model.inspectCleanupFolder(wheels)
        try await wait("cleanup by folder") { !model.scanning }
        try check("folder inspection lands on known recommendations, with a return path", model.cleanupScope == .recommended && Set(model.filtered.map(\.id)) == recommendationIDs && model.canReturnCleanup)
        try check("entering a different folder keeps earlier hand selections", Set(model.selectedItems.map(\.id)) == Set([video.path, log.path]))
        model.returnCleanup()

        model.analyzeStorageFolder(wheels)
        try await wait("second chosen storage scope") { !model.analyzing }
        let added = try fixture("Library/Caches/pip/wheels/added-1-py3-none-any.whl")
        model.smartScan()
        try check("combined scan starts cleanup and existing storage update", model.scanning && model.analyzing)
        try await wait("combined scan and continuation") { !model.scanning && !model.analyzing && model.storagePendingRoots.isEmpty }
        let updatedIndex = try StorageIndex(url: model.storageIndexURL)
        try check("combined rescan sees the new cache on both pages", model.items.contains { $0.id == added.path } && (try updatedIndex.item(at: added)) != nil)
        try check("combined update keeps the user's storage folder", model.storageInfo?.roots.map(\.url.path) == [wheels.path])
        model.selectCleanupScope(.recommended)
        model.selectPriority()
        let previousSelection = model.selected
        let previousPaths = model.items.map(\.id)
        let previousTime = model.scannedAt
        model.rescan()
        model.cancelScan()
        try await wait("cancelled cleanup") { !model.scanning }
        try check("stopping retains the previous cleanup list, timestamp, and selection", !previousSelection.isEmpty && model.selected == previousSelection && model.items.map(\.id) == previousPaths && model.scannedAt == previousTime && model.stoppedCleanupScan != nil)
        let catalogURL = model.storageIndexURL.deletingLastPathComponent().appendingPathComponent("cleanup-catalog.sqlite")
        let saved = try CleanupCatalog(url: catalogURL).archive()
        try check("stopping does not replace the saved complete report", !saved.result.cancelled && Set(saved.result.items.map(\.id)) == Set(previousPaths))
        let reopened = AppModel(home: directory, loadSavedScan: true, startTimer: false)
        try await wait("load chosen scope") { !reopened.loadingStorageIndex && !reopened.loadingReport }
        try check("reopening a chosen scope adds no system directories", reopened.storageInfo?.roots.map(\.url.path) == [wheels.path] && reopened.storagePendingRoots.isEmpty && reopened.storageScanScope == .selectedFolders)
        try updatedIndex.execute("DELETE FROM metadata WHERE key='scope'")
        let legacy = AppModel(home: directory, loadSavedScan: true, startTimer: false)
        try await wait("load older scope") { !legacy.loadingStorageIndex && !legacy.loadingReport }
        try check("older narrow reports keep their on-disk scope", legacy.storageInfo?.roots.map(\.url.path) == [wheels.path] && legacy.storagePendingRoots.isEmpty)
        try check("restart never preselects personal media", reopened.selected.isEmpty && legacy.selected.isEmpty)

        let trashed = try fixture(".Trash/restore-example.bin", bytes: 8192)
        let original = directory.appendingPathComponent("Downloads/restore-example.bin")
        let trash = trashed.deletingLastPathComponent()
        let record = TrashRecord(id: UUID(), original: original, trashed: trashed, bytes: 8192, date: Date(), stamp: FileStamp.read(trashed))
        model.history = [record]
        func refreshHistory() async throws {
            try await wait("previous history refresh") { !model.sampling }
            model.refresh()
            try await wait("history refresh") { !model.sampling }
        }
        try await refreshHistory()
        try check("readable Trash record is available", model.restoreStates[record.id] == .available)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: trash.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: trash.path) }
        try await refreshHistory()
        try check("access denied is distinct from a missing Trash file", model.restoreStates[record.id] == .permission && model.recoverable.isEmpty)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: trash.path)
        try await refreshHistory()
        try check("recheck recovers permission without losing the file", model.restoreStates[record.id] == .available)
        try Data("conflict".utf8).write(to: original)
        try await refreshHistory()
        try check("restoration preserves an occupied destination", model.restoreStates[record.id] == .occupied && model.recoverable.isEmpty)
        try fm.removeItem(at: original)
        try await refreshHistory()
        model.restore(record)
        try await wait("restore") { !model.mutating }
        try check("restored fixture is byte-identical", model.operationOutcome?.completed == 1 && (try Data(contentsOf: original)) == Data(repeating: 0x63, count: 8192))
        try check("a missing Trash file on a readable volume is reported missing", RestoreAvailability.check(record: TrashRecord(id: UUID(), original: directory.appendingPathComponent("Downloads/missing"), trashed: trashed, bytes: 8192, date: Date(), stamp: record.stamp), policy: model.policy) == .missing)
        let offline = URL(fileURLWithPath: "/Volumes/QingSweep-test-" + UUID().uuidString).appendingPathComponent(".Trashes/\(getuid())/item")
        let offlineRecord = TrashRecord(id: UUID(), original: directory.appendingPathComponent("Downloads/offline"), trashed: offline, bytes: 8192, date: Date(), stamp: record.stamp)
        try check("an unavailable external mount has its own recovery state", RestoreAvailability.check(record: offlineRecord, policy: model.policy) == .disconnected)
        try check("original project and media bytes unchanged", (try Data(contentsOf: project)) == Data(repeating: 0x63, count: 1_024_000) && (try Data(contentsOf: video)) == Data(repeating: 0x63, count: 1_024_000))
        print("\n\(checks) scope and review checks passed; only generated fixtures were used.")
    }
}
