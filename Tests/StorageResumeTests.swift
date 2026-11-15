import Foundation
@main struct StorageResumeTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default, home = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/qing-resume-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let folder = home.appendingPathComponent("Movies"), file = home.appendingPathComponent("index.sqlite"), next = home.appendingPathComponent("next.sqlite")
        for group in 0..<4 { for part in 0..<4 {
            let url = folder.appendingPathComponent("g\(group)/p\(part)/clip.mov")
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x50, count: 8192).write(to: url)
        } }
        let root = StorageRoot(url: folder, title: "视频与素材", kind: .project)
        _ = try StorageIndex.build(at: file, roots: [root], auditor: StorageAuditor(home: home, entryLimit: 5), applications: [], cancellation: ScanCancellation())
        var index = try StorageIndex(url: file), queue = try index.pendingRoots()
        guard !queue.isEmpty else { print("FAIL: a partially scanned directory has no continuation work, so missing files can never be reached"); exit(1) }
        print("PASS: partially scanned directories provide continuation work")
        var batches = 0
        while !queue.isEmpty && batches < 30 {
            _ = try StorageIndex.build(at: next, roots: queue, auditor: StorageAuditor(home: home, entryLimit: 5), applications: [], cancellation: ScanCancellation(), ownershipRoots: [root])
            try index.mergePending(from: StorageIndex(url: next)); batches += 1
            index = try StorageIndex(url: file); queue = try index.pendingRoots()
        }
        guard queue.isEmpty else { fatalError("FAIL: automatic continuation does not converge") }
        guard try index.page(search: "clip.mov").total == 16 else { fatalError("FAIL: continuation omitted nested personal files") }
        print("PASS: continuation reaches every nested file and terminates")
        guard try index.summaries().reduce(Int64(0), {$0 + $1.bytes}) == 16 * 8192 else { fatalError("FAIL: continuation changed total accounting") }
        guard try index.page(search: "clip.mov").items.allSatisfy({$0.ownerTitle == root.title}) else { fatalError("FAIL: continuation changed personal ownership") }
        print("PASS: continuation preserves original ownership and exact allocated bytes")
        guard try index.issues().filter({$0.kind == .incomplete}).isEmpty else { fatalError("FAIL: completed continuation retained stale incomplete labels") }
        print("PASS: completion clears stale incomplete states")
        _ = try StorageIndex.build(at: next, roots: [root], auditor: StorageAuditor(home: home, entryLimit: 5), applications: [], cancellation: ScanCancellation())
        try index.merge(subtree: folder, from: StorageIndex(url: next))
        guard try index.page(search: "clip.mov").total == 16 else { fatalError("FAIL: a partial rescan discarded previously indexed files") }
        print("PASS: a partial rescan preserves previously indexed files")
        guard try index.summaries().reduce(Int64(0), {$0 + $1.bytes}) == 16 * 8192 else { fatalError("FAIL: a partial rescan discarded known byte totals") }
        print("PASS: interrupted rescans preserve prior capacity")
        _ = try StorageIndex.build(at: file, roots: [root], auditor: StorageAuditor(home: home, entryLimit: 5), applications: [], cancellation: ScanCancellation())
        let model = AppModel(home: home, loadSavedScan: false, startTimer: false)
        model.storageIndexURL = file; model.storageInfo = try StorageIndex(url: file).info(); model.storagePendingRoots = try StorageIndex(url: file).pendingRoots()
        model.continueStorageAnalysis()
        for _ in 0..<160 { if !model.analyzing && model.storagePendingRoots.isEmpty { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        guard !model.analyzing, model.storagePendingRoots.isEmpty else { fatalError("FAIL: model did not automatically finish its continuation queue") }
        print("PASS: real app model automatically drains the continuation queue")
        guard model.selected.isEmpty else { fatalError("FAIL: read-only continuation selected creative files") }
        print("PASS: automatic analysis leaves media and projects unselected")
        model.storageAutoContinue = true; model.cancelStorageAnalysis()
        guard !model.storageAutoContinue else { fatalError("FAIL: Stop did not cancel future automatic batches") }
        print("PASS: Stop disables every subsequent automatic batch")
        let extra = home.appendingPathComponent("extra"), extraFile = home.appendingPathComponent("extra/file.mov")
        try fm.createDirectory(at: extra, withIntermediateDirectories: true); try Data(repeating: 0x20, count: 8192).write(to: extraFile)
        let index2 = try StorageIndex(url: file), extraRoot = StorageRoot(url: extra, title: "新增系统数据", kind: .system)
        try index2.includeAdditionalRoots([extraRoot]); try index2.includeAdditionalRoots([extraRoot])
        guard try index2.pendingRoots().filter({ $0.url.path == extra.path }).count == 1 else { fatalError("FAIL: adding a missing volume scope was not idempotent") }
        print("PASS: additional volume scopes are queued exactly once")
        _ = try StorageIndex.build(at: next, roots: index2.pendingRoots(), auditor: StorageAuditor(home: home), applications: [], cancellation: ScanCancellation())
        try index2.mergePending(from: StorageIndex(url: next))
        guard try index2.item(at: extraFile)?.bytes == 8192 else { fatalError("FAIL: newly included system data was not indexed") }
        print("PASS: added system data becomes browsable after continuation")
        model.analyzing = true; model.shouldRecheckAccessOnActivation = true; model.recheckStorageAccess()
        guard model.shouldRecheckAccessOnActivation else { fatalError("FAIL: returning from Settings while scanning lost its permission recheck") }
        print("PASS: returning from Settings during a scan retains the pending access check")
        model.analyzing = false; model.recheckStorageAccess()
        guard !model.shouldRecheckAccessOnActivation else { fatalError("FAIL: an idle model did not start the deferred check") }
        for _ in 0..<50 { if !model.accessCheckRunning { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        guard !model.accessCheckRunning else { fatalError("FAIL: deferred access check never finished") }
        print("PASS: deferred access check runs when the model becomes idle")
        print("13 storage resume checks passed")
    }
}
