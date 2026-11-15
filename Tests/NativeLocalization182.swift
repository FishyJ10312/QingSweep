import AppKit
import SwiftUI

@main struct NativeLocalization182 {
    @MainActor static func main() throws {
        let app=NSApplication.shared,fm=FileManager.default
        let home=URL(fileURLWithPath:"/Users/Shared/qingsweep-i18n182-fixture")
        let fresh=FileStamp.read(home)==nil
        let downloads=home.appendingPathComponent("Downloads")
        try fm.createDirectory(at:downloads,withIntermediateDirectories:true)
        if fresh {
            let fixtures:[(String,UInt8)]=[("Downloads/推荐清理.mov",41),("Downloads/项目.drp",42),("Downloads/清理",43),("Downloads/推荐清理/Example.mov",44),("Library/Caches/pip/http-v2/demo.body",45)]
            for (path,value) in fixtures {
                let file=home.appendingPathComponent(path)
                try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data(repeating:value,count:1_100_000).write(to:file)
                try fm.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-18*86400)],ofItemAtPath:file.path)
            }
        }
        let model=AppModel(home:home,loadSavedScan:false,startTimer:false)
        model.items=DiskScanner(policy:model.policy,minimumBytes:0).scan(roots:[downloads,home.appendingPathComponent("Library/Caches")],cancellation:ScanCancellation()){_ in}.items
        model.scannedAt=Date();model.scanLabel="常用位置";model.section = .results;model.selectCleanupScope(.protected);model.presentation = .files
        let db=home.appendingPathComponent("fixture-storage.sqlite")
        if FileStamp.read(db)==nil {
            _=try StorageIndex.build(at:db,roots:[StorageRoot(url:downloads,title:"文稿与项目",kind:.project)],auditor:StorageAuditor(home:home),applications:[],cancellation:ScanCancellation())
        }
        let index=try StorageIndex(url:db);model.storageIndexURL=db;model.storageInfo=try index.info();model.appSummaries=try index.summaries();model.storageCountedBytes=try index.accountedBytes(onDeviceOf:home)
        let delegate=QingSweepApplicationDelegate();delegate.model=model;app.delegate=delegate
        let menu=NSMenu(),root=NSMenuItem();menu.addItem(root);let appMenu=NSMenu()
        appMenu.addItem(withTitle:"Quit QingSweep test",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");root.submenu=appMenu;app.mainMenu=menu
        let window=NSWindow(contentRect:NSRect(x:60,y:80,width:1380,height:800),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title="QingSweep 1.8.2 · Temporary localization test";window.identifier=NSUserInterfaceItemIdentifier("main")
        let body=VStack(spacing:0){ContentView().environmentObject(model);Text(verbatim:"Temporary test files only · No personal files").font(.system(size:11)).padding(5)}
        window.contentView=NSHostingView(rootView:body);window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
        withExtendedLifetime(delegate){app.run()}
    }
}
