import CoreFoundation
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
  var disabled: Bool? = nil
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
  static func validate(_ url: URL, home: URL) throws -> (String, String, FileStamp, Bool) {
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
    var disabled = false
    if let value = info["Disabled"] {
      guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let flag = value as? Bool
      else { throw ToolFailure.invalid("启动项的默认停用设置无效") }
      disabled = flag
    }
    let program = info["Program"] as? String ?? (info["ProgramArguments"] as? [String])?.first ?? ""
    guard program.hasPrefix("/"), FileStamp.read(url) == stamp else { throw ToolFailure.changed }
    return (label, program, stamp, disabled)
  }
  private struct State: Equatable {
    let disabled: Bool
    let loaded: Bool
  }
  private static func overrides(_ result: ToolCommandResult) throws -> [String: Bool] {
    // launchctl's text is not a stable API. Accept only complete known formats and fail closed.
    guard result.status == 0, !result.truncated else {
      throw ToolFailure.invalid("启动项停用状态未确认，请重新检查")
    }
    let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    if text == "disabled services = {}" { return [:] }
    let lines = text.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard lines.count >= 2, lines.first == "disabled services = {", lines.last == "}" else {
      throw ToolFailure.invalid("启动项停用状态未确认，请重新检查")
    }
    let pattern = try NSRegularExpression(
      pattern: #"^"([^"\\]+)"\s*=>\s*(true|false|enabled|disabled)\s*,?$"#)
    var values: [String: Bool] = [:]
    for line in lines.dropFirst().dropLast() {
      let range = NSRange(line.startIndex..<line.endIndex, in: line)
      guard let match = pattern.firstMatch(in: line, range: range), match.range == range,
        let nameRange = Range(match.range(at: 1), in: line),
        let flagRange = Range(match.range(at: 2), in: line)
      else { throw ToolFailure.invalid("启动项停用状态未确认，请重新检查") }
      let name = String(line[nameRange])
      guard values[name] == nil else {
        throw ToolFailure.invalid("启动项停用状态未确认，请重新检查")
      }
      let flag = String(line[flagRange])
      values[name] = flag == "true" || flag == "disabled"
    }
    return values
  }
  private static func loaded(
    _ label: String, commands: ToolCommandRunning, cancellation: ScanCancellation?
  ) throws -> Bool {
    let result = try commands.run(
      "/bin/launchctl", ["print", "gui/\(getuid())/" + label], cancellation: cancellation)
    guard !result.truncated else {
      throw ToolFailure.invalid("启动项载入状态未确认，请重新检查")
    }
    if result.status == 0 { return true }
    let absent = "Could not find service \"\(label)\" in domain for user gui: \(getuid())"
    let lines = result.output.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard result.status == 113, lines == [absent] || lines == ["Bad request.", absent] else {
      throw ToolFailure.invalid("启动项载入状态未确认，请重新检查")
    }
    return false
  }
  private static func state(
    _ label: String, defaultDisabled: Bool, commands: ToolCommandRunning,
    cancellation: ScanCancellation?
  ) throws -> State {
    let values = try overrides(
      commands.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"], cancellation: cancellation))
    return try State(
      disabled: values[label] ?? defaultDisabled,
      loaded: loaded(label, commands: commands, cancellation: cancellation))
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
      var values: [String: Bool]?
      do {
        values = try overrides(
          commands.run(
            "/bin/launchctl", ["print-disabled", "gui/\(getuid())"], cancellation: cancellation))
      } catch { issues.append(error.localizedDescription) }
      for url in try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil
      ).filter({ $0.pathExtension == "plist" }) {
        if cancellation.isCancelled { break }
        do {
          let (label, program, stamp, defaultDisabled) = try validate(url, home: home)
          var present = false
          var disabled: Bool?
          if let values {
            do {
              present = try loaded(label, commands: commands, cancellation: cancellation)
              disabled = values[label] ?? defaultDisabled
            } catch { issues.append(url.lastPathComponent + "：" + error.localizedDescription) }
          }
          entries.append(
            StartupEntry(
              label: label, url: url, stamp: stamp, program: program, loaded: present,
              disabledBySweep: receipts.last(where: { $0.label == label && $0.path == url.path })?
                .disabled == true, disabled: disabled))
        } catch { issues.append(url.lastPathComponent + "：" + error.localizedDescription) }
      }
    } catch { issues.append(error.localizedDescription) }
    return (entries.sorted { $0.label < $1.label }, issues)
  }
  static func set(
    _ entry: StartupEntry, enabled: Bool, home: URL,
    commands: ToolCommandRunning = SystemToolCommands(), cancellation: ScanCancellation
  ) throws -> StartupReceipt {
    let (label, _, stamp, defaultDisabled) = try validate(entry.url, home: home)
    guard label == entry.label, stamp == entry.stamp else { throw ToolFailure.changed }
    let domain = "gui/\(getuid())"
    let target = domain + "/" + label
    let original = try state(
      label, defaultDisabled: defaultDisabled, commands: commands, cancellation: cancellation)
    guard try validate(entry.url, home: home).2 == stamp else { throw ToolFailure.changed }
    var attemptedChange = false
    func change(_ args: [String]) throws {
      if cancellation.isCancelled { throw ToolFailure.cancelled }
      // Even a thrown command may have changed launchd before cancellation or a transport error.
      attemptedChange = true
      let result = try commands.run("/bin/launchctl", args, cancellation: cancellation)
      guard result.status == 0, !result.truncated else {
        throw ToolFailure.invalid("系统未接受更改：" + String(result.output.prefix(200)))
      }
    }
    func restore() throws {
      var failures: [String] = []
      func restoreCommand(_ args: [String]) {
        do {
          let result = try commands.run("/bin/launchctl", args, cancellation: nil)
          if result.status != 0 || result.truncated {
            failures.append(String(result.output.prefix(200)))
          }
        } catch { failures.append(error.localizedDescription) }
      }
      let present = try? loaded(label, commands: commands, cancellation: nil)
      if original.loaded && present != true {
        do {
          guard try validate(entry.url, home: home).2 == stamp else { throw ToolFailure.changed }
          restoreCommand(["enable", target])
          restoreCommand(["bootstrap", domain, entry.url.path])
        } catch { failures.append(error.localizedDescription) }
      } else if !original.loaded && present != false {
        restoreCommand(["bootout", target])
      }
      restoreCommand([original.disabled ? "disable" : "enable", target])
      // A command may also report failure after applying its effect; final state decides recovery.
      do {
        let restored = try state(
          label, defaultDisabled: defaultDisabled, commands: commands, cancellation: nil)
        if restored == original { return }
      } catch { failures.append(error.localizedDescription) }
      throw ToolFailure.invalid(
        "启动项恢复原状态失败，请在系统设置中检查：" + failures.filter { !$0.isEmpty }.joined(separator: "；"))
    }
    do {
      try change([enabled ? "enable" : "disable", target])
      let present = try loaded(label, commands: commands, cancellation: cancellation)
      if enabled && !present {
        guard try validate(entry.url, home: home).2 == stamp else { throw ToolFailure.changed }
        try change(["bootstrap", domain, entry.url.path])
      } else if !enabled && present {
        try change(["bootout", target])
      }
      let updated = try state(
        label, defaultDisabled: defaultDisabled, commands: commands, cancellation: cancellation)
      guard updated == State(disabled: !enabled, loaded: enabled) else {
        throw ToolFailure.invalid("启动项更改后的状态未确认")
      }
      guard try validate(entry.url, home: home).2 == stamp else { throw ToolFailure.changed }
      if cancellation.isCancelled { throw ToolFailure.cancelled }
      return StartupReceipt(label: label, path: entry.url.path, date: Date(), disabled: !enabled)
    } catch {
      if attemptedChange {
        do { try restore() }
        catch let recoveryError {
          throw ToolFailure.invalid(
            recoveryError.localizedDescription + "；" + error.localizedDescription)
        }
      }
      throw error
    }
  }
}
