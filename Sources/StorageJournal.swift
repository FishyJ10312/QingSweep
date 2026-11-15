import Foundation
import CoreServices

struct StorageCheckpoint: Codable {
    let eventID: UInt64
    let volumes: [String]
    var journalUUID: String? = nil
    static func current() -> StorageCheckpoint {
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []).map {
            $0.path + ":" + ((try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? "unknown")
        }.sorted()
        let device = FileStamp.read(FileManager.default.homeDirectoryForCurrentUser)?.device
        let uuid = device.flatMap { FSEventsCopyUUIDForDevice($0) }.map { CFUUIDCreateString(nil, $0) as String }
        return StorageCheckpoint(eventID: FSEventsGetCurrentEventId(), volumes: volumes, journalUUID: uuid)
    }
}

/// Replays the OS journal. Any loss of history falls back to a full metadata scan.
/// A checkpoint is captured BEFORE scanning, so changes during a scan are replayed next time.
enum StorageJournal {
    private final class Replay {
        let lock = NSLock()
        var paths = Set<String>()
        var complete = false
        var invalid = false
        func consume(_ count: Int, _ raw: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>) {
            let names = unsafeBitCast(raw, to: NSArray.self)
            lock.lock(); defer { lock.unlock() }
            for i in 0..<count {
                let flag = flags[i]
                if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { complete = true; continue }
                if flag & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount | kFSEventStreamEventFlagMount) != 0 { invalid = true }
                if let name = names[i] as? String {
                    let url = URL(fileURLWithPath: name)
                    // Rescan the parent for removals and renames, including deleted directories.
                    if flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 && flag & UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) == 0 {
                        paths.insert(url.path)
                    } else { paths.insert(url.deletingLastPathComponent().path) }
                }
            }
        }
    }
    static func changes(since checkpoint: StorageCheckpoint?, roots: [StorageRoot], home: URL) -> [URL]? {
        let current = StorageCheckpoint.current()
        guard let checkpoint, checkpoint.volumes == current.volumes, checkpoint.journalUUID != nil, checkpoint.journalUUID == current.journalUUID, checkpoint.eventID <= current.eventID else { return nil }
        // External disks may carry colliding host event IDs. Use a full scan for those scopes.
        guard !roots.contains(where: { $0.url.path.hasPrefix("/Volumes/") }) else { return nil }
        if checkpoint.eventID == current.eventID { return [] }
        let replay = Replay()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(replay).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let paths = roots.filter { FileStamp.read($0.url)?.isDirectory == true }.map { $0.url.path }
        guard !paths.isEmpty else { return nil }
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            Unmanaged<Replay>.fromOpaque(info).takeUnretainedValue().consume(count, paths, flags)
        }, &context, paths as CFArray, checkpoint.eventID, 0.1, UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else { return nil }
        let queue = DispatchQueue(label: "local.qingsweep.journal")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return nil }
        defer { withExtendedLifetime(replay) { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); queue.sync {}; FSEventStreamRelease(stream) } }
        FSEventStreamFlushSync(stream)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            replay.lock.lock(); let done = replay.complete || replay.invalid; replay.lock.unlock()
            if done { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        replay.lock.lock(); defer { replay.lock.unlock() }
        guard replay.complete, !replay.invalid else { return nil }
        let ownCache = home.appendingPathComponent("Library/Application Support/QingSweep")
        return replay.paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard !SafetyPolicy.within(url, ownCache) else { return nil }
            return url
        }
    }
}
