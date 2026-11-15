import AppKit
import Foundation

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    let folder = URL(fileURLWithPath: CommandLine.arguments[1])
    let refuses = CommandLine.arguments.contains("refuse")
    var handle: FileHandle?
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        handle = try! FileHandle(forReadingFrom: folder.appendingPathComponent("Downloads/open.mp4"))
        try! Data("ready".utf8).write(to: folder.appendingPathComponent("ready"))
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("finish").path) { NSApplication.shared.terminate(nil) }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        refuses && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("finish").path) ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { try? handle?.close() }
}
let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
