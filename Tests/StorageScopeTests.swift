import AppKit
import Foundation

struct ScopeCheckFailure: Error { let message:String }
@main struct StorageScopeTests {
    @MainActor static func main() async {
        setbuf(stdout,nil)
        do { try await run() } catch { fputs("FAIL: \(error)\n",stderr);exit(1) }
    }
    @MainActor static func run() async throws {
        _=NSApplication.shared
        let fm=FileManager.default
        let home=URL(fileURLWithPath:"/Users/Shared/qingsweep-scope183-"+UUID().uuidString)
        defer { try? fm.removeItem(at:home) }
        var count=0
        func check(_ value:Bool,_ title:String)throws {guard value else{throw ScopeCheckFailure(message:title)};count+=1;print("PASS: "+title)}
        func file(_ relative:String)throws->URL {let u=home.appendingPathComponent(relative);try fm.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(repeating:71,count:8192).write(to:u);return u}
        let download=try file("Downloads/Demo-download.bin"),document=try file("Documents/Demo-project.drp")
        let picture=try file("Pictures/Demo-image.raw"),movie=try file("Movies/Demo-clip.mov")
        let desktop=try file("Desktop/Demo-desktop.bin"),music=try file("Music/Demo-audio.wav")
        let extra=try file("ExtraScope/Demo-extra.bin")
        let defaults=["Downloads","Documents","Pictures","Movies","Desktop","Music"].map{StorageRoot(url:home.appendingPathComponent($0),title:$0,kind:.project)}
        let prior=[defaults[0],StorageRoot(url:extra.deletingLastPathComponent(),title:"Chosen extra scope",kind:.project)]
        let model=AppModel(home:home,loadSavedScan:false,startTimer:false)
        let db=home.appendingPathComponent("Library/Application Support/QingSweep/storage-index.sqlite")
        _=try StorageIndex.build(at:db,roots:prior,auditor:StorageAuditor(home:home),applications:[],cancellation:ScanCancellation())
        model.storageIndexURL=db;model.storageInfo=try StorageIndex(url:db).info()
        func wait() async throws {let deadline=Date().addingTimeInterval(40);while(model.analyzing || model.storageAutoContinue && !model.storagePendingRoots.isEmpty) && Date()<deadline{try await Task.sleep(nanoseconds:20_000_000)};guard !model.analyzing else{throw ScopeCheckFailure(message:"scan did not finish")}}
        model.runStorageAnalysis(navigate:false,full:true);try await wait()
        try check(try StorageIndex(url:db).item(at:document)==nil,"current-scope full rescan does not unexpectedly expand scope")
        model.analyzeAllStorageLocations(defaultRoots:defaults+[defaults[1]])
        try await wait()
        let index=try StorageIndex(url:db)
        try check(try index.item(at:document) != nil,"Analyze all includes Documents outside the previous narrow index")
        try check(try index.item(at:picture) != nil && index.item(at:movie) != nil,"Analyze all includes pictures and video scopes")
        try check(try index.item(at:desktop) != nil && index.item(at:music) != nil,"Analyze all includes desktop and music scopes")
        try check(try index.item(at:extra) != nil,"expanding default locations preserves a previously chosen extra scope")
        try check(model.storageHasPersonalCoverage,"personal coverage becomes complete after scope expansion")
        let roots=try index.info().roots
        try check(Set(roots.map{$0.url.path}).count==roots.count,"duplicate requested roots are queued only once")
        let expected=[download,document,picture,movie,desktop,music,extra].reduce(Int64(0)){$0+FileStamp.read($1)!.allocated}
        try check(try index.summaries().reduce(Int64(0)){$0+$1.bytes}==expected,"expanded analysis neither loses nor double-counts file bytes")
        try check(model.selected.isEmpty,"read-only scope expansion leaves media and projects unselected")
        model.analyzeAllStorageLocations(defaultRoots:defaults);try await wait()
        let again=try StorageIndex(url:db)
        try check(try again.info().roots.count==roots.count,"repeated Analyze all is idempotent")
        try check(try again.summaries().reduce(Int64(0)){$0+$1.bytes}==expected,"repeated full analysis preserves accurate accounting")
        try check(try again.pendingRoots().isEmpty,"completed expanded analysis clears its continuation queue")
        model.runStorageAnalysis(navigate:false,full:true);try await wait()
        try check(try StorageIndex(url:db).info().roots.count==roots.count,"later current-scope updates preserve the expanded scan range")
        model.analyzeAllStorageLocations(defaultRoots:defaults);model.cancelStorageAnalysis();try await wait()
        try check(!model.storageAutoContinue,"Stop prevents automatic scan continuation")
        try check(try StorageIndex(url:db).item(at:document) != nil,"cancelling expanded analysis preserves existing indexed files")
        try check(try Data(contentsOf:document)==Data(repeating:71,count:8192),"analysis and cancellation leave project bytes unchanged")
        try check(model.selected.isEmpty,"cancellation never turns analysis into cleanup selection")
        let freshHome=home.appendingPathComponent("Fresh")
        let freshDoc=freshHome.appendingPathComponent("Documents/First-project.drp");try fm.createDirectory(at:freshDoc.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(repeating:72,count:8192).write(to:freshDoc)
        let fresh=AppModel(home:freshHome,loadSavedScan:false,startTimer:false)
        fresh.analyzeAllStorageLocations(defaultRoots:[StorageRoot(url:freshDoc.deletingLastPathComponent(),title:"Documents",kind:.project)])
        let deadline=Date().addingTimeInterval(30)
        while fresh.analyzing && Date()<deadline {try await Task.sleep(nanoseconds:20_000_000)}
        let freshIndexed=try StorageIndex(url:fresh.storageIndexURL).item(at:freshDoc) != nil
        try check(!fresh.analyzing && freshIndexed,"Analyze all also builds a fresh requested scope when no index exists")
        print("\(count) storage-scope checks passed; only generated temporary files were scanned")
    }
}
