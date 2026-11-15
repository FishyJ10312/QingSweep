import AppKit
import SwiftUI

// A native fixture host for CUA. It exposes production views, no synthesized input.
@main struct NativeWorkflow17 {
  @MainActor static func main() throws {
    let fm = FileManager.default
    let home = URL(fileURLWithPath: "/Users/Shared/qingsweep-ui17-fixture")
    guard FileStamp.read(home) == nil else { throw ToolFailure.invalid("已有验收夹具，请检查后再启动") }
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let artifacts = URL(fileURLWithPath: "/Users/Shared/qingsweep-ui17-observed")
    try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
    @discardableResult func file(
      _ path: String, _ data: Data = Data(repeating: 48, count: 1_100_000)
    ) throws -> URL {
      let url = home.appendingPathComponent(path)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
      try fm.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -12 * 86400)], ofItemAtPath: url.path)
      return url
    }
    let proxy = try file("Movies/ProxyMedia/Travel/clip.mov")
    _ = try file("Movies/CacheClip/Travel/cache.dvcc")
    _ = try file("Downloads/Projects/edit.drp")
    _ = try file("Downloads/Duplicates/copy-A.mov")
    _ = try file("Downloads/Duplicates/copy-B.mov")
    _ = try file("Downloads/old-package.dmg")
    _ = try file("Documents/ArchiveInput/clip.txt")
    try fm.createDirectory(
      at: home.appendingPathComponent("ArchiveTarget"), withIntermediateDirectories: true)
    let id = "local.qingsweep.fixture.removable"
    let appDir = home.appendingPathComponent("Applications/示例应用.app/Contents")
    try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": id, "CFBundleName": "示例应用", "CFBundleShortVersionString": "1.0",
      ], format: .xml, options: 0
    ).write(to: appDir.appendingPathComponent("Info.plist"))
    _ = try file("Applications/示例应用.app/Contents/data")
    _ = try file("Library/Caches/" + id + "/entry.cache")
    let root = StorageRoot(
      url: home.appendingPathComponent("Movies"), title: "视频与素材", kind: .project)
    let db = home.appendingPathComponent("storage.sqlite")
    _ = try StorageIndex.build(
      at: db, roots: [root], auditor: StorageAuditor(home: home), applications: [],
      cancellation: ScanCancellation())
    let model = AppModel(home: home, loadSavedScan: false, startTimer: false)
    model.storageIndexURL = db
    model.storageInfo = try StorageIndex(url: db).info()
    model.appSummaries = try StorageIndex(url: db).summaries()
    model.storageCountedBytes = try StorageIndex(url: db).accountedBytes(onDeviceOf: home)
    model.items =
      DiskScanner(policy: model.policy, minimumBytes: 0).scan(
        roots: [home.appendingPathComponent("Downloads")], cancellation: ScanCancellation()
      ) { _ in }.items
    model.workbench.applications = AppInventory.collect(
      home: home, roots: [home.appendingPathComponent("Applications")])
    let sample = MediaAssociation(
      media: proxy, original: home.appendingPathComponent("Downloads/Duplicates/copy-A.mov"),
      originalStamp: FileStamp.read(
        home.appendingPathComponent("Downloads/Duplicates/copy-A.mov"))!, confirmedAt: Date())
    model.workbench.associations = [sample]
    model.workbench.duplicates = DuplicateFinder.scan(
      roots: [home.appendingPathComponent("Downloads/Duplicates")], home: home,
      cancellation: ScanCancellation())
    let app = NSApplication.shared
    let delegate = QingSweepApplicationDelegate()
    delegate.model = model
    app.delegate = delegate
    let window = NSWindow(
      contentRect: NSRect(x: 80, y: 80, width: 1360, height: 760),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = "轻扫 1.7 · 临时夹具验收"
    window.identifier = NSUserInterfaceItemIdentifier("main")
    window.contentView = NSHostingView(rootView: ContentView().environmentObject(model))
    window.makeKeyAndOrderFront(nil)
    let menu = NSMenu()
    let appMenu = NSMenu()
    let item = NSMenuItem(title: "轻扫验收", action: nil, keyEquivalent: "")
    item.submenu = appMenu
    menu.addItem(item)
    appMenu.addItem(
      withTitle: "退出轻扫验收", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    app.mainMenu = menu
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
      Task { @MainActor in
        let state: [String: Any] = [
          "home": home.path, "section": model.section.rawValue,
          "tool": model.workbench.section.rawValue, "selected": model.selected.count,
          "history": model.history.count, "receipts": model.cleanupReceipts.count,
          "archives": model.workbench.archives.count, "media": model.workbench.media.files.count,
          "duplicates": model.workbench.duplicates.groups.count, "busy": model.busy,
          "files": model.history.map { ["original": $0.original.path, "trash": $0.trashed.path] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: .prettyPrinted) {
          try? data.write(to: artifacts.appendingPathComponent("state.json"), options: .atomic)
        }
      }
    }
    app.run()
    timer.invalidate()
    if model.history.isEmpty { try? fm.removeItem(at: home) }
  }
}
