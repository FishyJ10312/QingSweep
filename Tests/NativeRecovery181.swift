import AppKit
import SwiftUI

/// Native CUA host. Only its generated fixtures can enter the intentional crash window.
@main struct NativeRecovery181 {
    @MainActor static func main() throws {
        let app=NSApplication.shared, fm=FileManager.default
        let home=URL(fileURLWithPath:"/Users/Shared/qingsweep-ui181-fixture")
        let docs=home.appendingPathComponent("Downloads")
        let fresh=FileStamp.read(home)==nil
        try fm.createDirectory(at:docs,withIntermediateDirectories:true)
        let arm=home.appendingPathComponent("armed"),marker=home.appendingPathComponent("crash-window")
        if fresh {
            try Data(repeating:41,count:16384).write(to:docs.appendingPathComponent("演示素材.mov"))
            try Data(repeating:52,count:8192).write(to:docs.appendingPathComponent("演示项目.drp"))
            try Data().write(to:arm)
        }
        let model=AppModel(home:home,loadSavedScan:false,startTimer:false,cleanupJournalCheckpoint:{point,_ in
            guard case .moveApplied=point,FileStamp.read(arm) != nil else{return}
            try fm.removeItem(at:arm);try Data("filesystem moved; completion not committed".utf8).write(to:marker,options:.atomic)
            Thread.sleep(forTimeInterval:300) // The verifier kills this disposable process, never a user app.
        })
        model.items=DiskScanner(policy:model.policy,minimumBytes:0).scan(roots:[docs],cancellation:ScanCancellation()){_ in}.items
        model.section=FileStamp.read(marker)==nil ? .results:.history
        model.scannedAt=Date();model.scanLabel="临时夹具";model.selectCleanupScope(.protected);model.presentation = .files
        let delegate=QingSweepApplicationDelegate();delegate.model=model;app.delegate=delegate
        let menu=NSMenu(),root=NSMenuItem();menu.addItem(root)
        let appMenu=NSMenu();appMenu.addItem(withTitle:"退出轻扫恢复验收",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");root.submenu=appMenu;app.mainMenu=menu
        let window=NSWindow(contentRect:NSRect(x:80,y:80,width:1380,height:800),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title="轻扫 1.8.1 · 恢复验收（临时文件）"
        window.contentView=NSHostingView(rootView:ContentView().environmentObject(model))
        window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
        withExtendedLifetime(delegate){app.run()}
    }
}
