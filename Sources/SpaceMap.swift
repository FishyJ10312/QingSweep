import SwiftUI

struct SpaceBlock: Identifiable {
  let id: String
  let title: String
  let bytes: Int64
  let app: AppStorageSummary?
}
struct SpaceTile: Identifiable {
  var id: String { block.id }
  let block: SpaceBlock
  let rect: CGRect
}
enum SpaceMapLayout {
  static func blocks(_ apps: [AppStorageSummary], limit: Int = 35) -> [SpaceBlock] {
    let sorted = apps.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    var blocks = sorted.prefix(limit).map {
      SpaceBlock(id: $0.id, title: $0.title, bytes: $0.bytes, app: $0)
    }
    if sorted.count > limit {
      blocks.append(
        SpaceBlock(
          id: "map-other", title: "其他 · \(sorted.count-limit) 类",
          bytes: sorted.dropFirst(limit).reduce(0) { $0 + $1.bytes }, app: nil))
    }
    return blocks
  }
  static func tiles(_ blocks: [SpaceBlock], in rect: CGRect) -> [SpaceTile] {
    let values = blocks.filter { $0.bytes > 0 }
    guard !values.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
    if values.count == 1 { return [SpaceTile(block: values[0], rect: rect)] }
    let total = values.reduce(0.0) { $0 + Double($1.bytes) }
    var left = 0.0
    var split = 1
    for index in 0..<values.count - 1 {
      left += Double(values[index].bytes)
      split = index + 1
      if left >= total / 2 { break }
    }
    let ratio = CGFloat(left / total)
    let a: CGRect
    let b: CGRect
    if rect.width >= rect.height {
      a = CGRect(x: rect.minX, y: rect.minY, width: rect.width * ratio, height: rect.height)
      b = CGRect(x: a.maxX, y: rect.minY, width: rect.width - a.width, height: rect.height)
    } else {
      a = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * ratio)
      b = CGRect(x: rect.minX, y: a.maxY, width: rect.width, height: rect.height - a.height)
    }
    return tiles(Array(values.prefix(split)), in: a) + tiles(Array(values.dropFirst(split)), in: b)
  }
}
struct SpaceMapView: View {
  @EnvironmentObject var model: AppModel
  private var blocks: [SpaceBlock] { SpaceMapLayout.blocks(model.displayedAppSummaries) }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("已读取内容的分配空间 · 方块大小不代表可清理程度").font(.system(size: 12)).foregroundStyle(
        SweepStyle.secondary)
      GeometryReader { geometry in
        ZStack(alignment: .topLeading) {
          ForEach(SpaceMapLayout.tiles(blocks, in: CGRect(origin: .zero, size: geometry.size))) {
            tile in
            Button {
              if let app = tile.block.app {
                model.showStorageOwner(app.id, title: app.title)
              } else {
                model.storageShowsMap = false
              }
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                if tile.rect.width > 60 && tile.rect.height > 35 {
                  Text(tile.block.title).font(
                    .system(size: tile.rect.width > 160 ? 16 : 12, weight: .semibold)
                  ).lineLimit(2)
                  if tile.rect.height > 60 {
                    Text(formatBytes(tile.block.bytes)).font(.system(size: 12, design: .monospaced))
                  }
                }
              }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(
                tile.rect.width > 50 ? 10 : 0
              ).background(color(tile.block).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                  RoundedRectangle(cornerRadius: 6).stroke(
                    color(tile.block).opacity(0.4), lineWidth: 1)
                ).contentShape(Rectangle())
            }.buttonStyle(.plain).frame(
              width: max(0, tile.rect.width - 3), height: max(0, tile.rect.height - 3)
            ).offset(x: tile.rect.minX, y: tile.rect.minY).help(
              tile.block.title + " · " + formatBytes(tile.block.bytes)
            ).accessibilityLabel(tile.block.title + "，" + formatBytes(tile.block.bytes))
          }
        }
      }
    }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private func color(_ block: SpaceBlock) -> Color {
    block.app?.applicationURL != nil ? CleanupScope.optional.color : CleanupScope.protected.color
  }
}
struct MemoryTrendView: View {
  @ObservedObject var tools: WorkbenchModel
  let total: Int64
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("最近 30 分钟").font(.system(size: 17, weight: .semibold))
        Spacer()
        Toggle("菜单栏监控", isOn: $tools.menuEnabled).toggleStyle(.switch).controlSize(.small)
      }
      GeometryReader { geometry in
        Path { path in
          let samples = tools.memoryTrend.samples
          for (index, sample) in samples.enumerated() {
            let x = geometry.size.width * CGFloat(index) / CGFloat(max(1, samples.count - 1))
            let y = geometry.size.height * (1 - CGFloat(sample.used) / CGFloat(max(1, total)))
            if index == 0 {
              path.move(to: CGPoint(x: x, y: y))
            } else {
              path.addLine(to: CGPoint(x: x, y: y))
            }
          }
        }.stroke(CleanupScope.optional.color, lineWidth: 2)
      }.frame(height: 90)
      Text(tools.memoryTrend.samples.count < 2 ? "采样积累中，每 15 秒更新" : "内存使用量 · 应用变化与约 5 分钟前比较").font(
        .system(size: 12)
      ).foregroundStyle(SweepStyle.secondary)
    }.padding(16).sweepCard()
  }
}
