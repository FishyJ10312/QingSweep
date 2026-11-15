import AppKit
import Foundation

@MainActor final class FixtureApplications: CleanupApplicationEnvironment {
    var snapshot = CleanupUsage()
    var requested: [Int32] = []
    var onQuit: ((CleanupApplication) -> Bool)?
    var onRead: (() throws -> Void)?
    func usage(for items: [ScanItem]) async throws -> CleanupUsage { try onRead?(); return snapshot }
    func requestQuit(_ app: CleanupApplication) -> Bool {
        requested.append(app.pid)
        if let onQuit { return onQuit(app) }
        snapshot.applications.removeAll { $0.pid == app.pid }
        for path in snapshot.openFiles.keys { snapshot.openFiles[path]?.remove(app.pid) }
        return true
    }
}

@main struct CleanupExecutionTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default, base = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("testdata-quit-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let policy = SafetyPolicy(home: base), bytes = Data(repeating: 0x37, count: 4096)
        var checks = 0
        func check(_ value: Bool, _ name: String) { if !value { fatalError("FAIL: " + name) }; checks += 1; print("PASS: " + name) }
        func make(_ name: String) throws -> ScanItem {
            let url = base.appendingPathComponent("Downloads/" + name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            let stamp = FileStamp.read(url)!
            return ScanItem(url: url, root: base, stamp: stamp, assessment: FileClassifier(policy: policy, context: InspectionContext()).assess(url, stamp: stamp))
        }
        let editor = CleanupApplication(pid: 900001, bundleID: "test.qingsweep.editor", name: "Fixture Editor", canQuit: true)
        let unrelated = CleanupApplication(pid: 900002, bundleID: "test.qingsweep.unrelated", name: "Unrelated", canQuit: true)
        var file = try make("clip.mp4")
        func environment() -> FixtureApplications {
            let env = FixtureApplications(); env.snapshot.applications = [editor, unrelated]; env.snapshot.openFiles[file.id] = [editor.pid]; return env
        }
        let env = environment()
        let denied = await CleanupExecutor(environment: env, quitTimeout: 0).run([file], policy: policy, consent: nil, cancellation: ScanCancellation()) { _ in }
        check(denied.trash.records.isEmpty && env.requested.isEmpty && fm.fileExists(atPath: file.id), "missing manual consent cannot quit apps or move a file")
        var consent = ManualCleanupConsent(reviewedItems: [file])
        let done = await CleanupExecutor(environment: env, quitTimeout: 0).run([file], policy: policy, consent: consent, cancellation: ScanCancellation()) { _ in }
        check(done.trash.records.count == 1 && done.closedApplications == ["Fixture Editor"], "observed graceful exit permits confirmed fixture cleanup")
        check(env.requested == [editor.pid] && env.snapshot.applications == [unrelated], "only the app using a selected file receives a quit request")
        try TrashService(policy: policy).restore(done.trash.records[0])
        check((try? Data(contentsOf: file.url)) == bytes, "automatic-close cleanup remains restorable with identical bytes")

        file = ScanItem(url: file.url, root: file.root, stamp: FileStamp.read(file.url)!, assessment: file.assessment)
        consent = ManualCleanupConsent(reviewedItems: [file])
        let refused = environment(); refused.onQuit = { _ in false }
        let refusedResult = await CleanupExecutor(environment: refused, quitTimeout: 0).run([file], policy: policy, consent: consent, cancellation: ScanCancellation()) { _ in }
        check(refusedResult.trash.records.isEmpty && refusedResult.trash.errors.count == 1 && refusedResult.closedApplications.isEmpty && refused.requested == [editor.pid], "a rejected quit skips affected files without claiming the app exited")
        let pending = environment(); pending.onQuit = { _ in true }
        let pendingResult = await CleanupExecutor(environment: pending, quitTimeout: 0).run([file], policy: policy, consent: consent, cancellation: ScanCancellation()) { _ in }
        check(pendingResult.trash.records.isEmpty && pending.requested.count == 1, "accepted quit request without actual exit never permits cleanup")
        let closedHandle = environment(); closedHandle.onQuit = { _ in closedHandle.snapshot.openFiles = [:]; return true }
        let handleResult = await CleanupExecutor(environment: closedHandle, quitTimeout: 0).run([file], policy: policy, consent: consent, cancellation: ScanCancellation()) { _ in }
        check(handleResult.trash.records.isEmpty, "closing the file handle while an app is still running does not fake app exit")
        let restarted = environment(); restarted.onQuit = { _ in
            restarted.snapshot.applications = [CleanupApplication(pid: 900003, bundleID: editor.bundleID, name: editor.name, canQuit: true)]
            restarted.snapshot.openFiles = [:]; return true
        }
        let restartedResult = await CleanupExecutor(environment: restarted, quitTimeout: 0).run([file], policy: policy, consent: consent, cancellation: ScanCancellation()) { _ in }
        check(restartedResult.trash.records.isEmpty && restartedResult.closedApplications.isEmpty, "an app restarting under a different PID blocks its original files")
        let stop = ScanCancellation(), cancelled = environment()
        cancelled.onQuit = { _ in stop.cancel(); return true }
        let stopped = await CleanupExecutor(environment: cancelled, quitTimeout: 0).run([file], policy: policy, consent: consent, cancellation: stop) { _ in }
        check(stopped.cancelled && stopped.trash.records.isEmpty && fm.fileExists(atPath: file.id), "stop during app exit prevents all subsequent file moves")
        let broken = environment(); broken.onRead = { throw CleanupPreparationError.usageUnavailable }
        let failed = await CleanupExecutor(environment: broken).run([file], policy: policy, consent: consent, cancellation: ScanCancellation()) { _ in }
        check(failed.trash.records.isEmpty && broken.requested.isEmpty, "failed occupancy inspection does not close apps or move files")
        let cli = environment(); cli.snapshot.applications = [unrelated]; cli.snapshot.processNames[editor.pid] = "Fixture Command"
        let cliResult = await CleanupExecutor(environment: cli).run([file], policy: policy, consent: consent, cancellation: ScanCancellation()) { _ in }
        check(cliResult.trash.records.isEmpty && cli.requested.isEmpty, "CLI file users are skipped without terminating Terminal or background processes")
        let another = try make("other.jpg"), partial = environment(); partial.onQuit = { _ in false }
        let partialResult = await CleanupExecutor(environment: partial, quitTimeout: 0).run([file, another], policy: policy, consent: ManualCleanupConsent(reviewedItems: [file, another]), cancellation: ScanCancellation()) { _ in }
        check(partialResult.trash.records.map(\.original) == [another.url] && fm.fileExists(atPath: file.id), "a blocked application does not prevent independent reviewed files from being cleaned")
        try TrashService(policy: policy).restore(partialResult.trash.records[0])
        let cacheURL = base.appendingPathComponent("Library/Caches/test.qingsweep.editor/data.bin")
        try fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true); try bytes.write(to: cacheURL)
        let cacheStamp = FileStamp.read(cacheURL)!
        let cache = ScanItem(url: cacheURL, root: base, stamp: cacheStamp, assessment: FileClassifier(policy: policy, context: InspectionContext()).assess(cacheURL, stamp: cacheStamp))
        let cacheApp = FixtureApplications(); cacheApp.snapshot.applications = [editor]
        let cacheResult = await CleanupExecutor(environment: cacheApp, quitTimeout: 0).run([cache], policy: policy, consent: ManualCleanupConsent(reviewedItems: [cache]), cancellation: ScanCancellation()) { _ in }
        if let record = cacheResult.trash.records.first { try TrashService(policy: policy).restore(record) }
        check(cacheApp.requested == [editor.pid] && cacheResult.trash.records.count == 1, "a cache directory with an exact app identifier closes its app even without an open handle")
        let changed = environment(); changed.onQuit = { _ in
            try! Data("saved during quit".utf8).write(to: file.url)
            changed.snapshot.applications = []; changed.snapshot.openFiles = [:]; return true
        }
        let changedResult = await CleanupExecutor(environment: changed, quitTimeout: 0).run([file], policy: policy, consent: consent, cancellation: ScanCancellation()) { _ in }
        check(changedResult.trash.records.isEmpty && (try? Data(contentsOf: file.url)) == Data("saved during quit".utf8), "files modified while saving on quit require a new scan")
        check(fm.fileExists(atPath: another.id), "restored independent fixture remains present")
        print("\(checks) application-cleanup checks passed; lifecycle boundary simulated, Trash and restore real.")
    }
}
