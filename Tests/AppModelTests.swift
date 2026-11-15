import Foundation
import Darwin

@main struct AppModelTests {
    @MainActor static func main() throws {
        let manager = FileManager.default
        // /private/tmp is standardized to the /tmp symlink by Foundation.
        // Real file validation intentionally rejects that alias.
        let base = URL(fileURLWithPath: "/Users/Shared").appendingPathComponent("qingsweep-model-" + UUID().uuidString)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        var count = 0
        var failures: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            guard value() else {
                fputs("FAIL: \(name)\n", stderr)
                failures.append(name)
                return
            }
            count += 1
            print("PASS: \(name)")
        }
        func make(_ path: String, size: Int, daysOld: Int, category: FileCategory,
                  disposition: CleanupDisposition, owner: String, group: String) throws -> ScanItem {
            let url = base.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x51, count: size).write(to: url)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(daysOld * 86_400))], ofItemAtPath: url.path)
            let assessment = FileAssessment(category: category, disposition: disposition, owner: owner,
                                            group: group, reason: "Fixture", evidence: "Fixture", ruleID: "fixture")
            return ScanItem(url: url, root: base.appendingPathComponent("Downloads"),
                            stamp: FileStamp.read(url)!, assessment: assessment)
        }
        let alpha = try make("Downloads/Alpha/cache.bin", size: 21_000, daysOld: 10,
                             category: .cache, disposition: .priority, owner: "Alpha", group: "Alpha cache")
        let zulu = try make("Downloads/AlphaCopy/zulu.dmg", size: 41_000, daysOld: 2,
                            category: .installer, disposition: .priority, owner: "Beta", group: "Zulu installer")
        let manual = try make("Downloads/manual.dmg", size: 61_000, daysOld: 5,
                              category: .installer, disposition: .manual, owner: "Manual", group: "Manual installer")
        let protected = try make("Downloads/video.mp4", size: 81_000, daysOld: 20,
                                 category: .video, disposition: .protected, owner: "Personal", group: "Protected video")
        let fixtureItems = [alpha, zulu, manual, protected]
        let model = AppModel(home: base, loadSavedScan: false, startTimer: false)
        model.items = fixtureItems
        check(!model.loadingReport && !model.scanning && !model.analyzing, "test initializer starts no scan or saved-report import")
        check(model.selected.isEmpty, "new model starts with no selections")

        model.selected = [manual.id]
        model.search = "Beta"
        check(model.filtered.map(\.id) == [zulu.id], "search finds owner within the current results")
        model.selectPriority()
        check(model.selected == Set([manual.id, zulu.id]), "recommended selection adds current matches without replacing hand-picked files")
        check(!model.selected.contains(alpha.id), "recommended selection respects the current search scope")
        model.showDisposition(nil)
        model.category = .cache
        model.selectPriority()
        check(model.selected == Set([manual.id, zulu.id, alpha.id]), "recommended selection also respects category scope")
        model.toggle(protected, on: true)
        check(model.selectedItems.contains { $0.id == protected.id }, "personal material supports explicit individual selection")
        model.toggle(protected, on: false)

        model.showDisposition(nil)
        model.ordering = .size
        check(model.filtered.map(\.id) == [protected.id, manual.id, zulu.id, alpha.id], "files sort by actual occupied size")
        check(model.groups.map(\.items).compactMap(\.first).map(\.id) == [protected.id, manual.id, zulu.id, alpha.id], "groups sort by occupied size across decision categories")
        model.ordering = .oldest
        check(model.filtered.map(\.id) == [protected.id, alpha.id, manual.id, zulu.id], "oldest file ordering follows modification dates")
        check(model.groups.map(\.items).compactMap(\.first).map(\.id) == [protected.id, alpha.id, manual.id, zulu.id], "oldest group ordering follows the oldest member")
        model.ordering = .name
        check(model.groups.map { $0.assessment.group } == ["Alpha cache", "Manual installer", "Protected video", "Zulu installer"], "group names sort independently from processing advice")
        model.onlySelected = true
        check(Set(model.filtered.map(\.id)) == Set([manual.id, zulu.id, alpha.id]), "selected-only view shows the actual selected set")
        model.showDisposition(.priority)
        check(!model.onlySelected && model.category == nil && model.groupFilter == nil && model.search.isEmpty,
              "changing processing advice clears stale filters")
        let group = model.groups.first { $0.items.contains { $0.id == alpha.id } }!
        model.showGroup(group)
        check(model.filtered.map(\.id) == [alpha.id] && model.presentation == .files,
              "opening a group shows its files without stale filter intersections")

        model.showDisposition(nil)
        model.selected = [manual.id, alpha.id]
        model.ignore(alpha.url.deletingLastPathComponent())
        check(!model.items.contains { $0.id == alpha.id } && !model.selected.contains(alpha.id),
              "ignoring a folder removes its files and selections together")
        check(model.items.contains { $0.id == zulu.id } && !model.preferences.isIgnored(zulu.url),
              "ignoring a folder preserves similarly named sibling folders")
        let settings = base.appendingPathComponent("Library/Application Support/QingSweep/preferences.json")
        let persisted = try CleanupPreferences.load(url: settings)
        check(persisted.isIgnored(alpha.url), "ignore action persists beyond this screen")
        let reloaded = AppModel(home: base, loadSavedScan: false, startTimer: false)
        check(reloaded.preferences.isIgnored(alpha.url), "new app model reloads ignored folder preferences")
        model.toggle(alpha, on: true)
        check(!model.selected.contains(alpha.id), "ignored items cannot be reselected through model actions")
        model.unignore(alpha.url.deletingLastPathComponent().path)
        let afterUnignore = try CleanupPreferences.load(url: settings)
        check(!model.preferences.isIgnored(alpha.url) && !afterUnignore.isIgnored(alpha.url),
              "removing an ignored folder updates memory and saved preferences")

        model.items = fixtureItems
        model.selected = [manual.id]
        model.scanning = true
        model.prepareReview()
        check(!model.showingReview && model.review.isEmpty, "cannot open a cleanup confirmation during a scan")
        model.review = [manual]
        model.reviewConfirmed = true
        model.moveReviewed()
        check(!model.mutating && manager.fileExists(atPath: manual.url.path), "cleanup execution is blocked while scanning")
        model.scanning = false
        model.review = []
        model.prepareReview()
        check(model.showingReview && model.review.map(\.id) == [manual.id] && !model.reviewConfirmed,
              "confirmation snapshots selected files and resets approval")
        check(model.busy, "open confirmation locks other disk operations")
        model.scan(roots: [base.appendingPathComponent("Downloads")], label: "must not start", minimum: 1)
        check(!model.scanning && model.items.count == fixtureItems.count, "new scans cannot replace files while confirmation is open")
        model.startStorageAnalysis()
        check(!model.analyzing && model.storageResult == nil, "space analysis cannot start while confirmation is open")
        model.ignore(zulu.url)
        check(!model.preferences.isIgnored(zulu.url) && model.items.count == fixtureItems.count,
              "ignored-file mutations are blocked while confirmation is open")
        model.showingReview = false
        model.review = [manual]
        model.reviewConfirmed = false
        model.moveReviewed()
        check(!model.mutating && manager.fileExists(atPath: manual.url.path), "unchecked confirmation never executes cleanup")
        model.reviewConfirmed = true
        model.analyzing = true
        model.moveReviewed()
        check(!model.mutating && manager.fileExists(atPath: manual.url.path), "cleanup execution is blocked while space analysis is running")
        model.analyzing = false
        model.loadingReport = true
        model.prepareReview()
        model.moveReviewed()
        check(!model.showingReview && !model.mutating && manager.fileExists(atPath: manual.url.path),
              "report loading blocks confirmation and cleanup execution")
        check(fixtureItems.allSatisfy { manager.fileExists(atPath: $0.url.path) }, "all fixture files stay in place throughout state testing")
        print("\n\(count) app-model checks passed, \(failures.count) failed; no real user data or Trash were changed.")
        if !failures.isEmpty { try? manager.removeItem(at: base); exit(1) }
    }
}
