import SwiftUI
import AppKit

@main struct NativeWorkflow16 {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: "/Users/Shared").appendingPathComponent("qingsweep-ui16-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let artifacts = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/native16")
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        @MainActor func file(_ name: String, bytes: Int = 1_100_000) throws -> URL {
            let url = home.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x30, count: bytes).write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -12 * 86400)], ofItemAtPath: url.path)
            return url
        }
        _ = try file("Downloads/IINA.v1.0.0.dmg")
        _ = try file("Downloads/Projects/edit.drp")
        let image = try file("Downloads/素材.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<320 { for y in 0..<200 { bitmap.setColor(NSColor(calibratedRed: 0.15, green: CGFloat(x)/320, blue: CGFloat(y)/200, alpha: 1), atX: x,y: y) } }
        var png = bitmap.representation(using: .png, properties: [:])!; png.append(Data(repeating: 0, count: 1_100_000)); try png.write(to: image)
        _ = try file("Applications/IINA.app/Contents/Info.plist", bytes: 0)
        let info: [String:Any] = ["CFBundleIdentifier":"com.colliderli.iina","CFBundleName":"IINA","CFBundleShortVersionString":"9.0.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: home.appendingPathComponent("Applications/IINA.app/Contents/Info.plist"))
        for path in ["Movies/group","Documents","Pictures","Desktop","Music","Library/Caches","Library/Logs"] { try fm.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true) }
        _ = try file("Movies/group/clip.mov", bytes: 8192)
        let roots = ["Movies","Documents","Pictures","Desktop","Music"].map { StorageRoot(url: home.appendingPathComponent($0), title: $0, kind: .project) }
        let db = home.appendingPathComponent("storage.sqlite")
        _ = try StorageIndex.build(at: db, roots: roots, auditor: StorageAuditor(home: home), applications: [], cancellation: ScanCancellation())
        let model = AppModel(home: home, loadSavedScan: false, startTimer: false)
        model.storageIndexURL = db; model.storageInfo = try StorageIndex(url: db).info(); model.appSummaries = try StorageIndex(url: db).summaries(); model.storageCountedBytes = try StorageIndex(url: db).accountedBytes(onDeviceOf: home)
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 100,y: 80,width: 1360,height: 760), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "轻扫 1.6 · 临时夹具验收"
        let host = NSHostingView(rootView: ContentView().environmentObject(model)); window.contentView = host
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        try "".write(to: artifacts.appendingPathComponent("commands.jsonl"), atomically: true, encoding: .utf8)
        Task { @MainActor in
            var processed = 0
            @MainActor func capture(_ name: String) throws {
                for (n,w) in NSApp.windows.filter({ $0.isVisible }).enumerated() {
                    guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])!.write(to: artifacts.appendingPathComponent(name + "-\(n).png"))
                }
            }
            while true {
                do {
                    let raw = (try? String(contentsOf: artifacts.appendingPathComponent("commands.jsonl"), encoding: .utf8)) ?? ""
                    let lines = raw.split(separator: "\n")
                    while processed < lines.count {
                        let command = try JSONSerialization.jsonObject(with: Data(lines[processed].utf8)) as! [String:Any]
                        processed += 1
                        switch command["action"] as? String {
                        case "click":
                            let target = (command["panel"] as? Bool == true ? NSApp.windows.first { $0.isVisible && $0 !== window } : nil) ?? window
                            guard let view = target.contentView else { continue }
                            let top = command["y"] as! Double
                            let point = view.convert(NSPoint(x: command["x"] as! Double, y: view.isFlipped ? top : view.bounds.height - top), to: nil)
                            for kind in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                                let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, eventNumber: processed, clickCount: 1, pressure: 0.5)!
                                app.postEvent(event, atStart: false)
                            }
                        case "key":
                            let text = command["text"] as! String
                            let code = UInt16(command["code"] as? Int ?? 0)
                            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: (NSApp.keyWindow ?? window).windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
                            app.postEvent(event, atStart: false)
                        case "snapshot": try capture(command["name"] as! String)
                        case "change": _ = try file("Movies/group/added.mov", bytes: 16384)
                        case "stop":
                            if !model.history.isEmpty { model.message = nil; model.restoreBatch(model.history); for _ in 0..<100 { if !model.mutating { break }; try await Task.sleep(nanoseconds: 50_000_000) } }
                            try? fm.removeItem(at: home)
                            print("Native workflow fixture stopped and recovered"); fflush(stdout)
                            exit(0)
                        default: break
                        }
                        try await Task.sleep(nanoseconds: 200_000_000)
                    }
                    let state: [String:Any] = ["pid":ProcessInfo.processInfo.processIdentifier,"fixture":home.path,"processed":processed,"section":model.section.rawValue,"scanning":model.scanning,"analyzing":model.analyzing,"loading":model.loadingReport,"mutating":model.mutating,"items":model.items.count,"selected":model.selected.sorted(),"scope":model.cleanupScope?.rawValue ?? "","review":model.review.count,"showingReview":model.showingReview,"manualConfirmation":model.showingManualConfirmation,"acknowledged":model.manualReviewAcknowledged,"history":model.history.count,"receipts":model.cleanupReceipts.count,"recoverable":model.recoverable.count,"preview":model.previewURL?.lastPathComponent ?? "","storageFolder":model.storageFolder?.path ?? "","storagePending":model.storagePendingRoots.count,"storageStatus":model.storageUpdateStatus,"message":model.message ?? "","windows":NSApp.windows.filter({$0.isVisible}).map { ["title":$0.title,"width":$0.frame.width,"height":$0.frame.height] }]
                    try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted,.sortedKeys]).write(to: artifacts.appendingPathComponent("status.json"), options: .atomic)
                } catch { print("QA error:",error); fflush(stdout) }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        app.run()
        try? fm.removeItem(at: home)
    }
}
