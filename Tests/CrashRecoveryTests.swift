import AppKit
import Darwin
import Foundation
import SQLite3

private struct CrashEnvironment: CleanupApplicationEnvironment {
    func usage(for items:[ScanItem]) async throws -> CleanupUsage { CleanupUsage() }
    func requestQuit(_ app:CleanupApplication) -> Bool { false }
}

@main struct CrashRecoveryTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil); _ = NSApplication.shared
        let args=CommandLine.arguments
        if args.count > 1, args[1] == "child" { try await child(args);return }
        let fm=FileManager.default
        let base=URL(fileURLWithPath:"/Users/Shared/qingsweep-crash181-"+UUID().uuidString)
        try fm.createDirectory(at:base,withIntermediateDirectories:true)
        var count=0
        func check(_ value:@autoclosure () throws -> Bool,_ message:String) {
            guard (try? value()) == true else{fputs("FAIL: "+message+"\n",stderr);exit(1)}
            count += 1;print("PASS: "+message)
        }
        // Only generated fixture URLs are removed. User Trash entries are never enumerated for deletion.
        defer{try? fm.removeItem(at:base)}
        var evidence:[[String:Any]]=[]
        for operation in ["move","managed","restore"] {
            let phases=operation == "restore" ? ["restoreIntent","restoreApplied","restoreRecorded"]:["moveIntent","moveApplied","moveRecorded"]
            for phase in phases {
                let home=base.appendingPathComponent(operation+"-"+phase)
                try fm.createDirectory(at:home,withIntermediateDirectories:true)
                let folder=operation == "managed" ? home.appendingPathComponent("Library/Application Support/com.example.qsfixture"):home.appendingPathComponent("Documents")
                try fm.createDirectory(at:folder,withIntermediateDirectories:true)
                let first=folder.appendingPathComponent("first-"+UUID().uuidString+".mov"),second=folder.appendingPathComponent("second-"+UUID().uuidString+".drp")
                try Data(repeating:71,count:16384).write(to:first);try Data(repeating:82,count:24576).write(to:second)
                let hashes=try [first,second].map{try LocalFiles.digest($0,expected:FileStamp.read($0)!)}
                let marker=home.appendingPathComponent("checkpoint.json")
                let p=Process();p.executableURL=URL(fileURLWithPath:args[0]);p.arguments=["child",home.path,operation,phase,first.path,second.path]
                let out=home.appendingPathComponent("child.log");fm.createFile(atPath:out.path,contents:nil)
                let handle=try FileHandle(forWritingTo:out);p.standardOutput=handle;p.standardError=handle
                try p.run()
                for _ in 0..<1500 {
                    if FileStamp.read(marker) != nil || !p.isRunning { break }
                    try await Task.sleep(nanoseconds:20_000_000)
                }
                check(FileStamp.read(marker) != nil,"\(operation)/\(phase) reached the exact production operation window")
                Darwin.kill(p.processIdentifier,SIGKILL);p.waitUntilExit();try handle.close()
                check(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGKILL,"\(operation)/\(phase) actually killed only the disposable child")
                let model=AppModel(home:home,loadSavedScan:false,startTimer:false)
                await wait{!model.reconcilingCleanup}
                check(model.cleanupJournalFailure == nil,"\(operation)/\(phase) restart reconciles without guessing")
                check(model.selected.isEmpty && model.review.isEmpty,"\(operation)/\(phase) restart selects no media or projects")
                let expected:Int
                if operation == "restore" { expected = phase == "restoreIntent" ? 2:1 }
                else if operation == "managed" { expected = phase == "moveIntent" ? 0:1 }
                else { expected = phase == "moveIntent" ? 0:1 }
                check(model.history.count == expected,"\(operation)/\(phase) reconstructs exactly \(expected) recoverable entries")
                check(Set(model.history.map(\.id)).count == model.history.count,"\(operation)/\(phase) never duplicates recovery records")
                check(model.cleanupReceipts.count == 1,"\(operation)/\(phase) reconstructs one batch receipt")
                if operation != "restore" {
                    check(model.cleanupReceipts.first?.interrupted == true,"\(operation)/\(phase) labels the interrupted batch")
                    if operation != "managed" { check(FileStamp.read(second) != nil,"\(operation)/\(phase) leaves the next file untouched") }
                }
                // Reopening a second time must be idempotent before any restore.
                let again=AppModel(home:home,loadSavedScan:false,startTimer:false)
                await wait{!again.reconcilingCleanup}
                check(Set(again.history.map(\.id)) == Set(model.history.map(\.id)),"\(operation)/\(phase) repeated restart is idempotent")
                if !model.history.isEmpty {
                    await wait{!model.busy};model.restoreBatch(model.history);await wait{!model.mutating}
                    check(model.history.isEmpty,"\(operation)/\(phase) restores through the production batch flow")
                }
                check(try [first,second].enumerated().allSatisfy{try LocalFiles.digest($0.element,expected:FileStamp.read($0.element)!) == hashes[$0.offset]},"\(operation)/\(phase) all restored bytes match the originals")
                let final=AppModel(home:home,loadSavedScan:false,startTimer:false);await wait{!final.reconcilingCleanup}
                check(final.history.isEmpty,"\(operation)/\(phase) restored entries stay removed after another restart")
                evidence.append(["operation":operation,"phase":phase,"signal":p.terminationStatus,"restart_records":expected,"restored_byte_identically":true])
            }
        }
        try await journalFailures(base:base,check:check)
        let evidenceURL=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/qa181/crash-recovery.json")
        try fm.createDirectory(at:evidenceURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]).write(to:evidenceURL)
        print("\(count) crash-recovery checks passed")
    }

    @MainActor static func child(_ args:[String]) async throws {
        let home=URL(fileURLWithPath:args[2]),operation=args[3],phase=args[4]
        let files=[URL(fileURLWithPath:args[5]),URL(fileURLWithPath:args[6])]
        let model=AppModel(home:home,loadSavedScan:false,startTimer:false,cleanupJournalCheckpoint:{point,id in
            guard String(describing:point) == phase else{return}
            try JSONSerialization.data(withJSONObject:["point":phase,"id":id.uuidString]).write(to:home.appendingPathComponent("checkpoint.json"),options:.atomic)
            Darwin.kill(getpid(),SIGSTOP)
        })
        model.cleanupEnvironment=CrashEnvironment()
        if operation == "managed" {
            let folder=files[0].deletingLastPathComponent()
            model.workbench.managedReview=[ManagedItem(url:folder,bundleID:"com.example.qsfixture",title:"Disposable fixture",role:"应用数据",tree:try FileTree.read(folder))]
            model.workbench.showingManagedReview=true;model.workbench.managedAcknowledged=true;model.moveManagedReview()
        }else {
            let classifier=FileClassifier(policy:model.policy,context:InspectionContext())
            let items=files.map{url in let stamp=FileStamp.read(url)!;return ScanItem(url:url,root:home,stamp:stamp,assessment:classifier.assess(url,stamp:stamp))}
            // Initial scan never chooses creative content; this models the user's explicit choice.
            guard model.selected.isEmpty else{exit(3)}
            model.reviewToolFiles(items,title:"Disposable crash-recovery fixture")
            model.requestReviewedMove();model.manualReviewAcknowledged=true;model.confirmManualCleanup()
        }
        await wait{!model.mutating}
        if operation == "restore" { model.restoreBatch(model.history);await wait{!model.mutating} }
    }

    @MainActor static func wait(_ done:()->Bool) async {
        for _ in 0..<2000 {if done(){return};try? await Task.sleep(nanoseconds:10_000_000)}
    }

    @MainActor static func journalFailures(base:URL,check:(_ value:@autoclosure () throws -> Bool,_ message:String)->Void) async throws {
        let fm=FileManager.default,home=base.appendingPathComponent("failures")
        try fm.createDirectory(at:home,withIntermediateDirectories:true)
        let policy=SafetyPolicy(home:home),url=home.appendingPathComponent("journal.sqlite")
        let journal=try CleanupOperationJournal(url:url)
        let file=home.appendingPathComponent("untouched.mov");try Data(repeating:3,count:8192).write(to:file)
        let stamp=FileStamp.read(file)!,classifier=FileClassifier(policy:policy,context:InspectionContext())
        let item=ScanItem(url:file,root:home,stamp:stamp,assessment:classifier.assess(file,stamp:stamp))
        let id=UUID(),batch=CleanupJournalBatch(id:id,date:Date(),title:"Failure fixture",requestedCount:1,freeBefore:0,retryFiles:[CleanupRetryTarget(item:item)],retryManaged:nil,retryOf:nil)
        try journal.begin(batch)
        // Abort SQLite commits at the storage boundary (equivalent fail-closed path to SQLITE_FULL).
        try sql(url,"CREATE TRIGGER fail_writes BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'disk full fixture'); END")
        let result=TrashService(policy:policy).move([item],manualConsent:ManualCleanupConsent(reviewedItems:[item]),journal:CleanupJournalContext(journal:journal,batchID:id))
        check(result.records.isEmpty && FileStamp.read(file) == stamp,"journal write failure before intent leaves the file untouched")
        check(journal.isBlocked,"journal write failure latches the stop state")
        try sql(url,"DROP TRIGGER fail_writes")
        check(TrashService(policy:policy).move([item],manualConsent:ManualCleanupConsent(reviewedItems:[item]),journal:CleanupJournalContext(journal:journal,batchID:id)).records.isEmpty,"latched storage failure prevents later moves even if storage recovers")
        let badHome=base.appendingPathComponent("corrupt"),support=badHome.appendingPathComponent("Library/Application Support/QingSweep")
        try fm.createDirectory(at:support,withIntermediateDirectories:true)
        let bad=support.appendingPathComponent("cleanup-operations.sqlite"),badData=Data("not a SQLite journal".utf8)
        try badData.write(to:bad)
        let model=AppModel(home:badHome,loadSavedScan:false,startTimer:false)
        check(model.cleanupJournalFailure != nil,"corrupt operation log visibly blocks new cleanup")
        check(try Data(contentsOf:bad)==badData,"corrupt operation log is preserved byte-for-byte")
        // No basename fallback: a different file at a plausible Trash path cannot be claimed.
        let other=try CleanupOperationJournal(url:home.appendingPathComponent("identity.sqlite"));try other.begin(batch)
        let context=CleanupJournalContext(journal:other,batchID:id)
        _=try other.prepareMove(original:file,stamp:stamp,bytes:stamp.allocated,context:context,checksum:LocalFiles.digest(file,expected:stamp))
        try fm.moveItem(at:file,to:home.appendingPathComponent("elsewhere.mov"))
        let state=try other.reconcile(policy:policy)
        check(state.entries.first?.state == .pending && !state.issues.isEmpty,"missing identity stays unresolved instead of trusting a filename")
        check(state.entries.first?.record == nil,"unresolved identity cannot create a recovery record")
        let gapURL=home.appendingPathComponent("commit-gap.sqlite")
        let gap=try CleanupOperationJournal(url:gapURL,checkpoint:{point,_ in
            if case .moveApplied=point {try sql(gapURL,"CREATE TRIGGER fail_writes BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'write failure after move'); END")}
        })
        let a=home.appendingPathComponent("gap-"+UUID().uuidString+".mov"),b=home.appendingPathComponent("next-"+UUID().uuidString+".drp")
        try Data(repeating:4,count:8192).write(to:a);try Data(repeating:5,count:8192).write(to:b)
        let pair=[a,b].map{ScanItem(url:$0,root:home,stamp:FileStamp.read($0)!,assessment:classifier.assess($0,stamp:FileStamp.read($0)!))}
        let gapID=UUID();try gap.begin(CleanupJournalBatch(id:gapID,date:Date(),title:"Commit failure fixture",requestedCount:2,freeBefore:0,retryFiles:pair.map{CleanupRetryTarget(item:$0)},retryManaged:nil,retryOf:nil))
        let partial=TrashService(policy:policy).move(pair,manualConsent:ManualCleanupConsent(reviewedItems:pair),journal:CleanupJournalContext(journal:gap,batchID:gapID))
        check(gap.isBlocked && partial.records.count==1,"write failure after a move retains the known in-memory recovery entry")
        check(FileStamp.read(a)==nil && FileStamp.read(b) != nil,"write failure after a move stops before touching the next file")
        try sql(gapURL,"DROP TRIGGER fail_writes")
        let resumed=try CleanupOperationJournal(url:gapURL)
        let repaired=try resumed.reconcile(policy:policy)
        check(repaired.entries.first?.record?.trashed == partial.records.first?.trashed,"restart recovers the exact actual Trash location after failed completion commit")
        var history:[TrashRecord]=[],receipts:[CleanupReceipt]=[]
        repaired.merge(history:&history,receipts:&receipts)
        check(history.count==1 && receipts.first?.retryCount==1,"journal rebuilds lost JSON history and receipt summaries")
        var historyAgain=history,receiptsAgain=receipts;repaired.merge(history:&historyAgain,receipts:&receiptsAgain)
        check(historyAgain.count==1 && receiptsAgain.count==1,"projection rebuilding never duplicates entries")
        let record=history[0]
        try Data("occupied".utf8).write(to:a)
        do {try TrashService(policy:policy).restore(record,journal:resumed);check(false,"restore rejects occupied destinations")}catch{check(try Data(contentsOf:a)==Data("occupied".utf8),"restore never overwrites an occupied destination")}
        try fm.removeItem(at:a)
        let restoreGap=try CleanupOperationJournal(url:gapURL,checkpoint:{point,_ in
            if case .restoreApplied=point {try sql(gapURL,"CREATE TRIGGER fail_writes BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'write failure after restore'); END")}
        })
        do{try TrashService(policy:policy).restore(record,journal:restoreGap);check(false,"restore completion storage error is surfaced")}catch{check(restoreGap.isBlocked,"restore completion storage error stops further operations")}
        check(try Data(contentsOf:a)==Data(repeating:4,count:8192),"restored original remains byte-identical even when its completion commit fails")
        try sql(gapURL,"DROP TRIGGER fail_writes")
        let last=try CleanupOperationJournal(url:gapURL),lastState=try last.reconcile(policy:policy)
        history=[];receipts=[];lastState.merge(history:&history,receipts:&receipts)
        check(history.isEmpty && lastState.entries.first?.state == .restored,"restart reconciles a completed restore whose outcome was not committed")
        // Legacy JSON-only records are admitted to the journal before their first restore.
        let legacyFile=home.appendingPathComponent("legacy-"+UUID().uuidString+".mov");try Data(repeating:9,count:8192).write(to:legacyFile)
        let legacyItem=ScanItem(url:legacyFile,root:home,stamp:FileStamp.read(legacyFile)!,assessment:classifier.assess(legacyFile,stamp:FileStamp.read(legacyFile)!))
        let legacy=TrashService(policy:policy).move([legacyItem],manualConsent:ManualCleanupConsent(reviewedItems:[legacyItem])).records[0]
        try TrashService(policy:policy).restore(legacy,journal:last)
        check(try last.snapshot().entries.first{$0.id==legacy.id}?.state == .restored,"older JSON-only recovery records acquire durable restore logging")
        let stopped=ScanCancellation(),cancelURL=home.appendingPathComponent("cancel-intent.sqlite")
        let cancelJournal=try CleanupOperationJournal(url:cancelURL,checkpoint:{point,_ in if case .moveIntent=point{stopped.cancel()}})
        let cancelItem=ScanItem(url:b,root:home,stamp:FileStamp.read(b)!,assessment:classifier.assess(b,stamp:FileStamp.read(b)!))
        let cancelID=UUID();try cancelJournal.begin(CleanupJournalBatch(id:cancelID,date:Date(),title:"Cancel after intent",requestedCount:1,freeBefore:0,retryFiles:[CleanupRetryTarget(item:cancelItem)],retryManaged:nil,retryOf:nil))
        let cancelled=TrashService(policy:policy).move([cancelItem],manualConsent:ManualCleanupConsent(reviewedItems:[cancelItem]),cancellation:stopped,journal:CleanupJournalContext(journal:cancelJournal,batchID:cancelID))
        check(cancelled.records.isEmpty && FileStamp.read(b)==cancelItem.stamp,"cancellation arriving after durable intent still prevents the filesystem move")
        check(try cancelJournal.snapshot().entries.first?.state == .notMoved,"cancelled intent is durably marked as not moved")
        let damagedHome=base.appendingPathComponent("damaged-event"),damagedURL=damagedHome.appendingPathComponent("Library/Application Support/QingSweep/cleanup-operations.sqlite")
        _=try CleanupOperationJournal(url:damagedURL)
        try sql(damagedURL,"INSERT INTO events(kind,key,payload) VALUES('item','fixture','{}')")
        let damaged=AppModel(home:damagedHome,loadSavedScan:false,startTimer:false)
        check(damaged.cleanupJournalFailure != nil && damaged.history.isEmpty,"invalid journal events fail closed instead of silently omitting recovery records")
    }

    static func sql(_ url:URL,_ query:String) throws {
        var db:OpaquePointer?;guard sqlite3_open(url.path,&db)==SQLITE_OK else{throw CleanupJournalError.unavailable}
        defer{sqlite3_close(db)}
        guard sqlite3_exec(db,query,nil,nil,nil)==SQLITE_OK else{throw CleanupJournalError.unavailable}
    }
}
