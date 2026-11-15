import AVFoundation
import CoreMedia
import Foundation

struct VideoFacts: Codable {
  let duration: Double
  let width: Int
  let height: Int
  let codec: String
  var description: String {
    "\(width) × \(height) · \(codec) · " + String(format: "%.1f 秒", duration)
  }
}
enum VideoInspector {
  static func inspect(_ url: URL, stamp: FileStamp) async throws -> VideoFacts {
    guard LocalFiles.noLinks(url), stamp.isRegular, !stamp.isDataless, FileStamp.read(url) == stamp
    else { throw ToolFailure.changed }
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw ToolFailure.invalid("没有可读取的视频轨道")
    }
    let size = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let formats = try await track.load(.formatDescriptions)
    let displayed = size.applying(transform)
    let seconds = CMTimeGetSeconds(duration)
    guard seconds.isFinite, seconds >= 0, displayed.width.isFinite, displayed.height.isFinite,
      abs(displayed.width) < 100000, abs(displayed.height) < 100000
    else { throw ToolFailure.invalid("视频参数无法读取") }
    let code = formats.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
    let bytes: [UInt8] = [
      UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255),
      UInt8(code & 255),
    ]
    let raw = String(bytes: bytes, encoding: .ascii) ?? "未知编码"
    let names = [
      "apch": "ProRes HQ", "apcn": "ProRes 422", "apcs": "ProRes LT", "apco": "ProRes Proxy",
      "avc1": "H.264", "hvc1": "HEVC", "hev1": "HEVC",
    ]
    guard FileStamp.read(url) == stamp else { throw ToolFailure.changed }
    return VideoFacts(
      duration: seconds, width: Int(abs(displayed.width)), height: Int(abs(displayed.height)),
      codec: names[raw] ?? raw)
  }
}
enum ResolveMediaKind: String, CaseIterable, Identifiable {
  case proxy = "代理文件"
  case cache = "CacheClip 缓存"
  case optimized = "优化媒体"
  var id: String { rawValue }
}
struct ResolveMediaFile: Identifiable {
  var id: String { item.id }
  let item: ScanItem
  let kind: ResolveMediaKind
  let group: URL
  var facts: VideoFacts?
  var possibleOriginals: [URL] = []
}
struct ResolveMediaGroup: Identifiable {
  var id: String { url.path }
  let url: URL
  let kind: ResolveMediaKind
  let files: [ResolveMediaFile]
  var bytes: Int64 { files.reduce(0) { $0 + $1.item.bytes } }
}
struct ResolveMediaReport {
  var files: [ResolveMediaFile] = []
  var issues: [String] = []
  var cancelled = false
  var limited = false
  var groups: [ResolveMediaGroup] {
    Dictionary(grouping: files, by: { $0.group.path }).values.map {
      ResolveMediaGroup(url: $0[0].group, kind: $0[0].kind, files: $0)
    }.sorted { $0.bytes > $1.bytes }
  }
}
struct MediaAssociation: Codable {
  let media: URL
  let original: URL
  let originalStamp: FileStamp
  let confirmedAt: Date
  var available: Bool { LocalFiles.noLinks(original) && FileStamp.read(original) == originalStamp }
}
enum ResolveMediaAudit {
  static func scan(
    roots: [URL], home: URL, cancellation: ScanCancellation,
    progress: @escaping (String) -> Void = { _ in }
  ) -> ResolveMediaReport {
    let scanned = DiskScanner(policy: SafetyPolicy(home: home), minimumBytes: 0).scan(
      roots: roots, cancellation: cancellation
    ) { progress("检查 \($0.visited) 项") }
    var result = ResolveMediaReport()
    result.issues = scanned.issues
    for item in scanned.items {
      let parts = item.url.pathComponents
      let kind: ResolveMediaKind =
        parts.contains("ProxyMedia")
        ? .proxy : parts.contains("OptimizedMedia") ? .optimized : .cache
      guard
        kind != .cache || item.url.pathExtension.lowercased() == "dvcc"
          || item.url.pathExtension.lowercased() == "dvca"
      else { continue }
      let base =
        roots.filter { SafetyPolicy.within(item.url, $0) }.max { $0.path.count < $1.path.count }
        ?? item.root
      let relative = String(item.url.path.dropFirst(base.path.count + 1)).split(separator: "/")
      let group = relative.count > 1 ? base.appendingPathComponent(String(relative[0])) : base
      var assessment = item.assessment
      if kind != .proxy {
        assessment = FileAssessment(
          category: .cache, disposition: .protected, owner: "DaVinci Resolve", group: kind.rawValue,
          reason: "清理后可能需要重新生成；请确认项目用途。", evidence: "按目录与文件格式识别，未判断项目已废弃。",
          ruleID: "resolve-cache-analysis",
          blockingAppIDs: ["com.blackmagic-design.DaVinciResolve"], needsClosedApps: true)
      }
      result.files.append(
        ResolveMediaFile(
          item: ScanItem(url: item.url, root: item.root, stamp: item.stamp, assessment: assessment),
          kind: kind, group: group))
    }
    result.cancelled = scanned.cancelled || cancellation.isCancelled
    result.limited = scanned.limited
    return result
  }
  static func possibleOriginals(for file: ResolveMediaFile, index: StorageIndex, limit: Int = 20)
    throws -> [URL]
  {
    let stem = file.item.url.deletingPathExtension().lastPathComponent.lowercased()
    let escaped = stem.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
      of: "%", with: "\\%"
    ).replacingOccurrences(of: "_", with: "\\_")
    return try index.rows(
      "SELECT path FROM nodes WHERE is_dir=0 AND lower(title) LIKE ? ESCAPE '\\' AND path NOT LIKE '%/ProxyMedia/%' AND path NOT LIKE '%/CacheClip/%' LIMIT ?",
      [escaped + ".%", String(limit)]
    ).compactMap { row in
      let url = URL(fileURLWithPath: row[0])
      return ["mov", "mp4", "mxf", "braw", "r3d"].contains(url.pathExtension.lowercased())
        && FileStamp.read(url)?.isDataless == false ? url : nil
    }
  }
}
