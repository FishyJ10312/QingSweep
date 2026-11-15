import Foundation

struct ArchiveFile: Codable, Identifiable {
  var id: String { source.path }
  let source: URL
  let sourceStamp: FileStamp
  let destination: URL
  let destinationStamp: FileStamp
  let sha256: String
}
struct ArchiveReceipt: Codable, Identifiable {
  let id: UUID
  let date: Date
  let root: URL
  let sourceRoots: [URL]
  let files: [ArchiveFile]
  let bytes: Int64
  let volume: String
}
enum ArchiveCopy {
  static func volumeID(_ url: URL) -> String? {
    guard let device = StorageVolumeUsage.identity(for: url),
      let uuid = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    else { return nil }
    return device + ":" + uuid
  }
  // Destination is always a new child; ditto never merges into a user's existing files.
  static func copy(
    sources: [URL], destination: URL, cancellation: ScanCancellation,
    commands: ToolCommandRunning? = nil,
    volumeIdentity: @escaping (URL) -> String? = ArchiveCopy.volumeID,
    progressData: (OperationProgress) -> Void = { _ in }, progress: (String) -> Void = { _ in }
  ) throws -> ArchiveReceipt {
    guard !sources.isEmpty, LocalFiles.noLinks(destination),
      let targetStamp = FileStamp.read(destination), targetStamp.isDirectory,
      let identity = volumeIdentity(destination)
    else { throw ToolFailure.disconnected }
    let unique = Array(Set(sources)).sorted { $0.path < $1.path }
    guard
      !unique.contains(where: { source in
        SafetyPolicy.within(destination, source)
          || unique.contains(where: { $0 != source && SafetyPolicy.within(source, $0) })
      })
    else { throw ToolFailure.invalid("来源不能相互包含，目标也不能位于来源内") }
    var trees: [FileTree] = []
    for source in unique {
      progressData(OperationProgress(phase: "准备", current: source.lastPathComponent))
      let tree = try FileTree.read(source, cancellation: cancellation)
      for entry in tree.entries where entry.stamp.isSymlink {
        guard let link = entry.link, !link.hasPrefix("/"),
          SafetyPolicy.within(
            entry.url(in: source).deletingLastPathComponent().appendingPathComponent(link)
              .standardizedFileURL, source)
        else { throw ToolFailure.invalid("来源含指向外部的链接，请单独处理") }
      }
      trees.append(tree)
    }
    let required = trees.reduce(Int64(0)) { boundedBytes($0, $1.logicalBytes) }
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: destination.path)
    let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    guard available >= required, available - required > max(16_000_000, required / 20) else {
      throw ToolFailure.insufficientSpace
    }
    let id = UUID()
    let date = Date()
    let name = "轻扫归档-" + String(Int(date.timeIntervalSince1970)) + "-" + id.uuidString.prefix(8)
    let staging = destination.appendingPathComponent(name + "-未完成", isDirectory: true)
    let final = destination.appendingPathComponent(String(name), isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    func checkVolume() throws {
      if cancellation.isCancelled { throw ToolFailure.cancelled }
      guard FileStamp.read(destination)?.device == targetStamp.device,
        volumeIdentity(destination) == identity, LocalFiles.noLinks(destination)
      else { throw ToolFailure.disconnected }
    }
    var verified: [ArchiveFile] = []
    var verifiedBytes: Int64 = 0
    let verificationTotal = required <= Int64.max / 2 ? required * 2 : Int64.max
    var lastPoll = Date.distantPast
    let runner: ToolCommandRunning =
      commands
      ?? SystemToolCommands(
        timeout: nil,
        onPoll: {
          if Date().timeIntervalSince(lastPoll) > 1 {
            try checkVolume()
            lastPoll = Date()
          }
        })
    for (index, tree) in trees.enumerated() {
      try checkVolume()
      progress("复制 · " + tree.root.lastPathComponent)
      progressData(
        OperationProgress(
          phase: "复制", current: tree.root.lastPathComponent, completedItems: index,
          totalItems: trees.count))
      let child = staging.appendingPathComponent(
        String(index + 1) + "-" + tree.root.lastPathComponent)
      let output = try runner.run(
        "/usr/bin/ditto", ["--rsrc", "--extattr", "--acl", "--qtn", tree.root.path, child.path],
        cancellation: cancellation)
      guard output.status == 0 else {
        throw ToolFailure.invalid("复制未完成：" + String(output.output.prefix(200)))
      }
      try checkVolume()
      guard FileStamp.read(tree.root) == tree.stamp else { throw ToolFailure.changed }
      for entry in tree.entries {
        try checkVolume()
        let from = entry.url(in: tree.root)
        let to = entry.url(in: child)
        guard let copied = FileStamp.read(to) else {
          throw ToolFailure.invalid("目标缺少文件：" + entry.relative)
        }
        if entry.stamp.isRegular {
          progress("校验 · " + from.lastPathComponent)
          func advanced(_ amount: Int64) {
            verifiedBytes += amount
            progressData(
              OperationProgress(
                phase: "内容校验", current: from.lastPathComponent, completedBytes: verifiedBytes,
                totalBytes: verificationTotal))
          }
          let original = try LocalFiles.digest(
            from, expected: entry.stamp, cancellation: cancellation, progress: advanced)
          guard copied.isRegular, copied.size == entry.stamp.size,
            try LocalFiles.digest(
              to, expected: copied, cancellation: cancellation, progress: advanced) == original
          else { throw ToolFailure.invalid("内容校验不一致，来源未处理") }
          let destinationFile = final.appendingPathComponent(
            String(index + 1) + "-" + tree.root.lastPathComponent
          ).appendingPathComponent(entry.relative)
          verified.append(
            ArchiveFile(
              source: from, sourceStamp: entry.stamp,
              destination: entry.relative.isEmpty
                ? final.appendingPathComponent(child.lastPathComponent) : destinationFile,
              destinationStamp: copied, sha256: original))
        } else if entry.stamp.isDirectory {
          guard copied.isDirectory, !copied.isSymlink else { throw ToolFailure.changed }
        } else if entry.stamp.isSymlink {
          guard copied.isSymlink,
            try FileManager.default.destinationOfSymbolicLink(atPath: to.path) == entry.link
          else { throw ToolFailure.changed }
        }
      }
      let again = try FileTree.read(tree.root, cancellation: cancellation)
      guard again.stamp == tree.stamp, again.digest == tree.digest else {
        throw ToolFailure.changed
      }
    }
    try checkVolume()
    progressData(
      OperationProgress(
        phase: "保存校验记录", completedBytes: verifiedBytes, totalBytes: verificationTotal))
    let receipt = ArchiveReceipt(
      id: id, date: date, root: final, sourceRoots: unique, files: verified, bytes: required,
      volume: identity)
    try JSONEncoder().encode(receipt).write(
      to: staging.appendingPathComponent("轻扫校验记录.json"), options: .atomic)
    try checkVolume()
    try FileManager.default.moveItem(at: staging, to: final)
    // Rename of a regular-file root does not alter the contained file; record actual final stamps.
    let refreshed = try verified.map { file -> ArchiveFile in
      guard let stamp = FileStamp.read(file.destination), stamp == file.destinationStamp else {
        throw ToolFailure.changed
      }
      return file
    }
    return ArchiveReceipt(
      id: id, date: date, root: final, sourceRoots: unique, files: refreshed, bytes: required,
      volume: identity)
  }
  static func cleanupCandidates(
    _ receipt: ArchiveReceipt, home: URL, cancellation: ScanCancellation
  ) throws -> ([ScanItem], [String: RetainedCopy]) {
    guard volumeID(receipt.root) == receipt.volume, LocalFiles.noLinks(receipt.root) else {
      throw ToolFailure.disconnected
    }
    let policy = SafetyPolicy(home: home)
    let classifier = FileClassifier(policy: policy, context: InspectionContext.collect(home: home))
    var items: [ScanItem] = []
    var guards: [String: RetainedCopy] = [:]
    for file in receipt.files {
      if cancellation.isCancelled { throw ToolFailure.cancelled }
      guard policy.permits(file.source), FileStamp.read(file.source) == file.sourceStamp else {
        continue
      }
      let keep = RetainedCopy(url: file.destination, stamp: file.destinationStamp)
      try keep.validate()
      guard
        try LocalFiles.digest(file.source, expected: file.sourceStamp, cancellation: cancellation)
          == file.sha256,
        try LocalFiles.digest(
          file.destination, expected: file.destinationStamp, cancellation: cancellation)
          == file.sha256
      else { throw ToolFailure.changed }
      let scope = receipt.sourceRoots.first { SafetyPolicy.within(file.source, $0) }
      let root =
        scope.flatMap { FileStamp.read($0)?.isDirectory == true ? $0 : nil }
        ?? file.source.deletingLastPathComponent()
      let base = classifier.assess(file.source, stamp: file.sourceStamp)
      let assessment = FileAssessment(
        category: base.category, disposition: .protected, owner: base.owner, group: base.group,
        reason: "已有校验副本；是否删除来源由你确认。", evidence: base.evidence, ruleID: "archive-verified-source",
        blockingAppIDs: base.blockingAppIDs, needsClosedApps: base.needsClosedApps)
      let item = ScanItem(
        url: file.source, root: root, stamp: file.sourceStamp, assessment: assessment)
      if (try? policy.validate(item)) != nil {
        items.append(item)
        guards[item.id] = keep
      }
    }
    return (items, guards)
  }
}
