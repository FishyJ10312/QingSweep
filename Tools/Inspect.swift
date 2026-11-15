import Foundation

@main struct Inspect {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scanner = DiskScanner(policy: SafetyPolicy(), minimumBytes: 1_000_000)
        let result = autoreleasepool {
            scanner.scan(roots: ["Downloads", "Library/Caches", "Library/Logs"].map { home.appendingPathComponent($0) }, cancellation: ScanCancellation()) { _ in }
        }
        let archive = ScanArchive(scannedAt: Date(), label: "下载、旧缓存与日志", result: result, preselectPriority: false, configuration: ScanConfiguration(roots: ["Downloads", "Library/Caches", "Library/Logs"].map { home.appendingPathComponent($0) }, label: "常用位置", minimumBytes: 1_000_000))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(archive).write(to: output.appendingPathComponent("轻扫扫描结果.json"), options: .atomic)
        let groups = AssessmentGroup.build(result.items)
        var lines = ["轻扫 1.3 · 清理候选与分类审查", "扫描时间：\(archive.scannedAt.formatted(date: .complete, time: .shortened))", "范围：下载、用户缓存、用户日志；至少 1 MB，缓存/日志至少 7 天未修改。", "本次只做审查，未移动或删除真实文件。素材、项目、预设、文档和运行资源锁定保护。", "扫描 \(result.items.count) 项，占用约 \(formatBytes(result.items.reduce(0) { $0 + $1.bytes }))。", ""]
        for decision in CleanupDisposition.allCases {
            lines.append("【\(decision.rawValue)】")
            for group in groups where group.assessment.disposition == decision {
                lines.append("\(group.assessment.group)：\(formatBytes(group.bytes)) / \(group.items.count) 项")
                lines.append("理由：\(group.assessment.reason)")
                lines.append("证据类型：\(group.assessment.confidence)")
                if decision == .priority || decision == .conditional || group.items.count == 1 { lines.append("示例依据：\(group.assessment.evidence)") }
                if let source = group.assessment.sourceURL { lines.append("官方说明：\(source)") }
                if decision == .priority && group.assessment.category == .installer { lines += group.items.map { "文件：\($0.url.path)" } }
                lines.append("")
            }
        }
        lines += ["说明：", "1. 旧安装包版本比较来自文件名与本机 Info.plist，未挂载或执行安装包，也未核验包内版本。", "2. 可重建不等于绝对没用。pip/Homebrew 缓存清理后可能重新下载或构建；先停止安装/更新任务。", "3. Camera Raw 与 Chrome 缓存需要另外确认并退出相关应用；不在优先清单中。", "4. ZIP/RAR 不直接视为安装包；未知缓存、离线数据、会话资源不会自动入选。", "5. 所有容量是分配块占用估计。文件会变化；清理时重新校验。移到废纸篓并不会立即释放空间。", "6. 扫描报告与清单只保存在本机，包含你的文件路径，请按私人文件保管。"]
        try lines.joined(separator: "\n").write(to: output.appendingPathComponent("待确认清理清单.txt"), atomically: true, encoding: .utf8)
        print("Scanned \(result.visited) entries; \(result.items.count) files; \(result.issues.count) read issues.")
        for group in groups { print("\(group.assessment.disposition.rawValue) | \(group.assessment.group) | \(group.items.count) | \(formatBytes(group.bytes))") }
        let priority = result.items.filter { $0.assessment.disposition == .priority }
        print("Priority: \(priority.count) files, \(formatBytes(priority.reduce(0) { $0 + $1.bytes }))")
    }
}
