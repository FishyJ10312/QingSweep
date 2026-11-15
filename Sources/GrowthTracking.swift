import Foundation

struct GrowthValue: Codable, Identifiable {
  let id: String
  let title: String
  let bytes: Int64
  let folder: URL?
}
struct GrowthSnapshot: Codable, Identifiable {
  let id: UUID
  let date: Date
  let coverage: String
  let values: [GrowthValue]
}
struct GrowthChange: Identifiable {
  let id: String
  let title: String
  let before: Int64
  let after: Int64
  let folder: URL?
  var delta: Int64 { after - before }
}
struct GrowthHistory {
  private(set) var snapshots: [GrowthSnapshot] = []
  init(snapshots: [GrowthSnapshot] = []) { self.snapshots = snapshots.sorted { $0.date < $1.date } }
  mutating func record(_ snapshot: GrowthSnapshot, force: Bool = false) {
    if let last = snapshots.last, !force, last.coverage == snapshot.coverage,
      snapshot.date.timeIntervalSince(last.date) < 1800
    {
      return
    }
    snapshots.append(snapshot)
    snapshots = Array(snapshots.suffix(180))
  }
  func comparison(days: Int = 0) -> (GrowthSnapshot, GrowthSnapshot)? {
    guard let newest = snapshots.last else { return nil }
    let comparable = snapshots.dropLast().filter { $0.coverage == newest.coverage }
    guard !comparable.isEmpty else { return nil }
    let date = newest.date.addingTimeInterval(-Double(days) * 86400)
    let previous =
      days == 0 ? comparable.last : comparable.last(where: { $0.date <= date }) ?? comparable.first
    return previous.map { ($0, newest) }
  }
  static func changes(from old: GrowthSnapshot, to new: GrowthSnapshot) -> [GrowthChange] {
    guard old.coverage == new.coverage else { return [] }
    let a = Dictionary(uniqueKeysWithValues: old.values.map { ($0.id, $0) })
    let b = Dictionary(uniqueKeysWithValues: new.values.map { ($0.id, $0) })
    return Set(a.keys).union(b.keys).map { id in
      GrowthChange(
        id: id, title: b[id]?.title ?? a[id]!.title, before: a[id]?.bytes ?? 0,
        after: b[id]?.bytes ?? 0, folder: b[id]?.folder ?? a[id]?.folder)
    }.filter { $0.delta != 0 }.sorted { abs($0.delta) > abs($1.delta) }
  }
  static func capture(index: StorageIndex, applications: [InstalledApplication], date: Date? = nil)
    throws -> GrowthSnapshot?
  {
    let info = try index.info()
    guard try index.pendingRoots().isEmpty, !info.cancelled, !info.limited else { return nil }
    let issues = try index.issues().map { $0.id }.sorted().joined(separator: "\n")
    let scope = info.roots.map {
      $0.url.path + ":" + (StorageVolumeUsage.identity(for: $0.url) ?? "unknown")
    }.sorted().joined(separator: "\n")
    let coverage = LocalFiles.textDigest("owners-v2\n" + scope + "\n" + issues)
    let apps = try index.summaries(applications: applications).map {
      GrowthValue(id: $0.id, title: $0.title, bytes: $0.bytes, folder: nil)
    }
    return GrowthSnapshot(
      id: UUID(), date: date ?? info.scannedAt, coverage: coverage, values: apps)
  }
}
struct MemoryTrendSample {
  let date: Date
  let used: Int64
  let swap: Int64
  let pressure: Int32
  let processes: [String: Int64]
}
struct MemoryTrend {
  private(set) var samples: [MemoryTrendSample] = []
  mutating func record(_ snapshot: SystemSnapshot) {
    samples.append(
      MemoryTrendSample(
        date: snapshot.timestamp, used: snapshot.memoryUsed, swap: snapshot.swap,
        pressure: snapshot.pressure,
        processes: Dictionary(snapshot.processes.map { ($0.id, $0.bytes) }, uniquingKeysWith: max)))
    samples = Array(samples.suffix(120))
  }
  func delta(for process: String) -> Int64? {
    guard let last = samples.last, let now = last.processes[process],
      let first = samples.first(where: { $0.date >= last.date.addingTimeInterval(-300) }),
      first.date < last.date, let before = first.processes[process]
    else { return nil }
    return now - before
  }
}
