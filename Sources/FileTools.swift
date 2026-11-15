import CryptoKit
import Darwin
import Foundation

enum ToolFailure: LocalizedError {
  case cancelled, changed
  case unreadable(String)
  case incomplete, insufficientSpace, disconnected
  case invalid(String)
  var errorDescription: String? {
    switch self {
    case .cancelled: return "已停止后续操作"
    case .changed: return "文件或目录已变化，请重新检查"
    case .unreadable(let path): return "尚未读取：" + path
    case .incomplete: return "目录尚未读完整，请选择较小范围"
    case .insufficientSpace: return "目标磁盘空间不足"
    case .disconnected: return "原磁盘未连接，操作已停止"
    case .invalid(let reason): return reason
    }
  }
}
extension FileStamp {
  func sameContentIdentity(_ other: FileStamp) -> Bool {
    device == other.device && inode == other.inode && size == other.size
      && modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos
      && links == other.links && flags == other.flags && mode == other.mode
  }
  static func descriptor(_ fd: Int32) -> FileStamp? {
    var s = stat()
    guard fstat(fd, &s) == 0 else { return nil }
    return FileStamp(
      device: s.st_dev, inode: s.st_ino, size: s.st_size, allocated: Int64(s.st_blocks) * 512,
      modifiedSeconds: Int64(s.st_mtimespec.tv_sec), modifiedNanos: Int64(s.st_mtimespec.tv_nsec),
      changedSeconds: Int64(s.st_ctimespec.tv_sec), changedNanos: Int64(s.st_ctimespec.tv_nsec),
      links: s.st_nlink, flags: s.st_flags, mode: s.st_mode)
  }
}
enum LocalFiles {
  static func noLinks(_ url: URL) -> Bool {
    guard url.isFileURL, !url.pathComponents.contains(".."), !url.pathComponents.contains(".")
    else { return false }
    var cursor = url
    while cursor.path != "/" {
      guard let stamp = FileStamp.read(cursor), !stamp.isSymlink, !stamp.isDataless else {
        return false
      }
      cursor.deleteLastPathComponent()
    }
    return true
  }
  static func digest(
    _ url: URL, expected: FileStamp, prefix: Int? = nil,
    cancellation: ScanCancellation = ScanCancellation(), progress: (Int64) -> Void = { _ in }
  ) throws -> String {
    guard noLinks(url) else { throw ToolFailure.changed }
    let fd = url.withUnsafeFileSystemRepresentation {
      $0.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
    }
    guard fd >= 0 else { throw ToolFailure.unreadable(url.path) }
    defer { Darwin.close(fd) }
    guard FileStamp.descriptor(fd) == expected, expected.isRegular, !expected.isDataless else {
      throw ToolFailure.changed
    }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var hash = SHA256()
    var remaining = prefix ?? Int.max
    while remaining > 0 {
      if cancellation.isCancelled { throw ToolFailure.cancelled }
      let data = try file.read(upToCount: min(4 * 1024 * 1024, remaining)) ?? Data()
      if data.isEmpty { break }
      hash.update(data: data)
      remaining -= data.count
      progress(Int64(data.count))
    }
    guard FileStamp.descriptor(fd) == expected, FileStamp.read(url) == expected else {
      throw ToolFailure.changed
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  static func textDigest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
struct TreeFile: Codable {
  let relative: String
  let stamp: FileStamp
  let link: String?
  func url(in root: URL) -> URL { relative.isEmpty ? root : root.appendingPathComponent(relative) }
}
struct FileTree {
  let root: URL
  let stamp: FileStamp
  let entries: [TreeFile]
  var bytes: Int64 {
    var seen = Set<String>()
    return entries.reduce(0) { total, entry in
      let key = "\(entry.stamp.device):\(entry.stamp.inode)"
      return total
        + (entry.stamp.isRegular && seen.insert(key).inserted ? entry.stamp.allocated : 0)
    }
  }
  var logicalBytes: Int64 {
    entries.reduce(0) { boundedBytes($0, ($1.stamp.isRegular ? $1.stamp.size : 0)) }
  }
  var files: Int { entries.filter { $0.stamp.isRegular }.count }
  var digest: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return LocalFiles.textDigest(
      entries.sorted { $0.relative < $1.relative }.map {
        String(decoding: (try? encoder.encode($0)) ?? Data(), as: UTF8.self)
      }.joined(separator: "\n"))
  }
  static func read(
    _ root: URL, cancellation: ScanCancellation = ScanCancellation(), limit: Int = 250_000,
    seconds: TimeInterval = 45
  ) throws -> FileTree {
    guard LocalFiles.noLinks(root), let stamp = FileStamp.read(root),
      stamp.isDirectory || stamp.isRegular
    else { throw ToolFailure.unreadable(root.path) }
    let values = try root.resourceValues(forKeys: [.isUbiquitousItemKey, .isAliasFileKey])
    guard values.isUbiquitousItem != true, values.isAliasFile != true else {
      throw ToolFailure.unreadable(root.path)
    }
    if stamp.isRegular {
      return FileTree(
        root: root, stamp: stamp, entries: [TreeFile(relative: "", stamp: stamp, link: nil)])
    }
    var entries: [TreeFile] = []
    var failure: Error?
    let started = Date()
    guard
      let iterator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isUbiquitousItemKey], options: [],
        errorHandler: { url, error in
          failure = ToolFailure.unreadable(url.path)
          return false
        })
    else { throw ToolFailure.unreadable(root.path) }
    while let url = iterator.nextObject() as? URL {
      if cancellation.isCancelled { throw ToolFailure.cancelled }
      if entries.count >= limit || Date().timeIntervalSince(started) > seconds
        || iterator.level > 64
      {
        throw ToolFailure.incomplete
      }
      guard let current = FileStamp.read(url), !current.isDataless else {
        throw ToolFailure.unreadable(url.path)
      }
      let link: String?
      if current.isSymlink {
        iterator.skipDescendants()
        link = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
      } else {
        link = nil
        guard current.isRegular || current.isDirectory else {
          throw ToolFailure.unreadable(url.path)
        }
        if current.isDirectory,
          (try url.resourceValues(forKeys: [.isUbiquitousItemKey])).isUbiquitousItem == true
        {
          throw ToolFailure.unreadable(url.path)
        }
      }
      entries.append(
        TreeFile(
          relative: String(url.path.dropFirst(root.path.count + 1)), stamp: current, link: link))
    }
    if let failure { throw failure }
    guard FileStamp.read(root) == stamp else { throw ToolFailure.changed }
    for entry in entries where entry.stamp.isDirectory {
      guard FileStamp.read(entry.url(in: root)) == entry.stamp else { throw ToolFailure.changed }
    }
    return FileTree(root: root, stamp: stamp, entries: entries)
  }
}
struct RetainedCopy: Codable {
  let url: URL
  let stamp: FileStamp
  func validate() throws {
    guard LocalFiles.noLinks(url), stamp.isRegular, !stamp.isDataless, FileStamp.read(url) == stamp
    else { throw ToolFailure.invalid("保留的副本已变化或磁盘未连接，本项未清理") }
  }
}
struct ToolCommandResult {
  let status: Int32
  let output: String
  var truncated = false
}
protocol ToolCommandRunning {
  func run(_ executable: String, _ arguments: [String], cancellation: ScanCancellation?) throws
    -> ToolCommandResult
}
struct SystemToolCommands: ToolCommandRunning {
  var timeout: TimeInterval? = 120
  var onPoll: (() throws -> Void)? = nil
  func run(_ executable: String, _ arguments: [String], cancellation: ScanCancellation? = nil)
    throws -> ToolCommandResult
  {
    if cancellation?.isCancelled == true { throw ToolFailure.cancelled }
    let task = Process()
    let pipe = Pipe()
    let capture = CommandCapture()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    task.standardOutput = pipe
    task.standardError = pipe
    try task.run()
    let done = DispatchGroup()
    done.enter()
    DispatchQueue.global(qos: .utility).async {
      while true {
        let chunk = pipe.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        if capture.data.count + chunk.count > 2_000_000 { capture.truncated = true }
        capture.data.append(chunk.prefix(max(0, 2_000_000 - capture.data.count)))
      }
      done.leave()
    }
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    var pollError: Error?
    while task.isRunning && (deadline == nil || Date() < deadline!)
      && cancellation?.isCancelled != true
    {
      do { try onPoll?() } catch {
        pollError = error
        break
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    if task.isRunning {
      task.terminate()
      Thread.sleep(forTimeInterval: 0.1)
      if task.isRunning { Darwin.kill(task.processIdentifier, SIGKILL) }
    }
    task.waitUntilExit()
    done.wait()
    if cancellation?.isCancelled == true { throw ToolFailure.cancelled }
    if let pollError { throw pollError }
    if let deadline, Date() >= deadline { throw ToolFailure.invalid("检查超时，请选择较小范围") }
    return ToolCommandResult(
      status: task.terminationStatus, output: String(decoding: capture.data, as: UTF8.self),
      truncated: capture.truncated)
  }
  private final class CommandCapture: @unchecked Sendable {
    var data = Data()
    var truncated = false
  }
}
