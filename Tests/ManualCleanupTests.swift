import Foundation
import Darwin

@main struct ManualCleanupTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("testdata-manual-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let policy = SafetyPolicy(home: base), service = TrashService(policy: SafetyPolicy(home: base))
        let bytes = Data(repeating: 0x41, count: 1_100_000)
        var count = 0
        func check(_ value: Bool, _ title: String) {
            guard value else { fputs("FAIL: " + title + "\n", stderr); exit(1) }
            count += 1; print("PASS: " + title)
        }
        func make(_ path: String) throws -> ScanItem {
            let url = base.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            let stamp = FileStamp.read(url)!
            return ScanItem(url: url, root: base, stamp: stamp, assessment: FileClassifier(policy: policy, context: InspectionContext()).assess(url, stamp: stamp))
        }
        func waitForOperation(_ model: AppModel) async {
            let deadline = Date().addingTimeInterval(15)
            while model.mutating && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
            check(!model.mutating, "file operation completes")
        }
        let video = try make("Downloads/take.mp4")
        let project = try make("Downloads/edit.drp")
        let archive = try make("Downloads/unidentified.zip")
        let model = AppModel(home: base, loadSavedScan: false, startTimer: false)
        let activeLog = try make("Library/Logs/Fixture/diagnostic.log")
        model.items = [activeLog]; model.openCleanup(.optional); model.toggle(activeLog, on: true); model.prepareCurrentReview()
        check(model.canProceedWithReview, "review does not require a user assertion that applications are closed")
        model.showingReview = false; model.selected = []
        model.items = [video, project, archive]; model.openCleanup(.protected)
        check(model.selected.isEmpty, "media, projects and unknown files start unselected")
        model.selectPriority()
        check(model.selected.isEmpty, "recommendations never select media or projects")
        model.toggleVisible()
        check(Set(model.selectedItems.map(\.id)) == Set([video.id, project.id, archive.id]), "explicit select all includes media and projects in the current scope")
        model.toggleGroup(model.groups.first { $0.items.contains { $0.id == project.id } }!)
        check(Set(model.selectedItems.map(\.id)) == Set([video.id, archive.id]), "group deselection preserves other explicitly selected groups")
        let staleVideoGroup = model.groups.first { $0.items.contains { $0.id == video.id } }!
        model.search = "edit.drp"; model.toggleVisible()
        check(Set(model.selectedItems.map(\.id)) == Set([video.id, project.id, archive.id]) && model.currentSelection.map(\.id) == [project.id], "filtered select all adds only matches and preserves selections elsewhere")
        model.toggleVisible(); model.toggleGroup(staleVideoGroup)
        check(Set(model.selectedItems.map(\.id)) == Set([video.id, archive.id]), "filtered deselect and stale groups do not alter other scopes")
        model.search = ""; model.selected = []
        model.preferences.ignore(project.url); model.toggleVisible()
        check(Set(model.selectedItems.map(\.id)) == Set([video.id, archive.id]), "manual select all respects the ignore list")
        model.preferences = CleanupPreferences(); model.selected = []
        model.selected = [video.id]; model.prepareReview()
        check(model.review.isEmpty && !model.showingReview, "a raw selection set cannot bypass individual selection")
        model.selected = []
        for item in [video, project, archive] { model.toggle(item, on: true) }
        model.prepareCurrentReview()
        check(Set(model.review.map(\.id)) == Set([video.id, project.id, archive.id]), "individually selected files enter the in-app review")
        model.reviewConfirmed = true; model.moveReviewed()
        check(!model.mutating && model.history.isEmpty, "first review approval alone cannot move individually confirmed files")
        model.requestReviewedMove()
        check(model.showingManualConfirmation && !model.manualReviewAcknowledged && !model.mutating, "continuing review opens a fresh second confirmation")
        model.confirmManualCleanup()
        check(!model.mutating && fm.fileExists(atPath: video.id), "second confirmation requires explicit acknowledgement")
        model.manualReviewAcknowledged = true; model.returnToReview()
        check(!model.showingManualConfirmation && !model.manualReviewAcknowledged && model.history.isEmpty, "returning from second confirmation revokes acknowledgement")
        model.requestReviewedMove(); model.manualReviewAcknowledged = true
        model.removeReviewedItem(project)
        check(!model.showingManualConfirmation && !model.manualReviewAcknowledged && !model.selected.contains(project.id), "changing the reviewed list invalidates second confirmation")
        model.confirmManualCleanup()
        check(!model.mutating && model.history.isEmpty, "stale second confirmation cannot execute")
        model.requestReviewedMove(); model.manualReviewAcknowledged = true
        model.confirmManualCleanup(); await waitForOperation(model)
        check(Set(model.history.map { $0.original.path }) == Set([video.id, archive.id]) && !fm.fileExists(atPath: video.id) && !fm.fileExists(atPath: archive.id), "acknowledged manual cleanup moves only the reviewed fixtures to macOS Trash")
        check(fm.fileExists(atPath: project.id), "cancelled project remains in its original location")
        let records = model.history
        model.restoreBatch(records); await waitForOperation(model)
        check(model.history.isEmpty && fm.fileExists(atPath: video.id) && fm.fileExists(atPath: archive.id), "manual cleanup history supports in-app restoration")
        check(try Data(contentsOf: video.url) == bytes && Data(contentsOf: archive.url) == bytes, "restoration preserves original fixture bytes")
        check(model.selected.isEmpty, "restored media is not automatically selected again")
        model.toggle(project, on: true); model.prepareCurrentReview(); model.requestReviewedMove()
        model.manualReviewAcknowledged = true; model.confirmManualCleanup(); await waitForOperation(model)
        check(model.history.count == 1 && model.history[0].original == project.url && !fm.fileExists(atPath: project.id), "a separately confirmed project can be moved through the same in-app flow")
        model.restoreBatch(model.history); await waitForOperation(model)
        check(model.history.isEmpty && (try? Data(contentsOf: project.url)) == bytes && model.selected.isEmpty, "project restoration preserves its bytes and leaves it unselected")

        let first = try make("Downloads/first.jpg"), second = try make("Downloads/second.jpg")
        let consent = ManualCleanupConsent(reviewedItems: [first])
        let limited = service.move([first, second], manualConsent: consent)
        check(limited.records.count == 1 && limited.records[0].original == first.url && limited.errors.count == 1 && fm.fileExists(atPath: second.id), "manual consent is restricted to the exact confirmed file")
        try service.restore(limited.records[0])
        let changed = try make("Downloads/changed.mp4")
        let oldConsent = ManualCleanupConsent(reviewedItems: [changed])
        try Data("changed after review".utf8).write(to: changed.url)
        let denied = service.move([changed], manualConsent: oldConsent)
        check(denied.records.isEmpty && denied.errors.count == 1 && fm.fileExists(atPath: changed.id), "manual confirmation never bypasses file identity checks")
        let database = try make("Downloads/catalog.sqlite")
        let blocked = service.move([database], manualConsent: ManualCleanupConsent(reviewedItems: [database]))
        check(blocked.records.isEmpty && fm.fileExists(atPath: database.id), "manual confirmation does not widen the hard path exclusions")
        let log = try make("Library/Logs/Example/old.log")
        try Data("{}".utf8).write(to: log.url.deletingLastPathComponent().appendingPathComponent("package.json"))
        let changedClassification = service.move([log], manualConsent: ManualCleanupConsent(reviewedItems: [log]))
        check(changedClassification.records.isEmpty && fm.fileExists(atPath: log.id), "newly detected project context requires a fresh individual review")
        let alias = base.appendingPathComponent("Downloads/link.mp4")
        try fm.createSymbolicLink(at: alias, withDestinationURL: second.url)
        let linkItem = ScanItem(url: alias, root: base, stamp: FileStamp.read(alias)!, assessment: second.assessment)
        check(service.move([linkItem], manualConsent: ManualCleanupConsent(reviewedItems: [linkItem])).records.isEmpty && fm.fileExists(atPath: second.id), "manual confirmation never follows a symbolic link")
        model.items = [second]; model.preferences.ignore(second.url); model.toggle(second, on: true)
        check(model.selected.isEmpty, "ignored media cannot be individually reselected")
        check(AppModel(home: base, loadSavedScan: false, startTimer: false).selected.isEmpty, "restarting never restores manual selections or consent")
        print("\(count) manual-cleanup checks passed; only disposable fixtures were moved and restored.")
    }
}
