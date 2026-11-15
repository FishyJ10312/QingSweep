import Foundation
import Darwin

@main struct StorageAuditTests {
    static func main() throws {
        let manager = FileManager.default
        guard let physicalTemp = realpath(NSTemporaryDirectory(), nil) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let tempPath = String(cString: physicalTemp)
        free(physicalTemp)
        let base = URL(fileURLWithPath: tempPath).appendingPathComponent("qingsweep-storage-tests-" + UUID().uuidString)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        var passed = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            passed += 1
        }
        @discardableResult func file(_ relative: String, count: Int = 16_000) throws -> URL {
            let url = base.appendingPathComponent(relative)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 93, count: count).write(to: url)
            return url
        }
        func root(_ relative: String, kind: StorageKind = .appData) -> StorageRoot {
            StorageRoot(url: base.appendingPathComponent(relative), title: relative, kind: kind)
        }
        let first = try file("A/One/first", count: 23_000)
        let second = try file("A/Two/second", count: 31_000)
        let linked = base.appendingPathComponent("A/Two/hardlink")
        guard link(first.path, linked.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let outside = try file("Outside/secret", count: 90_000)
        try manager.createSymbolicLink(at: base.appendingPathComponent("A/linked-file"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: base.appendingPathComponent("A/linked-folder"), withDestinationURL: outside.deletingLastPathComponent())
        var updates: [StorageAuditProgress] = []
        let auditor = StorageAuditor(home: base)
        let result = auditor.scan(roots: [root("A")], cancellation: ScanCancellation()) { updates.append($0) }
        expect(result.files == 2, "counts unique files once despite hard links")
        expect(result.entries.count == 1, "returns requested root")
        expect(result.entries[0].children.count == 2, "symlinks do not appear as analyzed child data")
        expect(result.totalBytes >= (FileStamp.read(first)!.allocated + FileStamp.read(second)!.allocated), "accounts for physical blocks")
        expect(result.totalBytes < FileStamp.read(outside)!.allocated, "does not count symlink destination")
        expect(result.skipped == 3, "records both skipped symlinks and duplicate inode")
        expect(result.unreadableCount == 0, "readable fixture has no access failures")
        expect(result.entries[0].fileCount == 2, "root exposes unique file count")
        expect(!updates.isEmpty && updates.last?.bytes == result.totalBytes, "progress ends at measured totals")
        expect(!result.cancelled && !result.limited, "complete traversal reports completion")
        let combined = auditor.scan(roots: [root("A/One"), root("A"), root("A")], cancellation: ScanCancellation())
        expect(combined.entries.count == 1, "normalizes duplicated and nested roots")
        expect(combined.totalBytes == result.totalBytes, "overlapping roots do not multiply totals")
        expect(combined.files == 2, "nested root normalization preserves unique file count")
        let linkRoot = auditor.scan(roots: [root("A/linked-folder")], cancellation: ScanCancellation())
        expect(linkRoot.entries.isEmpty, "rejects a symlink root")
        expect(linkRoot.unreadableCount == 1, "symlink root reports unavailable location")
        let nestedLink = auditor.scan(roots: [root("A/linked-folder/subfolder")], cancellation: ScanCancellation())
        expect(nestedLink.entries.isEmpty, "rejects a symlink ancestor")
        let token = ScanCancellation()
        token.cancel()
        let cancelled = auditor.scan(roots: [root("A")], cancellation: token)
        expect(cancelled.cancelled && cancelled.visited == 0, "respects cancellation before traversal")
        let during = ScanCancellation()
        let cancelledDuring = auditor.scan(roots: [root("A")], cancellation: during) { _ in during.cancel() }
        expect(cancelledDuring.cancelled && cancelledDuring.files == 0, "progress callback can cancel before reading files")
        let limited = StorageAuditor(home: base, entryLimit: 1).scan(roots: [root("A")], cancellation: ScanCancellation())
        expect(limited.limited && limited.visited == 1, "entry cap bounds traversal and marks partial result")
        let missing = auditor.scan(roots: [root("DoesNotExist")], cancellation: ScanCancellation())
        expect(missing.unreadableCount == 1 && missing.issues.count == 1, "missing root is visible instead of an empty success")
        let more = try file("A/Three/third", count: 100_000)
        let restricted = StorageAuditor(home: base, childLimit: 1).scan(roots: [root("A")], cancellation: ScanCancellation())
        expect(restricted.entries[0].children.count == 1, "displayed child count is bounded")
        expect(restricted.entries[0].omittedChildCount == 2, "exposes omitted child groups")
        expect(restricted.entries[0].children[0].url.lastPathComponent == "Three", "keeps the largest child when truncating display")
        expect(restricted.totalBytes >= FileStamp.read(more)!.allocated + result.totalBytes, "display limit retains full measured parent total")
        expect(!restricted.limited, "display limits do not claim incomplete measurement")
        let encoded = try JSONEncoder().encode(restricted)
        let decoded = try JSONDecoder().decode(StorageAuditResult.self, from: encoded)
        expect(decoded.totalBytes == restricted.totalBytes && decoded.entries[0].children[0].id == restricted.entries[0].children[0].id, "result round trips for saved read-only reports")
        expect(StorageRoot.defaults(home: base).contains { $0.url.path == base.appendingPathComponent("Documents").path }, "read-only default scope includes project storage")
        expect(StorageRoot.defaults(home: base).contains { $0.url.path == base.appendingPathComponent("Library/Group Containers").path }, "shared clipboard parent is in default scope")
        let appResource = try file("Apps/Claude/vm_bundles/bundle", count: 20_000)
        let cache = try file("Groups/group.com.apple.coreservices.useractivityd/shared-pasteboard/archives/id", count: 20_000)
        let nested = auditor.scan(roots: [root("Apps"), root("Groups")], cancellation: ScanCancellation())
        let titles = nested.entries.flatMap(\.children).map(\.title)
        expect(titles.contains("跨设备剪贴板") && titles.contains("Claude"), "known application folders receive readable names")
        expect(nested.files == 2 && nested.totalBytes >= FileStamp.read(appResource)!.allocated + FileStamp.read(cache)!.allocated, "multiple disjoint roots retain their own totals")
        var shallow = StorageAuditor(home: base)
        shallow.maximumDepth = 1
        let shallowResult = shallow.scan(roots: [root("Groups")], cancellation: ScanCancellation())
        expect(shallowResult.limited && shallowResult.files == 0, "depth limit prevents unbounded nested traversal")

        func plist(_ relative: String, _ value: [String: Any]) throws {
            let url = base.appendingPathComponent(relative)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: url)
        }
        let fixtureID = "com.example.qingsweep-storage-fixture"
        let fixtureName = "空间分析测试应用"
        try plist("Applications/Storage Fixture.app/Contents/Info.plist", ["CFBundleIdentifier": fixtureID, "CFBundleName": fixtureName, "CFBundleShortVersionString": "1.0"])
        try plist("Applications/Override Fixture.app/Contents/Info.plist", ["CFBundleIdentifier": "com.tencent.xinWeChat", "CFBundleName": "不可覆盖微信名称", "CFBundleShortVersionString": "1.0"])
        let uuid = "578E0667-0001-4097-ADDB-570629F04501"
        let unknownUUID = "578E0667-0002-4097-ADDB-570629F04502"
        let linkedUUID = "578E0667-0003-4097-ADDB-570629F04503"
        let identityName = ".com.apple.containermanagerd.metadata.plist"
        try plist("Library/Containers/\(uuid)/\(identityName)", ["MCMMetadataIdentifier": fixtureID])
        try plist("Library/Containers/\(unknownUUID)/\(identityName)", ["MCMMetadataIdentifier": "com.example.not-installed"])
        _ = try file("Library/Containers/\(linkedUUID)/Data/cache")
        try manager.createSymbolicLink(at: base.appendingPathComponent("Library/Containers/\(linkedUUID)/\(identityName)"), withDestinationURL: base.appendingPathComponent("Library/Containers/\(uuid)/\(identityName)"))
        _ = try file("Library/Containers/\(fixtureID)/Data/cache")
        _ = try file("Library/Containers/com.tencent.xinWeChat/Data/cache")
        _ = try file("Library/Caches/\(fixtureID).ShipIt/data")
        let friendly = auditor.scan(roots: [root("Library/Containers"), root("Library/Caches")], cancellation: ScanCancellation())
        let friendlyChildren = friendly.entries.flatMap(\.children)
        expect(friendlyChildren.first { $0.url.lastPathComponent == uuid }?.title == fixtureName, "UUID container maps via the OS identity plist to installed application name")
        expect(friendlyChildren.first { $0.url.lastPathComponent == fixtureID }?.title == fixtureName, "bundle identifier folder maps to installed application name")
        expect(friendlyChildren.first { $0.url.lastPathComponent == unknownUUID }?.title == unknownUUID, "unknown container keeps its original folder name")
        expect(friendlyChildren.first { $0.url.lastPathComponent == linkedUUID }?.title == linkedUUID, "container identity does not follow symlink metadata")
        expect(friendlyChildren.first { $0.url.lastPathComponent == "com.tencent.xinWeChat" }?.title == "微信", "existing friendly names take priority over installed metadata")
        expect(friendlyChildren.first { $0.url.lastPathComponent == fixtureID + ".ShipIt" }?.title == fixtureName + " 更新缓存", "updater cache uses the installed application name")
        _ = try file("PriorityLongFolder/first")
        _ = try file("B/second")
        var firstPath: String?
        _ = auditor.scan(roots: [root("PriorityLongFolder"), root("B")], cancellation: ScanCancellation()) { update in
            if firstPath == nil { firstPath = update.current }
        }
        expect(firstPath == base.appendingPathComponent("PriorityLongFolder").path, "root normalization preserves supplied scan priority")
        let defaultPaths = StorageRoot.defaults(home: base).map { $0.url.path }
        expect(defaultPaths.prefix(4) == ["Documents", "Pictures", "Movies", "Downloads"].map { base.appendingPathComponent($0).path }[...], "default scan prioritizes omitted personal footprint before app caches")
        print("Storage audit: \(passed) checks passed")
    }
}
