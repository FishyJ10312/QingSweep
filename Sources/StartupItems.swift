import Darwin
import Foundation

struct StartupEntry: Identifiable {
  var id: String { label }
  let label: String
  let url: URL
  let stamp: FileStamp
  let program: String
  let loaded: Bool
  let disabledBySweep: Bool
}
struct StartupReceipt: Codable {
  let label: String
  let path: String
  let date: Date
  var disabled: Bool
}
enum StartupItems {
  static func safeLabel(_ label: String) -> Bool {
    !label.hasPrefix("com.apple.") && label != "local.fishyj.qingsweep" && label.count < 256
      && label.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]+$", options: .regularExpression) != nil
      && ![
        "antivirus", "endpoint", "defender", "sentinel", "crowdstrike", "falcon", "sophos", "eset",
        "malwarebytes", "security",
      ].contains(where: { label.lowercased().contains($0) })
  }
  static func validate(_ url: URL, home: URL) throws -> (String, String, FileStamp) {
    let folder = home.appendingPathComponent("Library/LaunchAgents")
    guard url.deletingLastPathComponent() == folder, url.pathExtension == "plist",
      LocalFiles.noLinks(url), let stamp = FileStamp.read(url), stamp.isRegular,
      stamp.size < 1_000_000
    else { throw ToolFailure.invalid("仅管理当前用户的 LaunchAgents") }
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0, metadata.st_uid == getuid() else {
      throw ToolFailure.invalid("文件不属于当前用户")
    }
    let data = try Data(contentsOf: url)
    guard
      let info = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any], let label = info["Label"] as? String, safeLabel(label)
    else { throw ToolFailure.invalid("此服务请在系统设置中管理") }
    let program = info["Program"] as? String ?? (info["ProgramArguments"] as? [String])?.first ?? ""
    guard program.hasPrefix("/"), FileStamp.read(url) == stamp else { throw ToolFailure.changed }
    return (label, program, stamp)
  }
  static func collect(
    home: URL, receipts: [StartupReceipt], commands: ToolCommandRunning = SystemToolCommands(),
    cancellation: ScanCancellation
  ) -> ([StartupEntry], [String]) {
    var entries: [StartupEntry] = []
    var issues: [String] = []
    let folder = home.appendingPathComponent("Library/LaunchAgents")
    guard FileStamp.read(folder) != nil else { return ([], []) }
    do {
      guard LocalFiles.noLinks(folder) else { throw ToolFailure.changed }
      for url in try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil
      ).filter({ $0.pathExtension == "plist" }) {
        if cancellation.isCancelled { break }
        do {
          let (label, program, stamp) = try validate(url, home: home)
          let status = try commands.run(
            "/bin/launchctl", ["print", "gui/\(getuid())/" + label], cancellation: cancellation)
          entries.append(
            StartupEntry(
              label: label, url: url, stamp: stamp, program: program, loaded: status.status == 0,
              disabledBySweep: receipts.last(where: { $0.label == label && $0.path == url.path })?
                .disabled == true))
        } catch { issues.append(url.lastPathComponent + "：" + error.localizedDescription) }
      }
    } catch { issues.append(error.localizedDescription) }
    return (entries.sorted { $0.label < $1.label }, issues)
  }
  static func set(
    _ entry: StartupEntry, enabled: Bool, home: URL,
    commands: ToolCommandRunning = SystemToolCommands(), cancellation: ScanCancellation
  ) throws -> StartupReceipt {
    let (label, _, stamp) = try validate(entry.url, home: home)
    guard label == entry.label, stamp == entry.stamp else { throw ToolFailure.changed }
    let domain = "gui/\(getuid())"
    let target = domain + "/" + label
    func run(_ args: [String]) throws -> ToolCommandResult {
      try commands.run("/bin/launchctl", args, cancellation: cancellation)
    }
    let first = try run([enabled ? "enable" : "disable", target])
    guard first.status == 0 else {
      throw ToolFailure.invalid("系统未接受更改：" + String(first.output.prefix(200)))
    }
    var committed = false
    defer {
      if !committed {
        _ = try? commands.run(
          "/bin/launchctl", [entry.disabledBySweep ? "disable" : "enable", target],
          cancellation: nil)
      }
    }
    let present = try run(["print", target]).status == 0
    if enabled {
      if !present {
        let result = try run(["bootstrap", domain, entry.url.path])
        if result.status != 0 {
          _ = try? commands.run("/bin/launchctl", ["disable", target], cancellation: nil)
          throw ToolFailure.invalid("未能载入，已恢复停用：" + String(result.output.prefix(200)))
        }
      }
    } else if present {
      let result = try run(["bootout", target])
      if result.status != 0 {
        _ = try? commands.run("/bin/launchctl", ["enable", target], cancellation: nil)
        throw ToolFailure.invalid("未能退出，已恢复启用：" + String(result.output.prefix(200)))
      }
    }
    committed = true
    return StartupReceipt(label: label, path: entry.url.path, date: Date(), disabled: !enabled)
  }
}
