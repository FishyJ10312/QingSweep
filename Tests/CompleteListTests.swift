import Foundation
@main struct CompleteListTests {
    static func main() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: "/Users/Shared").appendingPathComponent("QingSweep-complete-list-" + UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let folder = home.appendingPathComponent("Movies/ProxyMedia")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<30017 { try Data([0x31]).write(to: folder.appendingPathComponent("clip-\(i).mov")) }
        let result = DiskScanner(policy: SafetyPolicy(home: home), minimumBytes: 0).scan(roots: [folder], cancellation: ScanCancellation()) { _ in }
        print("Fixture issues:", result.issues)
        guard result.items.count == 30017, !result.limited else { print("FAIL: complete cleanup list: expected 30017, got \(result.items.count), limited=\(result.limited)"); exit(1) }
        guard result.items.allSatisfy({ $0.assessment.requiresIndividualConfirmation }) else { fatalError("Media must require deliberate selection") }
        print("PASS: all 30017 files retained; media requires explicit confirmation")
    }
}
