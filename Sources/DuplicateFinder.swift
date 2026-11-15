import Foundation

struct DuplicateGroup: Identifiable {
  let id: String
  let files: [ScanItem]
  var copyBytes: Int64 { files.dropFirst().reduce(0) { $0 + $1.bytes } }
}
struct DuplicateResult {
  var groups: [DuplicateGroup] = []
  var inspected = 0
  var verified = 0
  var bytesRead: Int64 = 0
  var issues: [String] = []
  var cancelled = false
}
enum DuplicateFinder {
  static func scan(
    roots: [URL], home: URL, minimum: Int64 = 100_000, cancellation: ScanCancellation,
    progressData: @escaping (OperationProgress) -> Void = { _ in },
    progress: @escaping (String) -> Void = { _ in }
  ) -> DuplicateResult {
    var result = DuplicateResult()
    let scanned = DiskScanner(policy: SafetyPolicy(home: home), minimumBytes: minimum).scan(
      roots: roots, cancellation: cancellation
    ) { p in
      progress("检查 \(p.visited) 项")
      progressData(OperationProgress(phase: "扫描", current: p.current, completedItems: p.visited))
    }
    result.inspected = scanned.items.count
    result.issues = scanned.issues
    let sizeGroups = Dictionary(grouping: scanned.items, by: { $0.stamp.size }).values.filter {
      $0.count > 1
    }
    var verified: [String: [ScanItem]] = [:]
    let prefixTotal = sizeGroups.flatMap { $0 }.reduce(Int64(0)) { $0 + min(65536, $1.stamp.size) }
    var prefixRead: Int64 = 0
    for candidates in sizeGroups {
      if cancellation.isCancelled { break }
      var prefixGroups: [String: [ScanItem]] = [:]
      for item in candidates {
        do {
          let key = try LocalFiles.digest(
            item.url, expected: item.stamp, prefix: 65536, cancellation: cancellation
          ) {
            result.bytesRead += $0
            prefixRead += $0
            progressData(
              OperationProgress(
                phase: "片段比较", current: item.url.lastPathComponent, completedBytes: prefixRead,
                totalBytes: prefixTotal))
          }
          prefixGroups[key, default: []].append(item)
        } catch {
          if !(error is ToolFailure && cancellation.isCancelled), result.issues.count < 100 {
            result.issues.append(item.url.lastPathComponent + "：" + error.localizedDescription)
          }
        }
      }
      for bucket in prefixGroups.values where bucket.count > 1 {
        for item in bucket {
          if cancellation.isCancelled { break }
          progress("校验内容 · " + item.url.lastPathComponent)
          progressData(
            OperationProgress(
              phase: "完整内容校验", current: item.url.lastPathComponent,
              completedBytes: result.bytesRead, completedItems: result.verified))
          do {
            let hash = try LocalFiles.digest(
              item.url, expected: item.stamp, cancellation: cancellation
            ) { result.bytesRead += $0 }
            verified[String(item.stamp.size) + ":" + hash, default: []].append(item)
            result.verified += 1
          } catch {
            if result.issues.count < 100 {
              result.issues.append(item.url.lastPathComponent + "：" + error.localizedDescription)
            }
          }
        }
      }
    }
    result.groups = verified.filter { $0.value.count > 1 }.map { key, files in
      DuplicateGroup(id: key, files: files.sorted { $0.url.path < $1.url.path })
    }.sorted { $0.copyBytes > $1.copyBytes }
    result.cancelled = cancellation.isCancelled
    return result
  }
  static func guards(groups: [DuplicateGroup], selected: Set<String>) throws -> [String:
    RetainedCopy]
  {
    var guards: [String: RetainedCopy] = [:]
    for group in groups {
      let chosen = group.files.filter { selected.contains($0.id) }
      guard !chosen.isEmpty else { continue }
      guard let keep = group.files.first(where: { !selected.contains($0.id) }) else {
        throw ToolFailure.invalid("每组至少保留一份文件")
      }
      let retained = RetainedCopy(url: keep.url, stamp: keep.stamp)
      try retained.validate()
      for item in chosen { guards[item.id] = retained }
    }
    return guards
  }
}
