import AppKit
import Foundation

struct Environment18: CleanupApplicationEnvironment {
  var fail = false
  func usage(for items: [ScanItem]) async throws -> CleanupUsage {
    if fail { throw CleanupPreparationError.usageUnavailable }
    return CleanupUsage()
  }
  func requestQuit(_ app: CleanupApplication) -> Bool { false }
}
@main struct Release18Tests {
  @MainActor static func main() async throws {
    setbuf(stdout, nil)
    _ = NSApplication.shared
    let fm = FileManager.default
    let home = URL(fileURLWithPath: "/Users/Shared/qingsweep-release18-" + UUID().uuidString)
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
    @discardableResult func file(_ name: String, size: Int = 8192) throws -> URL {
      let url = home.appendingPathComponent(name)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 43, count: size).write(to: url)
      return url
    }
    func item(_ url: URL, category: FileCategory = .video, rule: String = "fixture") -> ScanItem {
      ScanItem(
        url: url, root: home, stamp: FileStamp.read(url)!,
        assessment: FileAssessment(
          category: category, disposition: .protected, owner: "Fixture", group: "Fixture",
          reason: "请核对用途", evidence: "夹具", ruleID: rule))
    }
    func wait(_ done: () -> Bool) async {
      for _ in 0..<1000 {
        if done() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
    }
    let video = try file("Documents/clip.mov")
    let project = try file("Documents/edit.drp")
    let proxy = try file("Movies/ProxyMedia/clip.mov")
    let impacts = CleanupImpact.build([item(video), item(project, category: .project), item(proxy)])
    check(
      impacts.count == 3 && impacts.reduce(0) { $0 + $1.count } == 3,
      "impact summary separates original media, projects and proxies")
    check(
      impacts.reduce(0) { $0 + $1.bytes } == 3 * FileStamp.read(video)!.allocated,
      "impact totals count each selected file once")
    check(
      impacts.first { $0.id == "proxy" }?.consequence.contains("原片") == true,
      "proxy consequence does not promise the original exists")
    let installer = try file("Downloads/setup.dmg")
    check(
      CleanupImpact.build([item(installer, category: .installer)])[0].consequence.contains("回退"),
      "installer impact explains future reinstall and rollback")
    check(
      CleanupImpact.build([item(video, rule: "archive-verified-source")])[0].id == "archived",
      "archive source impact retains the verified-copy requirement")
    check(CleanupImpact.build([]).isEmpty, "empty impact summary is safe")
    let retained = try file("Documents/keep.mov")
    let reference = CleanupRetryTarget(
      item: item(video), retainedCopy: RetainedCopy(url: retained, stamp: FileStamp.read(retained)!)
    )
    let encoded = try JSONEncoder().encode(reference)
    let decoded = try JSONDecoder().decode(CleanupRetryTarget.self, from: encoded)
    check(
      decoded.retainedCopy?.url == retained && decoded.manualRequired,
      "retry metadata preserves explicit retained-copy and manual-consent requirements")
    let unguardedReference = CleanupRetryTarget(item: item(video))
    try Data(repeating: 5, count: 16384).write(to: video)
    check(
      rejects {
        _ = try decoded.recheck(
          policy: SafetyPolicy(home: home),
          classifier: FileClassifier(policy: SafetyPolicy(home: home), context: InspectionContext()))
      }, "edited source cannot reuse a retained-copy proof for different contents")
    let current = try unguardedReference.recheck(
      policy: SafetyPolicy(home: home),
      classifier: FileClassifier(policy: SafetyPolicy(home: home), context: InspectionContext()))
    check(
      current.stamp.size == 16384 && current.assessment.requiresIndividualConfirmation,
      "retry reclassifies the actual current file without carrying consent")
    var appAssessment = item(video).assessment
    appAssessment.blockingAppIDs = ["local.fixture.editor"]
    appAssessment.needsClosedApps = true
    let appGuard = CleanupRetryTarget(
      item: ScanItem(
        url: video, root: home, stamp: FileStamp.read(video)!, assessment: appAssessment))
    let guardedAgain = try appGuard.recheck(
      policy: SafetyPolicy(home: home),
      classifier: FileClassifier(policy: SafetyPolicy(home: home), context: InspectionContext()))
    check(
      guardedAgain.assessment.blockingAppIDs.contains("local.fixture.editor")
        && guardedAgain.assessment.needsClosedApps,
      "retry retains previously identified application-usage requirements")
    try fm.removeItem(at: retained)
    check(
      rejects {
        _ = try decoded.recheck(
          policy: SafetyPolicy(home: home),
          classifier: FileClassifier(policy: SafetyPolicy(home: home), context: InspectionContext())
        )
      }, "missing retained copy blocks retry before selection")
    let target = try file("Documents/retry.mov")
    let model = AppModel(home: home, loadSavedScan: false, startTimer: false)
    model.cleanupEnvironment = Environment18(fail: true)
    model.reviewToolFiles([item(target)], title: "重试夹具")
    model.requestReviewedMove()
    model.manualReviewAcknowledged = true
    model.confirmManualCleanup()
    await wait { !model.mutating }
    let first = model.cleanupReceipts[0]
    check(
      first.movedCount == 0 && first.retryFiles?.count == 1 && FileStamp.read(target) != nil,
      "failed cleanup persists precisely the unprocessed file")
    check(
      model.operationOutcome?.completed == 0 && model.operationOutcome?.receipt?.id == first.id,
      "structured result exposes failure without losing the receipt")
    model.retryCleanup(first)
    await wait { !model.mutating }
    check(
      model.showingReview && model.review.count == 1 && !model.manualReviewAcknowledged
        && model.reviewNotice != nil, "retry builds a fresh review and clears prior acknowledgement"
    )
    check(
      FileStamp.read(target) != nil && model.history.isEmpty,
      "rechecking does not move or close anything")
    model.requestReviewedMove()
    check(
      model.showingManualConfirmation && !model.reviewConfirmed,
      "retry still enters a second confirmation for media")
    model.cleanupEnvironment = Environment18()
    model.manualReviewAcknowledged = true
    model.confirmManualCleanup()
    await wait { !model.mutating }
    trash += model.history.map(\.trashed)
    check(
      model.history.count == 1 && model.operationOutcome?.completed == 1,
      "explicitly confirmed retry moves only the reviewed fixture")
    check(
      model.cleanupReceipts[0].retryOf == first.id
        && model.cleanupReceipts.first { $0.id == first.id }?.retryCount == 0,
      "successful retry resolves the parent pending list and links both batches")
    check(
      model.operationOutcome?.receipt?.retryCount == 0,
      "successful result has no stale retry selection")
    let record = model.history[0]
    try Data([8]).write(to: target)
    model.operationOutcome = nil
    model.restoreBatch([record])
    await wait { !model.mutating }
    check(
      try model.operationOutcome?.restoreRemaining.count == 1
        && Data(contentsOf: target) == Data([8]),
      "partial restore records the blocked target without overwriting it")
    try fm.removeItem(at: target)
    let restoreOutcome = model.operationOutcome!
    model.retryRestore(restoreOutcome)
    await wait { !model.mutating }
    check(
      model.history.isEmpty && model.operationOutcome?.completed == 1
        && FileStamp.read(target) != nil,
      "restore retry rechecks and restores after the conflict is removed")
    if var savedOutcome = model.operationOutcome {
      savedOutcome.saveFailure = "夹具保存待重试"
      model.operationOutcome = savedOutcome
    }
    model.retrySaveHistory()
    check(
      model.operationOutcome?.saveFailure == nil
        && FileStamp.read(
          home.appendingPathComponent("Library/Application Support/QingSweep/cleanup-receipts.json")
        ) != nil, "saving again clears the result warning after writing durable history")
    let loaded = AppModel(home: home, loadSavedScan: false, startTimer: false)
    check(
      loaded.cleanupReceipts.count == 2
        && loaded.cleanupReceipts.first { $0.id == first.id }?.retryCount == 0,
      "retry resolution survives restart")
    var receiptJSON =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
    for key in ["retryFiles", "retryManaged", "retryOf"] { receiptJSON.removeValue(forKey: key) }
    let old = try JSONDecoder().decode(
      CleanupReceipt.self, from: JSONSerialization.data(withJSONObject: receiptJSON))
    check(
      old.retryCount == 0 && old.movedCount == first.movedCount,
      "old receipts import without inventing retry paths from error text")
    let id = "local.fixture18." + UUID().uuidString
    let privateFile = try file("Library/Caches/" + id + "/cache")
    let managed = ManagedItem(
      url: privateFile.deletingLastPathComponent(), bundleID: id, title: "Cache", role: "缓存",
      tree: try FileTree.read(privateFile.deletingLastPathComponent()))
    var managedReceipt = first
    managedReceipt.retryFiles = []
    managedReceipt.retryManaged = [ManagedRetryTarget(managed)]
    loaded.retryCleanup(managedReceipt)
    await wait { !loaded.mutating }
    check(
      loaded.workbench.showingManagedReview && loaded.workbench.managedReview.count == 1
        && !loaded.workbench.managedAcknowledged,
      "managed retry rebuilds complete directory identity and requires confirmation")
    check(FileStamp.read(privateFile) != nil, "managed retry leaves directory content in place")
    loaded.workbench.showingManagedReview = false
    var ignored = model.preferences
    ignored.ignore(video)
    model.preferences = ignored
    var ignoredReceipt = first
    ignoredReceipt.retryFiles = [CleanupRetryTarget(item: item(video))]
    model.operationOutcome = nil
    model.retryCleanup(ignoredReceipt)
    await wait { !model.mutating }
    check(
      !model.showingReview && model.message?.contains("忽略") == true && FileStamp.read(video) != nil,
      "retry honors items added to the ignore list")
    let progress = OperationProgress(phase: "校验", completedBytes: 200, totalBytes: 100)
    check(
      progress.fraction == 1 && OperationProgress(phase: "复制").fraction == nil,
      "progress clamps measured bytes and never invents copy percentage")
    check(
      formatElapsed(-2) == "0 秒" && formatElapsed(61) == "1 分 1 秒" && formatElapsed(.nan) == "—",
      "elapsed time safely handles clock changes")
    var delivered: [OperationProgress] = []
    let relay = OperationProgressRelay { delivered.append($0) }
    relay.send(OperationProgress(phase: "扫描"))
    for _ in 0..<100 { relay.send(OperationProgress(phase: "扫描")) }
    relay.send(OperationProgress(phase: "校验"))
    relay.send(OperationProgress(phase: "校验", completedBytes: 10, totalBytes: 10))
    check(
      delivered.count == 3,
      "progress delivery is throttled while preserving phase and completion updates")
    let taskURL = home.appendingPathComponent("journal.json")
    let plan = ToolTaskPlan(kind: .media, roots: [proxy.deletingLastPathComponent()])
    let running = ToolTaskRecord(
      id: UUID(), started: Date(), ended: nil, plan: plan, status: .running,
      progress: OperationProgress(phase: "扫描"))
    try ToolTaskStore.save([running], to: taskURL)
    let interrupted = try ToolTaskStore.load(taskURL)
    check(
      interrupted[0].status == .interrupted && interrupted[0].plan.roots == plan.roots,
      "interrupted jobs retain the exact scope without automatic file operations")
    try ToolTaskStore.save(
      (0..<70).map { _ in
        ToolTaskRecord(
          id: UUID(), started: Date(), ended: nil, plan: plan, status: .running,
          progress: OperationProgress(phase: "扫描"))
      }, to: taskURL)
    check(
      try ToolTaskStore.load(taskURL).count == 50, "task journal retains a bounded recent history")
    let tools = model.workbench
    tools.scanMedia(roots: [home.appendingPathComponent("Movies")])
    await wait { !tools.busy }
    check(
      tools.tasks.first?.plan.kind == .media && tools.tasks.first?.status == .completed
        && tools.mediaSelected.isEmpty,
      "media job persists completion and keeps all media unselected")
    let persisted = try ToolTaskStore.load(
      home.appendingPathComponent("Library/Application Support/QingSweep/task-history.json"))
    check(persisted.first?.id == tools.tasks.first?.id, "finished tasks survive restart")
    tools.scanMedia(roots: [home.appendingPathComponent("Movies")])
    tools.stop()
    await wait { !tools.busy }
    check(
      tools.tasks.first?.status == .cancelled && tools.media.cancelled,
      "stopped jobs cannot be reported as successful")
    let oldProgress = tools.progressData
    try await Task.sleep(nanoseconds: 200_000_000)
    check(
      tools.progress.isEmpty && tools.progressData == oldProgress,
      "late worker progress cannot overwrite a completed or stopped job")
    let targetDir = home.appendingPathComponent("ArchiveTarget")
    try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
    let archivePlan = ToolTaskPlan(kind: .archive, roots: [project], destination: targetDir)
    let previous = ToolTaskRecord(
      id: UUID(), started: Date(), ended: Date(), plan: archivePlan, status: .failed,
      progress: OperationProgress(phase: "复制"))
    tools.repeatTask(previous)
    check(
      try !tools.busy && tools.archiveSources == [project] && tools.archiveDestination == targetDir
        && fm.contentsOfDirectory(atPath: targetDir.path).isEmpty,
      "archive repeat only restores settings and never starts another copy")
    var archiveProgress: [OperationProgress] = []
    let archive = try ArchiveCopy.copy(
      sources: [project], destination: targetDir, cancellation: ScanCancellation(),
      progressData: { archiveProgress.append($0) })
    check(
      archiveProgress.contains { $0.phase == "复制" && $0.fraction == nil },
      "archive copy reports a truthful indeterminate phase")
    check(
      archiveProgress.contains { $0.phase == "内容校验" && $0.fraction == 1 },
      "archive hashes report exact source and destination verification bytes")
    check(
      archiveProgress.last?.completedBytes == FileStamp.read(project)!.size * 2,
      "archive verification progress counts data forks on both sides")
    let candidates = try ArchiveCopy.cleanupCandidates(
      archive, home: home, cancellation: ScanCancellation())
    check(
      candidates.0.count == 1 && candidates.0[0].root.path != project.path
        && candidates.0[0].assessment.requiresIndividualConfirmation,
      "single-file archives can enter source review using the parent scope")
    check(FileStamp.read(project) != nil, "archiving and source review retain the original")
    let cancelFinalize = ScanCancellation()
    check(
      rejects {
        _ = try ArchiveCopy.copy(
          sources: [project], destination: targetDir, cancellation: cancelFinalize,
          progressData: { if $0.phase == "保存校验记录" { cancelFinalize.cancel() } })
      }, "cancellation before archive commit cannot publish a completed archive")

    check(
      rejects { _ = try SystemToolCommands(timeout: 0.03).run("/bin/sleep", ["0.3"]) },
      "ordinary probes retain a bounded timeout")
    check(
      try SystemToolCommands(timeout: nil).run("/bin/sleep", ["0.2"]).status == 0,
      "unbounded cancellable copy runner can outlive a short probe deadline")
    check(
      rejects {
        _ = try SystemToolCommands(timeout: nil, onPoll: { throw ToolFailure.disconnected }).run(
          "/bin/sleep", ["3"])
      }, "volume-check failure stops only the owned subprocess")
    let cancel = ScanCancellation()
    cancel.cancel()
    check(
      rejects {
        _ = try SystemToolCommands(timeout: nil).run("/bin/sleep", ["3"], cancellation: cancel)
      }, "unbounded runner still honors explicit cancellation")
    let badHome = home.appendingPathComponent("BrokenTasks")
    let bad = badHome.appendingPathComponent(
      "Library/Application Support/QingSweep/task-history.json")
    try fm.createDirectory(at: bad.deletingLastPathComponent(), withIntermediateDirectories: true)
    let corrupt = Data("{broken".utf8)
    try corrupt.write(to: bad)
    let badTools = WorkbenchModel(home: badHome)
    check(badTools.taskLoadIssue != nil, "corrupt task history produces a recoverable local state")
    badTools.scanMedia(roots: [badHome])
    await wait { !badTools.busy }
    check(
      try Data(contentsOf: bad) == corrupt, "new jobs never overwrite unreadable history silently")
    badTools.rebuildTaskHistory()
    check(
      try badTools.taskLoadIssue == nil && ToolTaskStore.load(bad).count == 1,
      "explicit rebuild preserves new in-memory tasks")
    check(
      try fm.contentsOfDirectory(atPath: bad.deletingLastPathComponent().path).contains {
        $0.hasPrefix("task-history-unreadable-")
      }, "rebuild preserves the unreadable original for inspection")
    check(
      [video, project, proxy, privateFile].allSatisfy { FileStamp.read($0) != nil },
      "all unselected creative and managed files remain intact")
    print("\(count) release 1.8 checks passed; only disposable fixtures were used.")
  }
}
