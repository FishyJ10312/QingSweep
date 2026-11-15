import Foundation
import Darwin

@main struct CleanupFlowTests {
    @MainActor static func main() throws {
        let base = URL(fileURLWithPath: "/Users/Shared/qingsweep-flow-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Downloads/Nested/Child")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("sample.bin")
        try Data(repeating: 1, count: 4096).write(to: url)
        let assessment = FileAssessment(category: .cache, disposition: .priority, owner: "Homebrew", group: "下载缓存", reason: "Fixture", evidence: "Fixture", ruleID: "cache-homebrew")
        let item = ScanItem(url: url, root: base.appendingPathComponent("Downloads"), stamp: FileStamp.read(url)!, assessment: assessment)
        let model = AppModel(home: base, loadSavedScan: false, startTimer: false)
        model.items = [item]; model.showDisposition(.priority); model.search = "sample"
        let group = model.groups[0]
        model.showGroup(group)
        var failures = 0, count = 0
        func check(_ value: Bool, _ name: String) {
            count += 1
            if !value { failures += 1; print("FAIL: " + name) } else { print("PASS: " + name) }
        }
        check(model.disposition == .priority, "entering a group preserves recommendation scope")
        check(model.search == "sample", "entering a group preserves the parent search")
        check(model.canReturnCleanup, "a group always has a return destination")
        model.returnCleanup()
        check(model.groupFilter == nil && model.search == "sample" && model.disposition == .priority && model.presentation == .groups, "Back restores the exact parent list")
        check(!model.canReturnCleanup, "Back is disabled at cleanup root")
        func fixture(_ name: String, _ category: FileCategory, _ disposition: CleanupDisposition) throws -> ScanItem {
            let file = folder.appendingPathComponent(name)
            try Data(repeating: 2, count: 8192).write(to: file)
            return ScanItem(url: file, root: item.root, stamp: FileStamp.read(file)!, assessment: FileAssessment(category: category, disposition: disposition, owner: "Homebrew", group: name, reason: "Fixture", evidence: "Fixture", ruleID: "cache-homebrew"))
        }
        let manual = try fixture("reinstall.dmg", .installer, .manual)
        let conditional = try fixture("cache.dat", .cache, .conditional)
        let media = try fixture("original.mov", .video, .protected)
        let unknown = try fixture("unknown.zip", .archive, .unknown)
        let malformed = try fixture("project.drp", .project, .priority)
        model.items = [item, manual, conditional, media, unknown, malformed]
        model.selectCleanupScope(.recommended)
        check(model.filtered.map(\.id) == [item.id], "recommendations exclude manual, conditional, unknown and protected content")
        model.selectCleanupScope(.optional)
        check(Set(model.filtered.map(\.id)) == Set([manual.id, conditional.id]), "optional contains only selectable non-recommended items")
        model.selectCleanupScope(.protected)
        check(Set(model.filtered.map(\.id)) == Set([media.id, unknown.id, malformed.id]), "individual-confirmation scope contains creative files and unknown content")
        model.selectPriority()
        check(model.selected.isEmpty, "recommendations do not select media or projects")
        model.toggleVisible()
        check(Set(model.selectedItems.map(\.id)) == Set([media.id, unknown.id, malformed.id]), "explicit select all includes all current manual-confirmation files")
        model.toggleVisible()
        check(model.selected.isEmpty, "cancel all removes the current explicit selections")
        model.toggle(malformed, on: true)
        check(model.selectedItems.map(\.id) == [malformed.id], "a project can be individually selected without becoming a bulk recommendation")
        model.selectCleanupScope(.recommended); model.selected = [manual.id]; model.selectPriority()
        check(model.selected == Set([manual.id, item.id]), "adding recommendations preserves manual selections")
        check(model.currentSelection.map(\.id) == [item.id] && model.otherSelectionCount == 1, "current and hidden selections are counted separately")
        model.prepareCurrentReview()
        check(model.review.map(\.id) == [item.id] && model.reviewScopeTitle == "推荐清理", "current confirmation excludes other scopes")
        model.showingReview = false; model.prepareReview()
        check(Set(model.review.map(\.id)) == Set([item.id, manual.id]) && model.reviewScopeTitle == "全部已选文件", "all selections are reviewable only through the explicit action")
        model.showingReview = false
        model.cleanupOwnerFilter = "tool:Homebrew"; model.cleanupOwnerTitle = "Homebrew"
        model.search = "sample"; model.clearCleanupFilters()
        check(model.cleanupOwnerFilter == "tool:Homebrew" && model.cleanupScope == .recommended, "clearing filters keeps the application and policy scope")
        model.search = "sample"; model.ordering = .name; model.minimumFilter = 1024
        model.showGroup(model.groups[0]); model.search = "no-match"; model.ordering = .size; model.returnCleanup()
        check(model.search == "sample" && model.ordering == .name && model.minimumFilter == 1024 && model.cleanupOwnerFilter == "tool:Homebrew", "return restores search, ordering and application context")
        model.clearCleanupOwner(); model.selectCleanupScope(.optional); model.selected = []
        model.toggleGroup(group)
        check(model.selected.isEmpty, "stale group action cannot select files outside the viewed scope")
        model.selectCleanupScope(.recommended); model.showGroup(model.groups[0]); model.clearCleanupFilters()
        check(!model.canReturnCleanup && model.groupFilter == nil && model.cleanupScope == .recommended, "clearing a group returns to its policy root")

        model.selected = [manual.id]
        check(model.unselectedRecommendations.map(\.id) == [item.id], "add-recommendations state counts only new recommendations")
        model.selectPriority()
        check(model.unselectedRecommendations.isEmpty && model.allVisibleSelected, "recommendation action is complete after adding visible files")
        model.clearCurrentSelection()
        check(model.selected == Set([manual.id]), "clearing the current tray preserves a manual selection elsewhere")
        model.search = "not-a-file"
        check(!model.allVisibleSelected && model.visibleBatchSelectableItems.isEmpty, "empty results never show a selected-all state")
        model.cleanupOwnerFilter = "unrelated-app"; model.cleanupOwnerTitle = "Other"
        check(model.allScopeItems(.recommended).map(\.id) == [item.id] && model.scopeItems(.recommended).isEmpty, "home ledger totals are independent of the last application filter")
        model.openCleanup(.protected)
        check(model.section == .results && model.cleanupScope == .protected && model.cleanupOwnerFilter == nil && model.search.isEmpty, "home category entry opens the exact global scope")
        check(model.selected == Set([manual.id]) && model.visibleSelectableItems.count == 3, "opening manual scope preserves selections without auto-selecting its files")
        model.preferences.ignore(item.url)
        check(model.priorityBytes == 0 && model.allScopeItems(.recommended).isEmpty, "ignored candidates are excluded from ledger totals")
        model.appSummaries = [AppStorageSummary(id: "tool:Homebrew", title: "Homebrew")]
        check(model.displayedAppSummaries[0].candidateBytes == manual.bytes + conditional.bytes, "application candidate capacity also excludes ignored and protected files")
        model.openCleanup(.recommended)
        check(model.unselectedRecommendations.isEmpty && model.currentSelection.isEmpty, "an ignored recommendation cannot reappear through bulk actions")
        model.preferences = CleanupPreferences()

        model.storageInfo = StorageIndexInfo(scannedAt: Date(), roots: [StorageRoot(url: item.root, title: "Downloads", kind: .project)], visited: 3, limited: false, cancelled: false, unreadableCount: 0, elapsed: 0)
        model.storageSearch = "sample"; model.storageMode = .applications
        model.browseStorage(folder)
        check(model.canReturnStorage && model.storageFolder == folder, "folder entry creates a browsing history destination")
        model.returnStorage()
        check(model.storageMode == .applications && model.storageSearch == "sample" && model.storageFolder == nil, "folder Back restores the search that led there")
        model.storageSearch = ""; model.browseStorage(folder, owner: AppStorageSummary(id: "tool:Homebrew", title: "Homebrew"))
        model.storageUp()
        check(model.storageFolder?.path == folder.deletingLastPathComponent().path && model.storageOwnerFilter == nil, "Up reaches the physical parent even across shared ownership")
        model.returnStorage()
        check(model.storageFolder?.path == folder.path && model.storageOwnerFilter == "tool:Homebrew", "Back after Up restores the application folder")
        model.browseStorage(item.root); model.storageUp()
        check(model.storageFolder == nil, "Up from a scan root returns to root locations")
        model.changeStorageMode(.applications)
        check(model.storageOwnerFilter == nil && model.storageFolder == nil && model.storageSearch.isEmpty, "switching storage modes resets the navigation scope coherently")
        check([item,manual,conditional,media,unknown,malformed].allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }, "all navigation and policy tests leave fixture files untouched")
        print("\(count) cleanup-flow checks; \(failures) failures")
        if failures > 0 { try? FileManager.default.removeItem(at: base); exit(1) }
    }
}
