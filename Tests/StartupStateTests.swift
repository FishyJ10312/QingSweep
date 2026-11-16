import Darwin
import Foundation

private final class StartupCommandModel: ToolCommandRunning {
  let label: String
  let domain = "gui/\(getuid())"
  var disabledOverride: Bool?
  var defaultDisabled = false
  var disabled: Bool {
    get { disabledOverride ?? defaultDisabled }
    set { disabledOverride = newValue }
  }
  var loaded: Bool
  var calls: [[String]] = []
  var cancellableCalls: [Bool] = []
  var changes = 0
  var failPrintAfterChange: Error?
  var disabledResult: ToolCommandResult?
  var loadedResult: ToolCommandResult?
  var legacyBooleans = false
  var beforeCommand: (([String], ScanCancellation?) throws -> ToolCommandResult?)?
  var afterCommand: (([String], ScanCancellation?) throws -> ToolCommandResult?)?

  init(label: String, disabled: Bool?, loaded: Bool) {
    self.label = label
    self.disabledOverride = disabled
    self.loaded = loaded
  }

  func run(_ executable: String, _ arguments: [String], cancellation: ScanCancellation?) throws
    -> ToolCommandResult
  {
    calls.append(arguments)
    cancellableCalls.append(cancellation != nil)
    if cancellation?.isCancelled == true { throw ToolFailure.cancelled }
    if let result = try beforeCommand?(arguments, cancellation) { return result }
    let target = domain + "/" + label
    var result = ToolCommandResult(status: 0, output: "")
    switch arguments.first {
    case "print-disabled":
      guard arguments == ["print-disabled", domain] else { throw ToolFailure.changed }
      let line = disabledOverride.map {
        let value = legacyBooleans ? ($0 ? "true" : "false") : ($0 ? "disabled" : "enabled")
        return "\t\"\(label)\" => \(value)\n"
      } ?? ""
      result = disabledResult ?? .init(status: 0, output: "disabled services = {\n" + line + "}\n")
    case "print":
      guard arguments == ["print", target] else { throw ToolFailure.changed }
      if changes > 0, let error = failPrintAfterChange {
        failPrintAfterChange = nil
        if case ToolFailure.cancelled = error { cancellation?.cancel() }
        throw error
      }
      result = loadedResult ?? (loaded
        ? .init(status: 0, output: "opaque service information")
        : .init(
          status: 113,
          output: "Bad request.\nCould not find service \"\(label)\" in domain for user gui: \(getuid())\n"))
    case "enable", "disable":
      guard arguments == [arguments[0], target] else { throw ToolFailure.changed }
      disabled = arguments[0] == "disable"
      changes += 1
    case "bootstrap":
      guard arguments.count == 3, arguments[1] == domain, !disabled else {
        return .init(status: 5, output: "service is disabled")
      }
      loaded = true
      changes += 1
    case "bootout":
      guard arguments == ["bootout", target] else { throw ToolFailure.changed }
      loaded = false
      changes += 1
    default: throw ToolFailure.changed
    }
    return try afterCommand?(arguments, cancellation) ?? result
  }
}

@main struct StartupStateTests {
  static func main() throws {
    setbuf(stdout, nil)
    setbuf(stderr, nil)
    let fm = FileManager.default
    let home = URL(fileURLWithPath: "/Users/Shared/qingsweep-startup-183-" + UUID().uuidString)
    let folder = home.appendingPathComponent("Library/LaunchAgents")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: home) }
    let label = "local.qingsweep.statefixture." + UUID().uuidString
    let agent = folder.appendingPathComponent("state.plist")
    try PropertyListSerialization.data(
      fromPropertyList: ["Label": label, "ProgramArguments": ["/usr/bin/true"], "RunAtLoad": false],
      format: .xml, options: 0
    ).write(to: agent)
    var passed = 0
    var failed = 0
    func check(_ value: Bool, _ title: String) {
      if value { passed += 1; print("PASS: " + title) }
      else { failed += 1; print("FAIL: " + title) }
    }
    func inventory(_ commands: StartupCommandModel, receipts: [StartupReceipt] = []) throws
      -> StartupEntry
    {
      let result = StartupItems.collect(
        home: home, receipts: receipts, commands: commands, cancellation: ScanCancellation())
      guard result.0.count == 1 else { throw ToolFailure.invalid("fixture inventory is missing") }
      return result.0[0]
    }
    func attempt(_ entry: StartupEntry, enabled: Bool, commands: StartupCommandModel) -> Error? {
      do {
        _ = try StartupItems.set(
          entry, enabled: enabled, home: home, commands: commands, cancellation: ScanCancellation())
        return nil
      } catch { return error }
    }
    func writeDefault(_ value: Any?) throws {
      var info: [String: Any] = [
        "Label": label, "ProgramArguments": ["/usr/bin/true"], "RunAtLoad": false,
      ]
      info["Disabled"] = value
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: agent)
    }
    for (name, failure) in [
      ("cancelled", ToolFailure.cancelled),
      ("query error", ToolFailure.invalid("fixture read failure")),
    ] {
      let commands = StartupCommandModel(label: label, disabled: true, loaded: false)
      let entry = StartupItems.collect(
        home: home, receipts: [], commands: commands, cancellation: ScanCancellation()).0[0]
      commands.failPrintAfterChange = failure
      var rejected = false
      do {
        _ = try StartupItems.set(
          entry, enabled: false, home: home, commands: commands, cancellation: ScanCancellation())
      } catch { rejected = true }
      check(rejected, name + " disable reports the interrupted operation")
      check(
        commands.disabled && !commands.loaded,
        name + " disable preserves an externally disabled unloaded service with no receipt")
      check(
        !commands.calls.contains(["enable", commands.domain + "/" + label]),
        name + " disable never enables that externally disabled service during rollback")
    }

    for legacy in [false, true] {
      for disabled in [false, true] {
        let commands = StartupCommandModel(label: label, disabled: disabled, loaded: !disabled)
        commands.legacyBooleans = legacy
        let entry = try inventory(commands)
        check(
          entry.disabled == disabled && entry.loaded == !disabled,
          "inventory reads authoritative \(legacy ? "boolean" : "word") override \(disabled)")
      }
    }
    for defaultDisabled in [false, true] {
      try writeDefault(defaultDisabled)
      let commands = StartupCommandModel(label: label, disabled: nil, loaded: false)
      commands.defaultDisabled = defaultDisabled
      let entry = try inventory(commands)
      check(
        entry.disabled == defaultDisabled,
        "absent override respects plist Disabled=\(defaultDisabled)")
      commands.disabledOverride = !defaultDisabled
      check(
        try inventory(commands).disabled == !defaultDisabled,
        "explicit override takes precedence over plist Disabled=\(defaultDisabled)")
    }
    try writeDefault(nil)

    let fullOverrides = "disabled services = {\n\"\(label)\" => disabled\n}\n"
    for (name, result) in [
      ("query status error", ToolCommandResult(status: 1, output: "permission denied")),
      ("truncated override output", .init(status: 0, output: fullOverrides, truncated: true)),
      ("missing override terminator", .init(status: 0, output: "disabled services = {\n")),
      ("unknown override value", .init(status: 0, output: fullOverrides.replacingOccurrences(of: "=> disabled", with: "=> unknown"))),
      ("duplicate override", .init(status: 0, output: "disabled services = {\n\"\(label)\" => true\n\"\(label)\" => false\n}")),
      ("trailing override text", .init(status: 0, output: fullOverrides + "partial data")),
    ] {
      let commands = StartupCommandModel(label: label, disabled: true, loaded: false)
      commands.disabledResult = result
      let entry = try inventory(commands)
      check(entry.disabled == nil, name + " leaves inventory action unavailable")
      check(
        attempt(entry, enabled: false, commands: commands) != nil && commands.changes == 0,
        name + " rejects mutation before any enable, disable, bootstrap or bootout")
    }
    for (name, result) in [
      ("unrecognized print error", ToolCommandResult(status: 1, output: "permission denied")),
      ("wrong absent label", .init(status: 113, output: "Could not find service \"another.label\" in domain for user gui: \(getuid())")),
      ("truncated service output", .init(status: 0, output: "opaque service information", truncated: true)),
    ] {
      let commands = StartupCommandModel(label: label, disabled: false, loaded: true)
      commands.loadedResult = result
      let entry = try inventory(commands)
      check(
        entry.disabled == nil && attempt(entry, enabled: false, commands: commands) != nil
          && commands.changes == 0,
        name + " cannot be mistaken for a safely unloaded service")
    }

    for disabled in [false, true] {
      for loaded in [false, true] {
        for enabled in [false, true] {
          let commands = StartupCommandModel(label: label, disabled: disabled, loaded: loaded)
          let entry = try inventory(commands)
          var failedAt: Int?
          commands.afterCommand = { args, cancellation in
            if failedAt == nil && ["enable", "disable"].contains(args[0]) {
              failedAt = commands.calls.count - 1
              cancellation?.cancel()
              throw ToolFailure.cancelled
            }
            return nil
          }
          let error = attempt(entry, enabled: enabled, commands: commands)
          let stateName = "disabled=\(disabled), loaded=\(loaded), requested enable=\(enabled)"
          check(
            error != nil && commands.disabled == disabled && commands.loaded == loaded,
            "cancellation after first command effect restores " + stateName)
          check(
            failedAt != nil && commands.cancellableCalls.dropFirst(failedAt! + 1).allSatisfy { !$0 },
            "all rollback commands ignore the cancelled token for " + stateName)
        }
      }
    }

    for enabled in [false, true] {
      let mutation = enabled ? "bootstrap" : "bootout"
      for afterEffect in [false, true] {
        for throwsError in [false, true] {
          let commands = StartupCommandModel(label: label, disabled: enabled, loaded: !enabled)
          let entry = try inventory(commands)
          var injected = false
          let hook: ([String], ScanCancellation?) throws -> ToolCommandResult? = { args, _ in
            if !injected && args[0] == mutation {
              injected = true
              if throwsError { throw ToolFailure.invalid("fixture " + mutation + " failure") }
              return .init(status: 5, output: "fixture " + mutation + " failure")
            }
            return nil
          }
          if afterEffect { commands.afterCommand = hook } else { commands.beforeCommand = hook }
          let error = attempt(entry, enabled: enabled, commands: commands)
          check(
            error != nil && injected && commands.disabled == enabled && commands.loaded == !enabled,
            "\(mutation) \(throwsError ? "throw" : "error status") \(afterEffect ? "after" : "before") effect restores disabled and loaded state")
        }
      }
    }

    for enabled in [false, true] {
      let commands = StartupCommandModel(label: label, disabled: enabled, loaded: !enabled)
      let entry = try inventory(commands)
      var injected = false
      commands.afterCommand = { args, _ in
        if !injected && args[0] == (enabled ? "enable" : "disable") {
          injected = true
          return .init(status: 5, output: "fixture first command error after effect")
        }
        return nil
      }
      check(
        attempt(entry, enabled: enabled, commands: commands) != nil
          && commands.disabled == enabled && commands.loaded == !enabled,
        "first \(enabled ? "enable" : "disable") error status after effect also rolls back")
    }

    do {
      let commands = StartupCommandModel(label: label, disabled: false, loaded: true)
      let entry = try inventory(commands)
      commands.beforeCommand = { args, _ in
        args[0] == "bootstrap" ? .init(status: 5, output: "fixture recovery bootstrap failed") : nil
      }
      var interrupted = false
      commands.afterCommand = { args, _ in
        if !interrupted && args[0] == "bootout" {
          interrupted = true
          throw ToolFailure.invalid("fixture bootout threw after effect")
        }
        return nil
      }
      let error = attempt(entry, enabled: false, commands: commands)
      check(
        error?.localizedDescription.contains("恢复原状态失败") == true && !commands.loaded,
        "failed rollback reports the remaining unloaded state rather than claiming restoration")
    }
    do {
      let commands = StartupCommandModel(label: label, disabled: true, loaded: false)
      let entry = try inventory(commands)
      commands.afterCommand = { args, _ in
        if ["bootstrap", "bootout", "disable"].contains(args[0]) {
          throw ToolFailure.invalid(args[0] == "bootstrap" ? "fixture primary failure" : "fixture recovery transport failure")
        }
        return nil
      }
      let error = attempt(entry, enabled: true, commands: commands)
      check(
        error?.localizedDescription == "fixture primary failure" && commands.disabled && !commands.loaded,
        "rollback command throws after effect are checked against the restored actual state")
    }

    do {
      let commands = StartupCommandModel(label: label, disabled: false, loaded: true)
      let receipt = StartupReceipt(label: label, path: agent.path, date: Date(), disabled: true)
      let entry = try inventory(commands, receipts: [receipt])
      check(
        entry.disabled == false && entry.disabledBySweep,
        "an externally enabled service keeps receipt provenance separate from actual enable state")
      check(
        attempt(entry, enabled: entry.disabled == true, commands: commands) == nil
          && commands.disabled && !commands.loaded,
        "the action derived from actual enabled state disables despite a stale disabled receipt")
    }
    do {
      let commands = StartupCommandModel(label: label, disabled: true, loaded: false)
      let entry = try inventory(commands)
      check(
        entry.disabled == true && !entry.disabledBySweep
          && attempt(entry, enabled: entry.disabled == true, commands: commands) == nil
          && !commands.disabled && commands.loaded,
        "an externally disabled service can be enabled without a QingSweep receipt")
    }
    try writeDefault("invalid")
    let invalid = StartupCommandModel(label: label, disabled: nil, loaded: false)
    let invalidInventory = StartupItems.collect(
      home: home, receipts: [], commands: invalid, cancellation: ScanCancellation())
    check(
      invalidInventory.0.isEmpty && !invalidInventory.1.isEmpty && invalid.changes == 0,
      "a malformed plist Disabled value cannot silently become enabled by default")
    print("Startup state checks: \(passed) passed, \(failed) failed")
    if failed > 0 { exit(1) }
  }
}
