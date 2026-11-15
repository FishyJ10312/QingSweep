import Foundation
import Darwin

@main struct InteractionSupportTests {
    static func main() throws {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent("interaction-fixture-" + UUID().uuidString)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            count += 1
            print("PASS: \(name)")
        }
        @discardableResult func write(_ relative: String, _ text: String = "fixture") throws -> URL {
            let url = base.appendingPathComponent(relative)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }

        var preferences = CleanupPreferences(ignoredPaths: ["relative", "", "/Folder/./Child/..", "/Folder", "/Folder\0bad"])
        check(preferences.ignoredPaths == ["/Folder"], "normalizes and deduplicates valid absolute paths")
        check(preferences.isIgnored(URL(fileURLWithPath: "/Folder/sub/file")), "ignores descendants")
        check(!preferences.isIgnored(URL(fileURLWithPath: "/Folder-copy/file")), "directory boundary excludes similarly named sibling")
        check(!preferences.isIgnored(URL(string: "https://example.com/Folder")!), "non-file URLs never match")
        preferences.ignore(URL(fileURLWithPath: "/Second/file"))
        preferences.ignore(URL(fileURLWithPath: "/Second/file"))
        check(preferences.ignoredPaths.count == 2, "ignoring twice remains idempotent")
        preferences.unignore("/Folder/./")
        check(!preferences.isIgnored(URL(fileURLWithPath: "/Folder/sub/file")), "canonical unignore removes rule")
        let settings = base.appendingPathComponent("settings/preferences.json")
        let emptyPreferences = try CleanupPreferences.load(url: settings)
        check(emptyPreferences.ignoredPaths.isEmpty, "missing settings starts empty")
        try preferences.save(url: settings)
        let loadedPreferences = try CleanupPreferences.load(url: settings)
        check(loadedPreferences == preferences, "ignore preferences survive persistence")
        let encoded = Data("{\"ignoredPaths\":[\"relative\",\"/A/../B\",\"/B\"]}".utf8)
        let sanitizedPreferences = try JSONDecoder().decode(CleanupPreferences.self, from: encoded)
        check(sanitizedPreferences.ignoredPaths == ["/B"], "loaded preferences also normalize untrusted stored paths")
        try Data("bad json".utf8).write(to: settings)
        do { _ = try CleanupPreferences.load(url: settings); check(false, "malformed preferences report error") }
        catch { check(true, "malformed preferences report error") }

        let policy = SafetyPolicy(home: base)
        let context = InspectionContext()
        let downloads = base.appendingPathComponent("Downloads")
        let existing = try write("Downloads/keep.zip")
        let changing = try write("Downloads/changed.zip")
        let missing = try write("Downloads/missing.zip")
        let ignoreFile = try write("Downloads/ignored/file.zip")
        let protectedFile = try write("Library/Application Support/private.bin")
        let forged = FileAssessment(category: .cache, disposition: .priority, owner: "forged", group: "forged", reason: "forged", evidence: "forged", ruleID: "forged")
        func item(_ url: URL, root: URL? = nil) -> ScanItem {
            ScanItem(url: url, root: root ?? downloads, stamp: FileStamp.read(url)!, assessment: forged)
        }
        let validItem = item(existing)
        let changedItem = item(changing)
        let missingItem = item(missing)
        let ignoredItem = item(ignoreFile)
        let unsafeItem = item(protectedFile, root: base.appendingPathComponent("Library/Application Support"))
        try Data("changed size".utf8).write(to: changing)
        try manager.removeItem(at: missing)
        let linkTarget = try write("Downloads/target.bin")
        let link = downloads.appendingPathComponent("linked.zip")
        try manager.createSymbolicLink(at: link, withDestinationURL: linkTarget)
        let linkItem = item(link)
        var ignored = CleanupPreferences()
        ignored.ignore(ignoreFile.deletingLastPathComponent())
        var archive = ScanArchive(scannedAt: .distantPast, label: "fixture", result: ScanResult(items: [validItem, validItem, changedItem, missingItem, ignoredItem, unsafeItem, linkItem]), preselectPriority: true)
        let validated = ScanReportLoader.validate(report: archive, policy: policy, context: context, ignored: ignored)
        check(validated.map(\.id) == [existing.path], "old reports reject changed, missing, ignored, unsafe, linked and duplicate items")
        check(validated[0].assessment.disposition == .unknown, "old serialized classification is never trusted")
        check(ScanReportLoader.validate(report: archive, policy: policy, context: context).contains { $0.id == ignoreFile.path }, "unignored existing file returns even with old report date")
        archive.schemaVersion = 99
        check(ScanReportLoader.validate(report: archive, policy: policy, context: context).isEmpty, "unsupported report schema rejected")

        // This is a fixture directory named .Trash, not the user's actual Trash.
        let trashed = try write(".Trash/restore.bin")
        let destination = downloads.appendingPathComponent("restore.bin")
        let record = TrashRecord(id: UUID(), original: destination, trashed: trashed, bytes: 7, date: Date(), stamp: FileStamp.read(trashed))
        check(RestoreAvailability.check(record: record, policy: policy) == .available, "unchanged fixture in Trash is restorable")
        _ = try write("Downloads/restore.bin", "occupied")
        check(RestoreAvailability.check(record: record, policy: policy) == .occupied, "same-name original blocks restoration")
        try manager.removeItem(at: destination)
        try manager.createSymbolicLink(at: destination, withDestinationURL: base.appendingPathComponent("missing-target"))
        check(RestoreAvailability.check(record: record, policy: policy) == .occupied, "dangling destination symlink blocks restoration")
        try manager.removeItem(at: destination)
        try Data("new content".utf8).write(to: trashed)
        check(RestoreAvailability.check(record: record, policy: policy) == .changed, "modified Trash fixture cannot be restored")
        try manager.removeItem(at: trashed)
        check(RestoreAvailability.check(record: record, policy: policy) == .missing, "cleared Trash item is reported unavailable")
        let outsideTrash = try write("somewhere/restore.bin")
        let falseRecord = TrashRecord(id: UUID(), original: destination, trashed: outsideTrash, bytes: 7, date: Date(), stamp: FileStamp.read(outsideTrash))
        check(RestoreAvailability.check(record: falseRecord, policy: policy) == .blocked, "record outside Trash is blocked")
        let parent = downloads.appendingPathComponent("new-parent")
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let tempTrash = try write(".Trash/parent.bin")
        let unavailableParent = TrashRecord(id: UUID(), original: parent.appendingPathComponent("parent.bin"), trashed: tempTrash, bytes: 7, date: Date(), stamp: FileStamp.read(tempTrash))
        try manager.removeItem(at: parent)
        check(RestoreAvailability.check(record: unavailableParent, policy: policy) == .blocked, "missing original parent is blocked")
        try manager.createSymbolicLink(at: parent, withDestinationURL: downloads)
        check(RestoreAvailability.check(record: unavailableParent, policy: policy) == .blocked, "symlinked original parent is blocked")
        let noStamp = TrashRecord(id: UUID(), original: destination, trashed: tempTrash, bytes: 7, date: Date(), stamp: nil)
        check(RestoreAvailability.check(record: noStamp, policy: policy) == .changed, "record with no file identity is unavailable")
        check(manager.fileExists(atPath: tempTrash.path) && manager.fileExists(atPath: existing.path), "inspection leaves all fixture files in place")
        print("\n\(count) interaction checks passed; no real user files or Trash were changed.")
    }
}
