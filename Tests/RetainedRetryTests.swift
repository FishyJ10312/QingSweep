import Foundation

@main struct RetainedRetryTests {
  static func main() throws {
    let fm = FileManager.default
    let home = URL(fileURLWithPath: "/Users/Shared/qingsweep-retained-retry-" + UUID().uuidString)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: home) }
    let policy = SafetyPolicy(home: home)
    let classifier = FileClassifier(policy: policy, context: InspectionContext())
    var checks = 0
    func check(_ value: @autoclosure () throws -> Bool, _ name: String) {
      guard (try? value()) == true else { fputs("FAIL: " + name + "\n", stderr); exit(1) }
      checks += 1
      print("PASS: " + name)
    }
    let folder = home.appendingPathComponent("Documents")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("edited.mov")
    let keeper = folder.appendingPathComponent("retained.mov")
    try Data(repeating: 1, count: 8192).write(to: source)
    try Data(repeating: 1, count: 8192).write(to: keeper)
    let original = ScanItem(
      url: source, root: home, stamp: FileStamp.read(source)!,
      assessment: FileAssessment(
        category: .video, disposition: .protected, owner: "Fixture", group: "Fixture",
        reason: "Fixture", evidence: "Fixture", ruleID: "archive-verified-source"))
    let retained = RetainedCopy(url: keeper, stamp: FileStamp.read(keeper)!)
    let reference = CleanupRetryTarget(item: original, retainedCopy: retained)
    try Data(repeating: 2, count: 16384).write(to: source)
    var editedRejected = false
    do {
      let accepted = try reference.recheck(policy: policy, classifier: classifier)
      var boundaries = 0
      _ = TrashService(policy: policy).move(
        [accepted], manualConsent: ManualCleanupConsent(reviewedItems: [accepted]),
        beforeMove: { _ in
          try retained.validate()
          boundaries += 1
          if boundaries == 3 { throw ToolFailure.invalid("Disposable probe stops before Trash") }
        })
      print("REGRESSION: changed source accepted through \(boundaries) guarded cleanup boundaries; no Trash operation performed")
    } catch { editedRejected = true }
    check(editedRejected, "changed-length source cannot reuse an older retained-copy proof on retry")
    check(try Data(contentsOf: source) == Data(repeating: 2, count: 16384), "rejected retry leaves the edited source bytes untouched")
    func rejects(_ action: () throws -> Void) -> Bool {
      do { try action(); return false } catch { return true }
    }
    func fixture(_ name: String) throws -> (ScanItem, RetainedCopy, CleanupRetryTarget) {
      let source = folder.appendingPathComponent(name + ".mov")
      let keeper = folder.appendingPathComponent(name + "-retained.mov")
      try Data(repeating: 7, count: 8192).write(to: source)
      try Data(repeating: 7, count: 8192).write(to: keeper)
      let item = ScanItem(
        url: source, root: home, stamp: FileStamp.read(source)!,
        assessment: classifier.assess(source, stamp: FileStamp.read(source)!))
      let kept = RetainedCopy(url: keeper, stamp: FileStamp.read(keeper)!)
      return (item, kept, CleanupRetryTarget(item: item, retainedCopy: kept))
    }
    // Exercise the final production guards, stopping immediately before any Trash operation.
    func guardedBoundary(_ item: ScanItem, keeper: RetainedCopy, consent: ManualCleanupConsent?) -> Int {
      var boundaries = 0
      let result = TrashService(policy: policy).move(
        [item], manualConsent: consent,
        beforeMove: { _ in
          try keeper.validate()
          boundaries += 1
          if boundaries == 3 { throw ToolFailure.invalid("Disposable probe stops before Trash") }
        })
      check(result.records.isEmpty && FileStamp.read(item.url) != nil, "guarded retry probe performs no Trash operation")
      return boundaries
    }

    try Data(repeating: 3, count: 8192).write(to: source)
    check(
      rejects { _ = try reference.recheck(policy: policy, classifier: classifier) },
      "same-size changed source bytes cannot reuse the older retained-copy proof")

    let unchanged = try fixture("unchanged")
    let verified = try unchanged.2.recheck(policy: policy, classifier: classifier)
    check(verified.stamp == unchanged.0.stamp, "unchanged source and keeper retain a valid retry proof")
    check(
      guardedBoundary(verified, keeper: unchanged.1, consent: nil) == 0,
      "retained-copy proof never bypasses manual consent at cleanup")
    check(
      guardedBoundary(verified, keeper: unchanged.1, consent: ManualCleanupConsent(reviewedItems: [verified])) == 3,
      "unchanged equal contents pass every guarded cleanup boundary with fresh consent")

    let metadata = try fixture("metadata-only")
    try fm.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: Double(metadata.0.stamp.modifiedSeconds) - 60)],
      ofItemAtPath: metadata.0.url.path)
    let metadataRetry = try metadata.2.recheck(policy: policy, classifier: classifier)
    check(
      metadataRetry.stamp != metadata.0.stamp && metadataRetry.assessment.requiresIndividualConfirmation,
      "same-content source metadata changes can be re-proved without weakening protection")
    check(
      !ManualCleanupConsent(reviewedItems: [metadata.0]).permits(metadataRetry),
      "a metadata-only retry cannot reuse consent for the previous source stamp")
    check(
      guardedBoundary(metadataRetry, keeper: metadata.1, consent: ManualCleanupConsent(reviewedItems: [metadataRetry])) == 3,
      "a metadata-only retry reaches cleanup only with its newly verified stamp and consent")

    let missing = try fixture("missing-keeper")
    try fm.removeItem(at: missing.1.url)
    check(
      rejects { _ = try missing.2.recheck(policy: policy, classifier: classifier) },
      "missing keeper rejects retry before selection")
    let changed = try fixture("changed-keeper")
    try Data(repeating: 8, count: 8192).write(to: changed.1.url)
    check(
      rejects { _ = try changed.2.recheck(policy: policy, classifier: classifier) },
      "changed keeper rejects retry even when its length still matches the source")

    let laterSource = try fixture("source-after-proof")
    let sourceProof = try laterSource.2.recheck(policy: policy, classifier: classifier)
    try Data(repeating: 9, count: 8192).write(to: laterSource.0.url)
    check(
      guardedBoundary(sourceProof, keeper: laterSource.1, consent: ManualCleanupConsent(reviewedItems: [sourceProof])) == 0,
      "source changes after retry proof are stopped by the immutable stamp check")
    let laterKeeper = try fixture("keeper-after-proof")
    let keeperProof = try laterKeeper.2.recheck(policy: policy, classifier: classifier)
    try Data(repeating: 9, count: 8192).write(to: laterKeeper.1.url)
    check(
      guardedBoundary(keeperProof, keeper: laterKeeper.1, consent: ManualCleanupConsent(reviewedItems: [keeperProof])) == 0,
      "keeper changes after retry proof are stopped by the retained-copy guard")

    let cancellation = ScanCancellation()
    cancellation.cancel()
    var cancelled = false
    do {
      _ = try unchanged.2.recheck(policy: policy, classifier: classifier, cancellation: cancellation)
    } catch ToolFailure.cancelled { cancelled = true } catch {}
    check(cancelled, "cancelled retry never returns a retained-copy cleanup candidate")

    let plain = try fixture("without-keeper")
    let plainReference = CleanupRetryTarget(item: plain.0)
    try Data(repeating: 10, count: 16384).write(to: plain.0.url)
    let plainRetry = try plainReference.recheck(policy: policy, classifier: classifier)
    check(
      plainRetry.stamp.size == 16384 && plainRetry.assessment.requiresIndividualConfirmation,
      "retry without a retained-copy condition still reclassifies the current protected source")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(unchanged.2)) as! [String: Any]
    legacy.removeValue(forKey: "blockingAppIDs")
    legacy.removeValue(forKey: "requiresClosedApps")
    let legacyReference = try JSONDecoder().decode(
      CleanupRetryTarget.self, from: JSONSerialization.data(withJSONObject: legacy))
    check(
      try legacyReference.recheck(policy: policy, classifier: classifier).stamp == verified.stamp,
      "legacy Codable retry receipts retain their existing format and can re-prove equal contents")
    print("\(checks) retained-copy retry checks passed; disposable fixtures only, no Trash operations.")
  }
}
