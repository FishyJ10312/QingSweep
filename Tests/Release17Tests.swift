import AppKit
import Darwin
import Foundation

final class Commands17: ToolCommandRunning {
  var calls: [[String]] = []
  var responses: [ToolCommandResult] = []
  var hook: (([String]) -> Void)?
  func run(_ executable: String, _ arguments: [String], cancellation: ScanCancellation?) throws
    -> ToolCommandResult
  {
    calls.append([executable] + arguments)
    hook?(arguments)
    if cancellation?.isCancelled == true { throw ToolFailure.cancelled }
    return responses.isEmpty ? ToolCommandResult(status: 0, output: "") : responses.removeFirst()
  }
}
struct Environment17: CleanupApplicationEnvironment {
  let hook: () -> Void
  func usage(for items: [ScanItem]) async throws -> CleanupUsage {
    hook()
    return CleanupUsage()
  }
  func requestQuit(_ app: CleanupApplication) -> Bool { false }
}
@main struct Release17Tests {
  @MainActor static func main() async throws {
    setbuf(stdout, nil)
    setbuf(stderr, nil)
    let fm = FileManager.default
    let home = URL(fileURLWithPath: "/Users/Shared/qingsweep-release17-" + UUID().uuidString)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    var trash: [URL] = []
    defer {
      for url in trash where FileStamp.read(url) != nil { try? fm.removeItem(at: url) }
      try? fm.removeItem(at: home)
    }
    var count = 0
    func check(_ value: @autoclosure () throws -> Bool, _ title: String) {
      guard (try? value()) == true else {
        fputs("FAIL: " + title + "\n", stderr)
        exit(1)
      }
      count += 1
      print("PASS: " + title)
    }
    func rejects(_ action: () throws -> Void) -> Bool {
      do {
        try action()
        return false
      } catch { return true }
    }
    @discardableResult func file(_ path: String, _ data: Data = Data(repeating: 55, count: 8192))
      throws -> URL
    {
      let url = home.appendingPathComponent(path)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
      return url
    }
    func item(_ url: URL) -> ScanItem {
      let stamp = FileStamp.read(url)!
      return ScanItem(
        url: url, root: home, stamp: stamp,
        assessment: FileClassifier(policy: SafetyPolicy(home: home), context: InspectionContext())
          .assess(url, stamp: stamp))
    }
    let content = Data(repeating: 65, count: 160000)
    let a = try file("Documents/Duplicates/a.mov", content)
    let b = try file("Documents/Duplicates/b.mov", content)
    var different = content
    different[different.count - 1] = 66
    let c = try file("Documents/Duplicates/c.mov", different)
    let dup = DuplicateFinder.scan(
      roots: [a.deletingLastPathComponent()], home: home, cancellation: ScanCancellation())
    check(
      dup.groups.count == 1 && dup.groups[0].files.count == 2,
      "full hash excludes same-prefix files with different tails")
    check(
      dup.groups[0].files.allSatisfy { $0.url != c },
      "different content cannot enter a duplicate group")
    check(
      dup.verified == 3 && dup.bytesRead > content.count * 3,
      "same-size prefix candidates receive complete content verification")
    check(
      rejects {
        _ = try DuplicateFinder.guards(groups: dup.groups, selected: Set([a.path, b.path]))
      }, "duplicate groups cannot select every copy")
    let guards = try DuplicateFinder.guards(groups: dup.groups, selected: [b.path])
    check(guards[b.path]?.url == a, "selected duplicate records an explicit retained copy")
    try (content + Data([3])).write(to: a)
    check(
      rejects { try guards[b.path]!.validate() },
      "changed retained copy invalidates the cleanup guard")
    let blocked = await CleanupExecutor(environment: Environment17(hook: {})).run(
      [item(b)], policy: SafetyPolicy(home: home),
      consent: ManualCleanupConsent(reviewedItems: [item(b)]), cancellation: ScanCancellation(),
      retainedCopies: guards
    ) { _ in }
    check(
      blocked.trash.records.isEmpty && FileStamp.read(b) != nil,
      "changed retained copy prevents the real cleanup path")
    try content.write(to: a)
    let newGuards = [b.path: RetainedCopy(url: a, stamp: FileStamp.read(a)!)]
    var changedOnce = false
    let during = await CleanupExecutor(
      environment: Environment17(hook: {
        if !changedOnce {
          changedOnce = true
          try? different.write(to: a)
        }
      })
    ).run(
      [item(b)], policy: SafetyPolicy(home: home),
      consent: ManualCleanupConsent(reviewedItems: [item(b)]), cancellation: ScanCancellation(),
      retainedCopies: newGuards
    ) { _ in }
    check(
      during.trash.records.isEmpty && FileStamp.read(b) != nil,
      "retained copy is checked again immediately before Trash")
    let cancelled = ScanCancellation()
    cancelled.cancel()
    check(
      DuplicateFinder.scan(roots: [home], home: home, cancellation: cancelled).cancelled,
      "duplicate search supports cancellation")
    let link = home.appendingPathComponent("Documents/Duplicates/hard.mov")
    try fm.linkItem(at: b, to: link)
    check(
      !DuplicateFinder.scan(
        roots: [b.deletingLastPathComponent()], home: home, cancellation: ScanCancellation()
      ).groups.flatMap(\.files).contains { $0.url == b || $0.url == link },
      "hard links are excluded instead of counting two removable copies")
    try fm.removeItem(at: link)
    let symlink = home.appendingPathComponent("linked.mov")
    try fm.createSymbolicLink(at: symlink, withDestinationURL: b)
    check(!LocalFiles.noLinks(symlink), "linked source paths are rejected")
    check(
      rejects { _ = try LocalFiles.digest(b, expected: FileStamp.read(a)!) },
      "hashing rejects a mismatched file identity")

    let proxy = try file("Movies/ProxyMedia/Travel/clip.mov")
    let render = try file("Movies/CacheClip/Travel/cache.dvcc")
    let optimized = try file("Movies/OptimizedMedia/Travel/clip.mov")
    _ = try file("Movies/CacheClip/Travel/project.drp")
    let media = ResolveMediaAudit.scan(
      roots: [home.appendingPathComponent("Movies")], home: home, cancellation: ScanCancellation())
    check(
      media.files.count == 3, "media audit only lists recognized proxy/cache/optimized contents")
    check(Set(media.files.map(\.kind)).count == 3, "media purposes remain distinct")
    check(
      media.files.filter { $0.item.url != proxy }.allSatisfy {
        $0.item.assessment.requiresIndividualConfirmation
      }, "cache project association never implies abandoned or recommended")
    _=NSApplication.shared
    let model = AppModel(home: home, loadSavedScan: false, startTimer: false)
    check(NSApp != nil,"monitor-off initialization cannot terminate a windowless native application")
    check(
      model.selected.isEmpty && model.workbench.mediaSelected.isEmpty
        && model.workbench.duplicateSelected.isEmpty && model.workbench.managedSelected.isEmpty,
      "all personal and new-tool selections start empty")
    model.reviewToolFiles([item(proxy)], title: "媒体测试")
    check(
      model.review.count == 1 && model.isIndividuallySelected(model.review[0]),
      "explicit media choices enter the shared review path")
    model.requestReviewedMove()
    check(
      model.showingManualConfirmation && !model.manualReviewAcknowledged && !model.mutating,
      "media still requires a second acknowledgement")
    model.showingReview = false
    check(
      FileStamp.read(proxy) != nil && FileStamp.read(render) != nil
        && FileStamp.read(optimized) != nil, "cancelling review leaves all media untouched")
    let association = MediaAssociation(
      media: proxy, original: b, originalStamp: FileStamp.read(b)!, confirmedAt: Date())
    check(association.available, "confirmed original stores file identity")
    try (content + Data([6])).write(to: b)
    check(!association.available, "original replacement changes its association status")

    let root = StorageRoot(url: home.appendingPathComponent("Movies"), title: "媒体", kind: .project)
    let db = home.appendingPathComponent("index.sqlite")
    _ = try StorageIndex.build(
      at: db, roots: [root], auditor: StorageAuditor(home: home), applications: [],
      cancellation: ScanCancellation())
    let index = try StorageIndex(url: db)
    let first = try GrowthHistory.capture(index: index, applications: [])!
    check(
      first.values.reduce(0) { $0 + $1.bytes }
        == (try index.summaries()).reduce(0) { $0 + $1.bytes },
      "growth snapshots count owner allocations exactly once")
    let later = GrowthSnapshot(
      id: UUID(), date: first.date.addingTimeInterval(1900), coverage: first.coverage,
      values: first.values.map {
        GrowthValue(id: $0.id, title: $0.title, bytes: $0.bytes + 4096, folder: nil)
      })
    var history = GrowthHistory()
    history.record(first)
    history.record(later)
    check(
      history.comparison() != nil && !GrowthHistory.changes(from: first, to: later).isEmpty,
      "same-coverage snapshots produce growth changes")
    let other = GrowthSnapshot(
      id: UUID(), date: later.date.addingTimeInterval(1900), coverage: "new-permission",
      values: later.values)
    history.record(other)
    check(
      history.comparison() == nil && GrowthHistory.changes(from: first, to: other).isEmpty,
      "authorization or scope changes establish a separate baseline")
    for n in 0..<200 {
      history.record(
        GrowthSnapshot(
          id: UUID(), date: Date().addingTimeInterval(Double(n) * 2000), coverage: "fixed",
          values: []), force: true)
    }
    check(history.snapshots.count == 180, "growth retention is bounded")
    let missing = home.appendingPathComponent("Missing")
    _ = try StorageIndex.build(
      at: home.appendingPathComponent("incomplete.sqlite"),
      roots: [StorageRoot(url: missing, title: "未读", kind: .project)],
      auditor: StorageAuditor(home: home), applications: [], cancellation: ScanCancellation())
    check(
      try GrowthHistory.capture(
        index: StorageIndex(url: home.appendingPathComponent("incomplete.sqlite")), applications: []
      ) == nil
        || first.coverage
          != GrowthHistory.capture(
            index: StorageIndex(url: home.appendingPathComponent("incomplete.sqlite")),
            applications: [])?.coverage,
      "incomplete or unavailable coverage cannot compare with a read scope")
    let dir = render.deletingLastPathComponent()
    try fm.removeItem(at: dir)
    try index.refresh(urls: [dir], applications: [])
    check(
      try index.item(at: render) == nil && index.page(search: "cache.dvcc").total == 0,
      "directory removal deletes all indexed descendants")
    _ = try file("Movies/CacheClip/Travel/cache.dvcc")
    try index.refresh(urls: [dir], applications: [])
    check(try index.item(at: render) != nil, "restored directory is recursively indexed again")

    let appDir = home.appendingPathComponent("Applications/Fixture.app")
    let id = "local.fixture." + UUID().uuidString
    try fm.createDirectory(
      at: appDir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let plist: [String: Any] = [
      "CFBundleIdentifier": id, "CFBundleName": "Fixture", "CFBundleShortVersionString": "1.0",
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
      to: appDir.appendingPathComponent("Contents/Info.plist"))
    _ = try file("Applications/Fixture.app/Contents/binary")
    _ = try file("Library/Caches/" + id + "/entry.cache")
    _ = try file("Library/Application Support/SharedVendor/keep.project")
    let apps = AppInventory.collect(
      home: home, roots: [home.appendingPathComponent("Applications")])
    check(
      apps.count == 1 && apps[0].id == id, "application inventory reads an exact bundle identifier")
    let inspection = AppInventory.inspect(apps[0], home: home, cancellation: ScanCancellation())
    check(
      inspection.items.count == 2, "application inspection includes body and exact private cache")
    check(
      !inspection.items.contains { $0.url.path.contains("SharedVendor") },
      "shared vendor data is not guessed into an uninstall plan")
    check(
      !ManagedLocations.validID("com.apple.finder")
        && !ManagedLocations.validID("local.fishyj.qingsweep")
        && !ManagedLocations.validID("../escape"),
      "system, current app and path-like identifiers cannot enter managed deletion")
    let planned = inspection.items.first { $0.url.path == appDir.path }!
    let result = await ManagedTrash.move([planned], home: home, cancellation: ScanCancellation()) {
      _ in
    }
    trash += result.records.map(\.trashed)
    check(
      result.records.count == 1 && result.errors.isEmpty && FileStamp.read(appDir) == nil,
      "confirmed disposable app directory moves to real Trash")
    let record = result.records[0]
    _ = chmod(record.trashed.path, mode_t(record.stamp!.mode & 0o777))
    check(
      RestoreAvailability.check(record: record, policy: SafetyPolicy(home: home)) == .available,
      "managed directory appears in batch recovery")
    try fm.createDirectory(at: appDir, withIntermediateDirectories: false)
    check(
      rejects { try TrashService(policy: SafetyPolicy(home: home)).restore(record) },
      "directory recovery refuses an occupied destination")
    try fm.removeItem(at: appDir)
    try TrashService(policy: SafetyPolicy(home: home)).restore(record)
    check(
      FileStamp.read(appDir.appendingPathComponent("Contents/binary")) != nil,
      "managed directory recovery preserves its contents")
    let fresh = AppInventory.inspect(apps[0], home: home, cancellation: ScanCancellation()).items
      .first { $0.url.path == appDir.path }!
    let second = await ManagedTrash.move([fresh], home: home, cancellation: ScanCancellation()) {
      _ in
    }
    trash += second.records.map(\.trashed)
    if second.records.isEmpty { print("SECOND MANAGED ERRORS:", second.errors) }
    check(second.records.count == 1, "freshly restored app can be reviewed and moved again")
    let changedRecord = second.records[0]
    try Data([3, 4, 5]).write(to: changedRecord.trashed.appendingPathComponent("Contents/binary"))
    check(
      rejects { try TrashService(policy: SafetyPolicy(home: home)).restore(changedRecord) },
      "changed content inside a trashed app cannot silently restore")
    check(
      FileStamp.read(appDir) == nil, "failed directory recovery never creates a partial destination"
    )
    let restoreFile = try file("Downloads/restore-metadata.txt")
    let regular = TrashService(policy: SafetyPolicy(home: home)).move(
      [item(restoreFile)], manualConsent: ManualCleanupConsent(reviewedItems: [item(restoreFile)]))
    trash += regular.records.map(\.trashed)
    let regularRecord = regular.records[0]
    _ = chmod(regularRecord.trashed.path, mode_t(regularRecord.stamp!.mode & 0o777))
    check(
      FileStamp.read(regularRecord.trashed) != regularRecord.stamp,
      "metadata-only changes reproduce the native Trash restore failure")
    try TrashService(policy: SafetyPolicy(home: home)).restore(regularRecord)
    check(
      FileStamp.read(restoreFile) != nil,
      "content-verified restoration tolerates metadata-only ctime updates")
    let modified = TrashService(policy: SafetyPolicy(home: home)).move(
      [item(restoreFile)], manualConsent: ManualCleanupConsent(reviewedItems: [item(restoreFile)]))
    trash += modified.records.map(\.trashed)
    let modifiedRecord = modified.records[0]
    try Data(repeating: 66, count: 8192).write(to: modifiedRecord.trashed, options: [])
    let oldDate = Date(
      timeIntervalSince1970: Double(modifiedRecord.stamp!.modifiedSeconds) + Double(
        modifiedRecord.stamp!.modifiedNanos) / 1e9)
    try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: modifiedRecord.trashed.path)
    check(
      rejects { try TrashService(policy: SafetyPolicy(home: home)).restore(modifiedRecord) },
      "content changes remain blocked even if size and modification time are restored")
    let unknown = try file("Library/Logs/org.missing.fixture/session.log")
    let leftovers = AppInventory.possibleLeftovers(
      home: home, installed: apps, cancellation: ScanCancellation())
    check(
      leftovers.0.contains { $0.url == unknown.deletingLastPathComponent() }
        && !leftovers.0.contains { $0.bundleID == id },
      "possible leftovers exclude installed exact identifiers")
    check(
      rejects { _ = try FileTree.read(home, limit: 1) },
      "incomplete directory reads cannot become deletion snapshots")

    let source = try file("Documents/Archive/clip.mov", content)
    let destination = home.appendingPathComponent("ArchiveTarget")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let archived = try ArchiveCopy.copy(
      sources: [source.deletingLastPathComponent()], destination: destination,
      cancellation: ScanCancellation())
    check(
      archived.files.count == 1 && FileStamp.read(source) != nil,
      "real ditto archive retains the source and records verified files")
    check(
      try Data(contentsOf: archived.files[0].destination) == content,
      "archived content matches byte-for-byte")
    check(
      try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).filter {
        $0.lastPathComponent.hasSuffix("未完成")
      }.isEmpty, "only a verified archive receives its final directory name")
    let archivedAgain = try ArchiveCopy.copy(
      sources: [source], destination: destination, cancellation: ScanCancellation())
    check(
      archivedAgain.root != archived.root && FileStamp.read(archived.root) != nil,
      "repeated archive never merges or overwrites an existing destination")
    let candidates = try ArchiveCopy.cleanupCandidates(
      archived, home: home, cancellation: ScanCancellation())
    check(
      candidates.0.count == 1 && candidates.0[0].assessment.requiresIndividualConfirmation
        && candidates.1[source.path] != nil,
      "verified source cleanup remains manual with a retained-copy guard")
    try Data([9, 8, 7]).write(to: archived.files[0].destination)
    check(
      rejects {
        _ = try ArchiveCopy.cleanupCandidates(
          archived, home: home, cancellation: ScanCancellation())
      }, "changed archive prevents source cleanup")
    let bad = Commands17()
    bad.responses = [ToolCommandResult(status: 1, output: "fixture failure")]
    check(
      rejects {
        _ = try ArchiveCopy.copy(
          sources: [source], destination: destination, cancellation: ScanCancellation(),
          commands: bad)
      }, "copy failure is not marked verified")
    check(try Data(contentsOf: source) == content, "copy failure leaves source bytes intact")
    check(
      rejects {
        _ = try ArchiveCopy.copy(
          sources: [source], destination: destination, cancellation: cancelled)
      }, "archive cancellation is honored before copying")
    var identities = 0
    check(
      rejects {
        _ = try ArchiveCopy.copy(
          sources: [source], destination: destination, cancellation: ScanCancellation(),
          volumeIdentity: { _ in
            identities += 1
            return identities == 1 ? "disk-A" : "disk-B"
          })
      }, "volume identity change stops an archive")
    let installedID = "local.qingsweep.fresh." + UUID().uuidString
    let freshInfo = try file(
      "Applications/Fresh.app/Contents/Info.plist",
      try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": installedID, "CFBundleName": "Fresh"],
        format: .xml, options: 0))
    _ = try file("Library/Caches/" + installedID + "/entry")
    model.workbench.applications = []
    model.workbench.findLeftovers()
    for _ in 0..<1000 {
      if !model.workbench.busy { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    check(
      model.workbench.applications.contains { $0.id == installedID }
        && !model.workbench.leftovers.contains { $0.bundleID == installedID },
      "leftover discovery refreshes installed identities even from an empty application list")
    check(
      FileStamp.read(freshInfo) != nil, "leftover discovery does not modify installed app contents")
    let sparse = try file("Documents/sparse-archive-fixture")
    let sparseHandle = try FileHandle(forWritingTo: sparse)
    try sparseHandle.truncate(atOffset: 1_000_000_000_000)
    try sparseHandle.close()
    check(
      rejects {
        _ = try ArchiveCopy.copy(
          sources: [sparse], destination: destination, cancellation: ScanCancellation())
      }, "insufficient destination space rejects a sparse fixture before copying")
    try fm.removeItem(at: sparse)
    let outside = home.appendingPathComponent("Documents/Archive/external-link")
    try fm.createSymbolicLink(at: outside, withDestinationURL: b)
    check(
      rejects {
        _ = try ArchiveCopy.copy(
          sources: [source.deletingLastPathComponent()], destination: destination,
          cancellation: ScanCancellation())
      }, "external symlinks cannot masquerade as a verified backup")
    check(
      rejects {
        _ = try ArchiveCopy.copy(
          sources: [home.appendingPathComponent("Documents")],
          destination: source.deletingLastPathComponent(), cancellation: ScanCancellation())
      }, "archive target inside its source is rejected")
    check(FileStamp.read(source) != nil, "all archive error scenarios retain the original")

    let label = "local.qingsweep.fixture." + UUID().uuidString
    let agent = home.appendingPathComponent("Library/LaunchAgents/fixture.plist")
    try fm.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: [
        "Label": label, "ProgramArguments": ["/usr/bin/true"], "RunAtLoad": false,
      ], format: .xml, options: 0
    ).write(to: agent)
    let mock = Commands17()
    mock.responses = [ToolCommandResult(status: 0, output: "")]
    let entries = StartupItems.collect(
      home: home, receipts: [], commands: mock, cancellation: ScanCancellation())
    check(
      entries.0.count == 1 && entries.0[0].loaded,
      "startup inventory uses command status rather than parsing launchctl text")
    let entry = entries.0[0]
    let target = "gui/\(getuid())/" + label
    let disable = Commands17()
    disable.responses = [
      .init(status: 0, output: ""), .init(status: 0, output: ""), .init(status: 0, output: ""),
    ]
    let receipt = try StartupItems.set(
      entry, enabled: false, home: home, commands: disable, cancellation: ScanCancellation())
    check(
      receipt.disabled
        && disable.calls.map { Array($0.dropFirst()) } == [
          ["disable", target], ["print", target], ["bootout", target],
        ], "disable persists and bootout targets only the exact service")
    check(
      !disable.calls.contains { Array($0.dropFirst()) == ["bootout", "gui/\(getuid())"] },
      "no startup operation can boot out the entire user domain")
    check(
      FileStamp.read(agent) == entry.stamp, "startup operations do not rewrite the user's plist")
    let disabled = StartupEntry(
      label: label, url: agent, stamp: entry.stamp, program: entry.program, loaded: false,
      disabledBySweep: true)
    let enable = Commands17()
    enable.responses = [
      .init(status: 0, output: ""), .init(status: 1, output: ""), .init(status: 0, output: ""),
    ]
    _ = try StartupItems.set(
      disabled, enabled: true, home: home, commands: enable, cancellation: ScanCancellation())
    check(
      enable.calls.last == ["/bin/launchctl", "bootstrap", "gui/\(getuid())", agent.path],
      "enable bootstraps the validated exact plist")
    let fail = Commands17()
    fail.responses = [
      .init(status: 0, output: ""), .init(status: 1, output: ""),
      .init(status: 5, output: "fixture failure"),
    ]
    check(
      rejects {
        _ = try StartupItems.set(
          disabled, enabled: true, home: home, commands: fail, cancellation: ScanCancellation())
      }, "failed bootstrap reports failure")
    check(
      fail.calls.last == ["/bin/launchctl", "disable", target],
      "failed enable rolls back to the previous disabled state")
    check(
      !StartupItems.safeLabel("com.apple.finder")
        && !StartupItems.safeLabel("com.security.endpoint") && !StartupItems.safeLabel("bad/label"),
      "system, security and malformed startup services stay outside scope")
    let live = try SystemToolCommands().run(
      "/bin/launchctl", ["bootstrap", "gui/\(getuid())", agent.path])
    if live.status == 0 {
      defer {
        _ = try? SystemToolCommands().run("/bin/launchctl", ["bootout", target])
        _ = try? SystemToolCommands().run("/bin/launchctl", ["enable", target])
      }
      let actual = StartupItems.collect(home: home, receipts: [], cancellation: ScanCancellation())
        .0.first!
      _ = try StartupItems.set(actual, enabled: false, home: home, cancellation: ScanCancellation())
      check(
        try SystemToolCommands().run("/bin/launchctl", ["print", target]).status != 0,
        "live disposable LaunchAgent is unloaded by its exact identifier")
      let stopped = StartupEntry(
        label: label, url: agent, stamp: entry.stamp, program: entry.program, loaded: false,
        disabledBySweep: true)
      _ = try StartupItems.set(stopped, enabled: true, home: home, cancellation: ScanCancellation())
      check(
        try SystemToolCommands().run("/bin/launchctl", ["print", target]).status == 0,
        "live disposable LaunchAgent is re-enabled and loaded")
    } else {
      print("LIVE STARTUP FIXTURE UNAVAILABLE: " + String(live.output.prefix(200)))
    }

    let summaries = (0..<100).map { n in
      AppStorageSummary(id: String(n), title: "App \(n)", dataBytes: Int64(n + 1) * 4096)
    }
    let blocks = SpaceMapLayout.blocks(summaries, limit: 35)
    let rect = CGRect(x: 0, y: 0, width: 800, height: 400)
    let tiles = SpaceMapLayout.tiles(blocks, in: rect)
    check(
      blocks.count == 36
        && blocks.reduce(0) { $0 + $1.bytes } == summaries.reduce(0) { $0 + $1.bytes },
      "space map aggregates every smaller category without dropping bytes")
    let area = tiles.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
    check(
      abs(area - 320000) < 0.01 && tiles.allSatisfy { rect.contains($0.rect) },
      "space tiles cover the complete chart with bounded rectangles")
    var overlap = false
    for i in tiles.indices {
      for j in tiles.indices where j > i {
        if tiles[i].rect.intersection(tiles[j].rect).width > 0.001
          && tiles[i].rect.intersection(tiles[j].rect).height > 0.001
        {
          overlap = true
        }
      }
    }
    check(!overlap, "space tiles do not overlap")
    check(
      SpaceMapLayout.tiles([], in: rect).isEmpty && SpaceMapLayout.tiles(blocks, in: .zero).isEmpty,
      "empty space map is safe")
    var trend = MemoryTrend()
    var s = SystemSnapshot()
    s.timestamp = Date(timeIntervalSince1970: 100)
    s.processes = [MemoryProcess(name: "Editor", bytes: 1000, count: 1)]
    trend.record(s)
    s.timestamp = Date(timeIntervalSince1970: 115)
    s.processes = [MemoryProcess(name: "Editor", bytes: 2000, count: 1)]
    trend.record(s)
    check(
      trend.delta(for: "Editor") == 1000,
      "memory trend compares application RSS over elapsed samples")
    for _ in 0..<200 { trend.record(s) }
    check(
      trend.samples.count == 120 && !model.workbench.menuEnabled,
      "memory ring is bounded and menu monitor is opt-in")
    print("\(count) release 1.7 checks passed; all file operations used disposable fixtures.")
  }
}
