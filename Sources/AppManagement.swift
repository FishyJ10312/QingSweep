import AppKit
import Foundation

struct ManagedItem: Identifiable {
  var id: String { url.path }
  let url: URL
  let bundleID: String
  let title: String
  let role: String
  let tree: FileTree
  var bytes: Int64 { tree.bytes }
}
struct AppInspection {
  let app: InstalledApplication
  var items: [ManagedItem] = []
  var issues: [String] = []
}
enum ManagedLocations {
  static func validID(_ id: String) -> Bool {
    id.count < 256 && id.contains(".")
      && id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]+$", options: .regularExpression) != nil
      && !id.hasPrefix("com.apple.") && id != "local.fishyj.qingsweep" && !id.contains("..")
  }
  static func resources(id: String, home: URL) -> [(URL, String)] {
    guard validID(id) else { return [] }
    return [
      ("Application Support/" + id, "应用数据"), ("Caches/" + id, "缓存"), ("Logs/" + id, "日志"),
      ("Preferences/" + id + ".plist", "偏好设置"),
      ("Saved Application State/" + id + ".savedState", "窗口状态"), ("HTTPStorages/" + id, "网页存储"),
      ("Containers/" + id, "独立数据"),
    ].map { (home.appendingPathComponent("Library/" + $0.0), $0.1) }
  }
  static func permits(_ url: URL, id: String, home: URL) -> Bool {
    guard validID(id) else { return false }
    if resources(id: id, home: home).contains(where: { $0.0.path == url.path }) { return true }
    guard url.pathExtension.lowercased() == "app" else { return false }
    let roots = [
      URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"),
    ]
    return roots.contains {
      SafetyPolicy.within(url, $0) && url.path != $0.path
        && url.pathComponents.count <= $0.pathComponents.count + 2
    }
  }
  static func inTrash(_ url: URL, home: URL) -> Bool {
    let homes = [home, FileManager.default.homeDirectoryForCurrentUser]
    if homes.contains(where: { SafetyPolicy.within(url, $0.appendingPathComponent(".Trash")) }) {
      return true
    }
    let parts = url.pathComponents
    return parts.count >= 6 && parts[1] == "Volumes" && parts[3] == ".Trashes"
      && parts[4] == String(getuid())
  }
  static func validateRestore(_ record: TrashRecord, home: URL) throws {
    guard let id = record.managedBundleID, permits(record.original, id: id, home: home),
      LocalFiles.noLinks(record.original.deletingLastPathComponent()),
      inTrash(record.trashed, home: home), LocalFiles.noLinks(record.trashed),
      FileStamp.read(record.original) == nil, let expected = record.stamp,
      let current = FileStamp.read(record.trashed),
      current == expected || current.sameContentIdentity(expected)
    else { throw ToolFailure.changed }
    if expected.isDirectory {
      guard let digest = record.treeDigest, try FileTree.read(record.trashed).digest == digest
      else { throw ToolFailure.changed }
    } else {
      guard expected.isRegular else { throw ToolFailure.changed }
      if current != expected {
        guard let proof = record.contentSHA256,
          try LocalFiles.digest(record.trashed, expected: current) == proof
        else { throw ToolFailure.changed }
      }
    }
  }
}
enum AppInventory {
  static func collect(home: URL, roots: [URL]? = nil) -> [InstalledApplication] {
    let manager = FileManager.default
    var found: [InstalledApplication] = []
    for root in roots ?? [
      URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"),
    ] {
      guard LocalFiles.noLinks(root),
        let iterator = manager.enumerator(
          at: root, includingPropertiesForKeys: [.isPackageKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { continue }
      while let url = iterator.nextObject() as? URL {
        guard url.pathExtension == "app", LocalFiles.noLinks(url),
          let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
          data.count < 1_000_000,
          let info = (try? PropertyListSerialization.propertyList(from: data, format: nil))
            as? [String: Any], let id = info["CFBundleIdentifier"] as? String,
          ManagedLocations.validID(id)
        else { continue }
        found.append(
          InstalledApplication(
            path: url.path, id: id,
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
              ?? url.deletingPathExtension().lastPathComponent,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? ""))
      }
    }
    return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  static func inspect(_ app: InstalledApplication, home: URL, cancellation: ScanCancellation)
    -> AppInspection
  {
    var report = AppInspection(app: app)
    let program = URL(fileURLWithPath: app.path)
    let targets = [(program, "程序本体")] + ManagedLocations.resources(id: app.id, home: home)
    for (url, role) in targets {
      if cancellation.isCancelled { break }
      guard FileStamp.read(url) != nil else { continue }
      do {
        guard ManagedLocations.permits(url, id: app.id, home: home) else {
          throw ToolFailure.invalid("此位置不在应用私有范围")
        }
        let tree = try FileTree.read(url, cancellation: cancellation)
        if role == "程序本体" {
          let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
          let info =
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
          guard info?["CFBundleIdentifier"] as? String == app.id else { throw ToolFailure.changed }
        }
        report.items.append(
          ManagedItem(
            url: url, bundleID: app.id, title: url.lastPathComponent, role: role, tree: tree))
      } catch { report.issues.append(url.path + "：" + error.localizedDescription) }
    }
    return report
  }
  static func possibleLeftovers(
    home: URL, installed: [InstalledApplication], cancellation: ScanCancellation
  ) -> ([ManagedItem], [String]) {
    let known = Set(installed.map(\.id))
    var result: [ManagedItem] = []
    var issues: [String] = []
    for location in ["Caches", "Logs", "Application Support", "Preferences"] {
      let root = home.appendingPathComponent("Library/" + location)
      do {
        for url in try FileManager.default.contentsOfDirectory(
          at: root, includingPropertiesForKeys: nil)
        {
          if cancellation.isCancelled { return (result, issues) }
          let id =
            location == "Preferences"
            ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
          guard ManagedLocations.validID(id), !known.contains(id),
            ManagedLocations.resources(id: id, home: home).contains(where: { $0.0.path == url.path }
            )
          else { continue }
          do {
            result.append(
              ManagedItem(
                url: url, bundleID: id, title: id, role: "可能残留 · " + location,
                tree: try FileTree.read(url, cancellation: cancellation, seconds: 10)))
          } catch { issues.append(url.path + "：" + error.localizedDescription) }
        }
      } catch {
        if FileStamp.read(root) != nil {
          issues.append(root.path + "：" + error.localizedDescription)
        }
      }
    }
    return (result.sorted { $0.bytes > $1.bytes }, issues)
  }
}
enum ManagedTrash {
  @MainActor static func move(
    _ items: [ManagedItem], home: URL, cancellation: ScanCancellation,
    quitTimeout: TimeInterval = 10, journal: CleanupJournalContext? = nil, progress: @escaping (String) -> Void
  ) async -> TrashResult {
    var result = TrashResult()
    // Private data may contain projects. This entry point is only called after a separate acknowledgement.
    let identifiers = Set(items.map(\.bundleID))
    for id in identifiers {
      for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
        if cancellation.isCancelled { return result }
        _ = app.terminate()
      }
    }
    let deadline = Date().addingTimeInterval(quitTimeout)
    while Date() < deadline
      && identifiers.contains(where: {
        !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
      })
    {
      if cancellation.isCancelled { return result }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    for item in items {
      if cancellation.isCancelled || journal?.journal.isBlocked == true { break }
      var unfinishedIntent = false
      progress("正在复核 · " + item.title)
      do {
        guard ManagedLocations.permits(item.url, id: item.bundleID, home: home),
          LocalFiles.noLinks(item.url),
          NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).isEmpty
        else { throw ToolFailure.invalid("应用仍在运行或位置已变化，本项未处理") }
        let current = try await Task.detached(priority: .utility) {
          try FileTree.read(item.url, cancellation: cancellation)
        }.value
        guard current.stamp == item.tree.stamp, current.digest == item.tree.digest else {
          throw ToolFailure.changed
        }
        // Open-file users include helpers whose bundle identifier differs from the main app.
        let arguments =
          ["-nP", "-F0pn"]
          + (current.stamp.isDirectory ? ["+D", item.url.path] : ["--", item.url.path])
        let opened = try await Task.detached(priority: .utility) {
          try SystemToolCommands().run("/usr/sbin/lsof", arguments, cancellation: cancellation)
        }.value
        guard !opened.truncated, opened.status == 0 || (opened.status == 1 && opened.output.isEmpty)
        else { throw ToolFailure.invalid("无法核验文件占用，本项未处理") }
        let paths = opened.output.split(separator: "\0").map {
          String($0.first == "\n" ? $0.dropFirst() : $0)
        }.filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        guard !paths.contains(where: { $0 == item.url.path || $0.hasPrefix(item.url.path + "/") })
        else { throw ToolFailure.invalid("仍有进程正在使用，本项未处理") }
        let final = try await Task.detached(priority: .utility) {
          try FileTree.read(item.url, cancellation: cancellation)
        }.value
        guard final.stamp == item.tree.stamp, final.digest == item.tree.digest else {
          throw ToolFailure.changed
        }
        let checksum =
          final.stamp.isRegular
          ? try LocalFiles.digest(item.url, expected: final.stamp, cancellation: cancellation) : nil
        let intent = try journal.map { try $0.journal.prepareMove(original:item.url, stamp:final.stamp, bytes:item.bytes, context:$0, checksum:checksum, bundleID:item.bundleID, treeDigest:final.stamp.isDirectory ? final.digest:nil) }
        unfinishedIntent = intent != nil
        if cancellation.isCancelled || FileStamp.read(item.url) != final.stamp || !LocalFiles.noLinks(item.url) || !NSRunningApplication.runningApplications(withBundleIdentifier:item.bundleID).isEmpty {
          if let journal,let intent{try journal.journal.didNotMove(intent);unfinishedIntent=false}
          throw cancellation.isCancelled ? ToolFailure.cancelled:ToolFailure.changed
        }
        var destination: NSURL?
        try FileManager.default.trashItem(at: item.url, resultingItemURL: &destination)
        if let journal, let intent { try journal.journal.hit(.moveApplied, id:intent.id) }
        guard let target = destination as URL?, let stamp = FileStamp.read(target) else {
          throw ToolFailure.invalid("系统未返回废纸篓位置，请检查清理记录")
        }
        var record = TrashRecord(
          id: intent?.id ?? UUID(), original: item.url, trashed: target, bytes: item.bytes, date: intent?.date ?? Date(),
          stamp: stamp)
        record.contentSHA256 = checksum
        record.managedBundleID = item.bundleID
        record.treeDigest = stamp.isDirectory ? item.tree.digest : nil
        record.batchID = journal?.batchID
        result.records.append(record)
        if let journal, let intent { try journal.journal.didMove(intent,record:record) }
        unfinishedIntent = false
      } catch { result.errors.append(item.title + "：" + error.localizedDescription) }
      if unfinishedIntent { break }
    }
    return result
  }
}
