import AppKit
import Foundation

struct FirstUseFailure: Error { let message: String }
@main struct FirstUseTests {
    @MainActor static func main() async {
        setbuf(stdout,nil)
        do { try await run() } catch { fputs("FAIL: \(error)\n",stderr);exit(1) }
    }
    @MainActor static func run() async throws {
        _=NSApplication.shared
        let fm=FileManager.default
        let home=URL(fileURLWithPath:"/Users/Shared/qingsweep-firstuse-"+UUID().uuidString)
        let downloads=home.appendingPathComponent("Downloads")
        defer { try? fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:downloads.path);try? fm.removeItem(at:home) }
        for folder in ["Downloads","Library/Caches","Library/Logs"] {try fm.createDirectory(at:home.appendingPathComponent(folder),withIntermediateDirectories:true)}
        let file=downloads.appendingPathComponent("Demo-project.drp");try Data(repeating:45,count:1_300_000).write(to:file)
        try fm.setAttributes([.posixPermissions:0],ofItemAtPath:downloads.path)
        let model=AppModel(home:home,loadSavedScan:false,startTimer:false)
        var count=0
        func check(_ value:Bool,_ title:String)throws {guard value else{throw FirstUseFailure(message:title)};count += 1;print("PASS: "+title)}
        func wait() async throws {let limit=Date().addingTimeInterval(25);while model.scanning && Date()<limit{try await Task.sleep(nanoseconds:20_000_000)};try check(!model.scanning,"scan finishes within fixture limit")}
        model.quickScan();try await wait()
        try check(model.cleanupIsPartial && model.result?.issues.isEmpty == false,"a denied first scan is reported as partial")
        try check(model.showingIssues,"a denied first scan opens actionable access guidance")
        try check(model.selected.isEmpty,"denied first scan never selects media or projects")
        let issue=model.result?.accessIssues?.first
        try check(issue?.url.path==downloads.path && issue?.root.path==downloads.path && issue?.kind == .permission,"denied scan retains its actual location and permission kind")
        let reportURL=home.appendingPathComponent("Library/Application Support/QingSweep/last-scan.json")
        let report=try JSONDecoder().decode(ScanArchive.self,from:Data(contentsOf:reportURL))
        try check(report.result.accessIssues?.first?.url.path==downloads.path,"saved scan retains structured access guidance")
        let originalRoots=model.currentScanConfiguration!.roots
        model.recheckCleanupScanAccess();try await wait()
        try check(model.showingIssues && model.result?.accessIssues?.first?.kind == .permission,"recheck performs a real read and retains guidance while still denied")
        try check(!model.storageIndexUnavailable,"cleanup access checks do not require or corrupt a storage index")
        let stillDenied=AppModel(home:home,loadSavedScan:true,startTimer:false)
        let readLimit=Date().addingTimeInterval(25)
        while (stillDenied.loadingReport || stillDenied.loadingStorageIndex) && Date()<readLimit {try await Task.sleep(nanoseconds:20_000_000)}
        try check(!stillDenied.scanning && !stillDenied.items.contains{$0.url==file},"relaunch with denied access does not pretend the project was scanned")
        try check(stillDenied.result?.accessIssues?.first?.kind == .permission,"relaunch retains the permission issue for the access action")
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:downloads.path)
        let reopened=AppModel(home:home,loadSavedScan:true,startTimer:false)
        let reopenLimit=Date().addingTimeInterval(20)
        while !reopened.items.contains(where:{$0.url==file}) && Date()<reopenLimit {try await Task.sleep(nanoseconds:20_000_000)}
        try check(reopened.items.contains{$0.url==file},"relaunch after access is restored automatically rescans the saved scope")
        try check(reopened.selected.isEmpty && reopened.currentScanConfiguration?.roots==originalRoots,"automatic access recovery preserves scope and never selects creative files")
        model.recheckCleanupScanAccess();try await wait()
        try check(model.result?.issues.isEmpty == true && model.result?.accessIssues?.isEmpty == true,"restored access clears errors only after scanning succeeds")
        try check(!model.showingIssues && !model.scanning,"successful recheck returns to the updated results")
        try check(model.currentScanConfiguration?.roots==originalRoots,"access recheck preserves the chosen scan scope")
        try check(model.items.contains{$0.url==file},"recovered scan includes the previously unread project")
        try check(model.selected.isEmpty,"recovered project stays unselected")
        model.selectPriority()
        try check(model.selected.isEmpty,"recommendations do not select the recovered project")
        let legacy=Data(#"{"items":[],"visited":0,"skipped":0,"issues":[],"cancelled":false,"limited":false,"elapsed":0}"#.utf8)
        let older=try JSONDecoder().decode(ScanResult.self,from:legacy)
        try check(older.accessIssues==nil && older.items.isEmpty,"older scan results without access metadata remain readable")
        let missing=home.appendingPathComponent("Not-created-yet")
        model.scan(roots:[missing],label:"Chosen fixture",minimum:1_000_000);try await wait()
        try check(model.result?.accessIssues?.first?.kind == .missing,"missing directories are distinct from permission denial")
        try check(!model.showingIssues,"missing locations do not automatically ask for permission")
        let added=missing.appendingPathComponent("New-video.mov");try fm.createDirectory(at:missing,withIntermediateDirectories:true);try Data(repeating:46,count:1_400_000).write(to:added)
        model.recheckCleanupScanAccess();try await wait()
        try check(model.currentScanConfiguration?.roots==[missing] && model.items.contains{$0.url==added},"recheck scans an explicitly chosen folder instead of default locations")
        try check(model.selected.isEmpty,"media stays unselected after the missing folder becomes available")
        let unchanged=try Data(contentsOf:file)==Data(repeating:45,count:1_300_000)
        try check(unchanged,"access failure and recovery preserve original project bytes")
        model.selectCleanupScope(.protected);model.toggle(model.items.first!,on:true);model.prepareCurrentReview()
        let reviewed=model.review
        model.recheckCleanupScanAccess()
        try check(model.showingReview && !model.scanning && model.review.map(\.id)==reviewed.map(\.id),"access recheck cannot replace an active cleanup confirmation")
        print("\(count) first-use access checks passed; generated files only")
    }
}
