import Foundation

@main struct StorageCoverageTests {
    static func main() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("testdata-coverage-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let names = ["Documents/Projects/timeline.drp", "Pictures/RAW/take.arw", "Movies/original.mov", "Desktop/course.pdf", "Music/track.wav", ".codex/work/project.swift", "Downloads/archive.zip", "Library/Application Support/Example/large.data", "Library/OtherDatabase/catalog.db", "loose-image.iso", "Documents/Adobe/own-project.drp"]
        var files: [URL] = []
        for name in names {
            let url = home.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x48, count: 8192).write(to: url); files.append(url)
        }
        let roots = StorageRoot.defaults(home: home).filter { SafetyPolicy.within($0.url, home) }
        var found = Set<String>()
        let result = StorageAuditor(home: home).scanIndexed(roots: roots, cancellation: ScanCancellation(), onEntry: { found.insert($0.url.path) }, onIssue: { _ in }, onRootFinished: { _, _ in })
        let absent = files.filter { !found.contains($0.path) }.map { $0.path.replacingOccurrences(of: home.path + "/", with: "") }
        guard absent.isEmpty else { print("FAIL: space analysis omitted non-cleanup files: " + absent.joined(separator: ", ")); exit(1) }
        let expected = files.reduce(Int64(0)) { $0 + FileStamp.read($1)!.allocated }
        guard result.totalBytes == expected else { fatalError("FAIL: full footprint must count actual allocated bytes once") }
        print("PASS: all personal media, projects, hidden workspaces and other Library data are included")
        print("PASS: full footprint counts allocated bytes once without making them cleanup candidates")
        guard files.allSatisfy({ (try? Data(contentsOf: $0)) == Data(repeating: 0x48, count: 8192) }) else { fatalError("FAIL: read-only analysis changed a fixture") }
        print("PASS: space analysis leaves all fixture bytes unchanged")
        let indexURL = home.deletingLastPathComponent().appendingPathComponent(".build/coverage-" + UUID().uuidString + ".sqlite")
        defer { try? fm.removeItem(at: indexURL) }
        _ = try StorageIndex.build(at: indexURL, roots: roots, auditor: StorageAuditor(home: home), applications: [], cancellation: ScanCancellation())
        let index = try StorageIndex(url: indexURL)
        guard try index.summaries().reduce(Int64(0), { $0 + $1.bytes }) == expected else { fatalError("FAIL: application/resource summary omits or double-counts personal files") }
        print("PASS: summaries include all scanned personal bytes exactly once")
        let project = try index.page(search: "own-project.drp").items.first!
        guard project.ownerID.hasPrefix("personal:") && project.ownerTitle == "文稿与项目" else { fatalError("FAIL: a personal Adobe-named folder must not be assigned to Adobe") }
        print("PASS: personal work is a named group, not misattributed to an application")
        guard try index.item(at: home.appendingPathComponent("loose-image.iso"))?.isDirectory == false else { fatalError("FAIL: home-level files must be indexed as files") }
        print("PASS: files directly in the home folder remain browsable files")
        guard try index.accountedBytes(onDeviceOf: home) == expected else { fatalError("FAIL: coverage total disagrees with scanned allocated bytes") }
        print("PASS: current-volume accounting counts all scanned files once")
        let subtree = home.appendingPathComponent("Documents/Adobe")
        let subtreeIndexURL = indexURL.appendingPathExtension("subtree")
        defer { try? fm.removeItem(at: subtreeIndexURL) }
        _ = try StorageIndex.build(at: subtreeIndexURL, roots: [StorageRoot(url: subtree, title: "Adobe", kind: .appData)], auditor: StorageAuditor(home: home), applications: [], cancellation: ScanCancellation(), ownershipRoots: roots)
        try index.merge(subtree: subtree, from: StorageIndex(url: subtreeIndexURL))
        guard try index.page(search: "own-project.drp").items.first?.ownerID == project.ownerID else { fatalError("FAIL: subtree rescan changed personal ownership") }
        print("PASS: subtree rescans retain the original personal category")
        guard try index.summaries().reduce(Int64(0), { $0 + $1.bytes }) == expected else { fatalError("FAIL: subtree merge changed accounting") }
        print("PASS: subtree merging preserves total accounting")
        let resumeURL = indexURL.appendingPathExtension("resume")
        let nextURL = indexURL.appendingPathExtension("next")
        defer { try? fm.removeItem(at: resumeURL); try? fm.removeItem(at: nextURL) }
        let loose = roots.first { $0.url.lastPathComponent == "loose-image.iso" }!
        let ordered = [loose] + roots.filter { $0.url.path != loose.url.path }
        _ = try StorageIndex.build(at: resumeURL, roots: ordered, auditor: StorageAuditor(home: home, entryLimit: 1), applications: [], cancellation: ScanCancellation())
        let resumed = try StorageIndex(url: resumeURL), pending = try resumed.pendingRoots()
        guard pending.count == ordered.count - 1, !pending.contains(where: { $0.url == loose.url }) else { fatalError("FAIL: continuation should only include unstarted scopes") }
        print("PASS: continuation queues unstarted scopes and skips completed scopes")
        let cancelled = ScanCancellation(); cancelled.cancel()
        _ = try StorageIndex.build(at: nextURL, roots: pending, auditor: StorageAuditor(home: home), applications: [], cancellation: cancelled)
        try resumed.mergePending(from: StorageIndex(url: nextURL))
        guard try resumed.item(at: loose.url)?.bytes == FileStamp.read(loose.url)!.allocated, try resumed.pendingRoots().count == pending.count else { fatalError("FAIL: cancelled continuation lost the prior snapshot") }
        print("PASS: cancelled continuation preserves prior results and its remaining queue")
        _ = try StorageIndex.build(at: nextURL, roots: pending, auditor: StorageAuditor(home: home), applications: [], cancellation: ScanCancellation(), ownershipRoots: ordered)
        let finished = try StorageIndex(url: nextURL)
        try resumed.mergePending(from: finished)
        guard try resumed.summaries().reduce(Int64(0), { $0 + $1.bytes }) == expected else { fatalError("FAIL: continuation omitted or double-counted existing bytes") }
        print("PASS: continuation merges remaining files without losing or double-counting prior bytes")
        guard try resumed.pendingRoots().isEmpty else { fatalError("FAIL: continuation did not clear completed scopes") }
        print("PASS: completed continuation clears its remaining queue")
        do { try resumed.mergePending(from: finished); fatalError("FAIL: continuation replaced scopes that were not pending") } catch StorageIndexError.invalid { }
        print("PASS: continuation cannot replace an already completed scope")
        let hardA = home.appendingPathComponent("hard-a.bin"), hardB = home.appendingPathComponent("hard-b.bin")
        try Data(repeating: 0x41, count: 8192).write(to: hardA); try fm.linkItem(at: hardA, to: hardB)
        let linkRoots = [hardA, hardB].map { StorageRoot(url: $0, title: $0.lastPathComponent, kind: .project) }
        _ = try StorageIndex.build(at: resumeURL, roots: linkRoots, auditor: StorageAuditor(home: home, entryLimit: 1), applications: [], cancellation: ScanCancellation())
        let links = try StorageIndex(url: resumeURL)
        _ = try StorageIndex.build(at: nextURL, roots: links.pendingRoots(), auditor: StorageAuditor(home: home), applications: [], cancellation: ScanCancellation())
        try links.mergePending(from: StorageIndex(url: nextURL))
        guard try links.summaries().reduce(Int64(0), { $0 + $1.bytes }) == FileStamp.read(hardA)!.allocated else { fatalError("FAIL: continuation counted a hard link twice") }
        print("PASS: hard links spanning separate scan batches are counted once")
        let appURL = home.appendingPathComponent("Applications/Fixture.app/Contents/large.bin")
        try fm.createDirectory(at: appURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x50, count: 16384).write(to: appURL)
        let app = InstalledApplication(path: home.appendingPathComponent("Applications/Fixture.app").path, id: "local.fixture.editor", name: "Fixture", version: "1", build: "1")
        _ = try StorageIndex.build(at: indexURL, roots: [StorageRoot(url: home.appendingPathComponent("Applications"), title: "应用程序", kind: .system)], auditor: StorageAuditor(home: home), applications: [app], cancellation: ScanCancellation())
        let fresh = try StorageIndex(url: indexURL)
        guard try fresh.summaries(applications: [app]).first(where: { $0.id == app.id })?.programBytes == FileStamp.read(appURL)!.allocated else { fatalError("FAIL: a broad Applications scan must count program bytes as program bytes") }
        print("PASS: broad application roots retain correct program ownership and component")
        print("16 storage coverage checks passed")
    }
}
