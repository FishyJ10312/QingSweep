import SwiftUI

struct StorageView: View {
    @EnvironmentObject var model: AppModel
    private let color = CleanupScope.optional.color
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("空间分析").font(.system(size: 24, weight: .semibold))
                    if let info = model.storageInfo {
                        Text(info.scannedAt.formatted(date: .abbreviated, time: .shortened) + (info.partial ? " · 部分结果" : ""))
                            .font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
                    }
                }
                Spacer()
                if model.analyzing { Button("停止分析", action: model.cancelStorageAnalysis).buttonStyle(SweepOutlineButton()) }
                else {
                    if !model.storagePendingRoots.isEmpty && model.storageHasPersonalCoverage {
                        Button("重新分析") { model.runStorageAnalysis() }.buttonStyle(SweepOutlineButton()).disabled(model.busy)
                        Button("继续分析") { model.continueStorageAnalysis() }.buttonStyle(SweepPrimaryButton(color: color)).disabled(model.busy).help("继续扫描 \(model.storagePendingRoots.count) 个尚未开始的位置，保留已有结果")
                    } else { Button(model.storageInfo == nil || !model.storageHasPersonalCoverage ? "分析全部位置" : "更新变化") { model.runStorageAnalysis() }.buttonStyle(SweepPrimaryButton(color: color)).disabled(model.busy) }
                }
                if model.storageInfo != nil { Menu { Button("完整重新分析") { model.runStorageAnalysis(full: true) } } label: { Image(systemName: "ellipsis") }.disabled(model.busy) }
            }
            HStack(alignment: .top, spacing: 16) {
                ScrollView { coverage }.frame(width: 200)
                VStack(spacing: 0) {
                    browserBar
                    Divider()
                    if model.storageInfo == nil {
                        VStack(spacing: 16) {
                            ContentUnavailableView(model.loadingStorageIndex ? "正在整理本机索引" : model.analyzing ? "正在分析空间" : model.storageIndexUnavailable ? "需要重新分析" : "尚未分析", systemImage: "chart.bar.xaxis")
                            if model.analyzing { Text("已检查 \(model.storageProgress.visited) 项").font(.system(size: 13)).foregroundStyle(SweepStyle.secondary) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.storageShowsMap && model.storageMode == .applications && model.storageSearch.isEmpty {SpaceMapView()} else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                if model.storageMode == .applications && model.storageSearch.isEmpty {
                                    ForEach(model.displayedAppSummaries) { AppStorageRow(app: $0) }
                                    if model.displayedAppSummaries.isEmpty { ContentUnavailableView("暂无已读取内容", systemImage: "tray") }
                                } else {
                                    ForEach(model.storageItems) { IndexedStorageRow(item: $0) }
                                    if model.queryingStorage { ProgressView().padding(20) }
                                    else if model.storageItems.isEmpty {
                                        ContentUnavailableView(model.storageSearch.isEmpty ? "暂无已读取内容" : "没有匹配项目", systemImage: "magnifyingglass")
                                        if let folder = model.storageFolder { Button("重新扫描此文件夹") { model.runStorageAnalysis(subtree: folder) }.disabled(model.busy) }
                                    }
                                    if model.storageHasMore { Button("加载更多 · \(model.storageItems.count) / \(model.storageTotalMatches)") { model.queryStoragePage(append: true) }.buttonStyle(SweepOutlineButton()).disabled(model.queryingStorage || model.analyzing).padding(8) }
                                }
                            }.padding(12)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Divider()
                    HStack {
                        Text(model.analyzing ? "已检查 \(model.storageProgress.visited) 项" : "只读分析").foregroundStyle(SweepStyle.secondary)
                        Spacer()
                        Button("选择文件夹", action: model.chooseStorageFolder).buttonStyle(.plain).disabled(model.busy)
                        if !model.storageAccessIssues.isEmpty { Button("访问助手 · \(model.storageAccessIssues.count)") { model.showingStorageIssues = true }.buttonStyle(SweepOutlineButton()) }
                    }.font(.system(size: 12)).padding(12)
                }.background(SweepStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SweepStyle.line))
            }
        }.padding(16).foregroundStyle(SweepStyle.ink).tint(color)
    }
    private var coverage: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModuleStat(title: "磁盘已用", value: formatBytes(max(0, model.snapshot.diskTotal - model.snapshot.diskFree)), color: SweepStyle.ink)
            ModuleStat(title: "本卷已统计", value: model.storageInfo == nil ? "待分析" : formatBytes(model.storageCountedBytes), color: color)
            ModuleStat(title: "系统与辅助卷", value: model.storageVolumes.isEmpty ? "正在核对" : formatBytes(model.storageSystemBytes), color: CleanupScope.protected.color)
                .help(model.storageVolumes.map { $0.title + " " + formatBytes($0.bytes) }.joined(separator: "、"))
            ModuleStat(title: "待核对差额", value: model.storageInfo == nil ? "待分析" : formatBytes(model.storageRemainingBytes), color: SweepStyle.secondary)
                .help("已扣除系统与辅助卷。剩余差额涉及下方未完成、权限受限位置与 APFS 分配口径；容量无法在授权前准确确定。")
            if !model.storagePendingRoots.isEmpty { Text(model.analyzing ? "正在自动续扫" : "还有位置可继续扫描").font(.system(size: 12, weight: .medium)).foregroundStyle(color) }
            if model.storagePermissionCount > 0 {
                Button("授权访问 · \(model.storagePermissionCount) 处") { model.showingStorageIssues = true }.buttonStyle(SweepPrimaryButton(color: color))
                Text("授权后自动检查并补扫").font(.system(size: 11)).foregroundStyle(SweepStyle.secondary)
            }
            Divider()
            Text("达芬奇文件").font(.system(size: 15, weight: .semibold))
            Button("检查代理文件") { model.inspectCleanupFolder(model.policy.home.appendingPathComponent("Movies/ProxyMedia")) }.buttonStyle(SweepOutlineButton()).disabled(model.busy)
            Button("检查渲染缓存") { model.inspectCleanupFolder(model.policy.home.appendingPathComponent("Movies/CacheClip")) }.buttonStyle(SweepOutlineButton()).disabled(model.busy)
            if model.storageInfo != nil && !model.storageHasPersonalCoverage {
                Label("当前范围不完整", systemImage: "info.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(CleanupScope.protected.color)
                    .help("旧版扫描未覆盖文稿、图片和影片等位置；请分析全部位置。")
            }
            if model.storageCountedBytes > max(0, model.snapshot.diskTotal - model.snapshot.diskFree) {
                Text("文件分配空间与磁盘用量口径不同").font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
            }
            if model.storageIndexUnavailable { Text("索引需要重建").font(.system(size: 12)).foregroundStyle(SweepStyle.warning) }
            if !model.storageUpdateStatus.isEmpty { Text(model.storageUpdateStatus).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary) }
            if model.analyzing {
                ProgressView().progressViewStyle(.linear)
                Text(model.storageProgress.current.isEmpty ? "正在合并统计" : model.storageProgress.current).font(.system(size: 11)).foregroundStyle(SweepStyle.secondary).lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
    private var browserBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button(action: model.returnStorage) { Image(systemName: "arrow.left") }.buttonStyle(SweepOutlineButton()).disabled(!model.canReturnStorage).keyboardShortcut("[", modifiers: .command).accessibilityLabel("返回")
                Button(action: model.storageUp) { Image(systemName: "arrow.up") }.buttonStyle(SweepOutlineButton()).disabled(model.storageFolder == nil).accessibilityLabel("上一级")
                Text(model.storageOwnerTitle ?? (model.storageMode == .applications ? "应用与个人文件" : "文件夹"))
                    .font(.system(size: 19, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if model.storageMode == .applications && model.storageSearch.isEmpty {Button(model.storageShowsMap ? "列表":"空间图"){model.storageShowsMap.toggle()}.buttonStyle(SweepOutlineButton())}
                Picker("浏览方式", selection: Binding(get: { model.storageMode }, set: model.changeStorageMode)) {
                    ForEach(StoragePresentation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 168)
            }
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(SweepStyle.secondary)
                    TextField("搜索名称、应用或路径", text: $model.storageSearch).textFieldStyle(.plain)
                    if !model.storageSearch.isEmpty { Button { model.storageSearch = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清除搜索") }
                }.font(.system(size: 13)).padding(8).background(SweepStyle.background, in: RoundedRectangle(cornerRadius: 6))
                if model.storageMode == .folders || !model.storageSearch.isEmpty {
                    Picker("排序", selection: $model.storageOrdering) { Text("占用最大").tag(FileOrdering.size); Text("名称").tag(FileOrdering.name) }.labelsHidden().frame(width: 104)
                }
            }
            if model.storageMode == .folders || !model.storageSearch.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("全部位置", action: model.browseAllStorage).buttonStyle(.plain)
                        if !model.storageSearch.isEmpty { Text("/ 搜索结果").foregroundStyle(SweepStyle.secondary) }
                        if let owner = model.storageOwnerTitle { Button("/ " + owner) { model.browseStorage(nil) }.buttonStyle(.plain) }
                        ForEach(model.storageSearch.isEmpty ? model.storageBreadcrumbs : [], id: \.path) { url in
                            Text("/").foregroundStyle(SweepStyle.secondary); Button(url.lastPathComponent) { model.browseStorage(url) }.buttonStyle(.plain)
                        }
                    }.font(.system(size: 12)).foregroundStyle(color)
                }
            }
        }.padding(12)
    }
}

struct AppStorageRow: View {
    @EnvironmentObject var model: AppModel
    let app: AppStorageSummary
    private var personal: Bool { app.id.hasPrefix("personal:") }
    private var color: Color { personal ? CleanupScope.protected.color : CleanupScope.optional.color }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: personal ? "folder" : app.id.hasPrefix("shared:") ? "square.stack.3d.up" : "app")
                    .font(.system(size: 20)).foregroundStyle(color).frame(width: 40, height: 40).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                Text(app.title).font(.system(size: 20, weight: .semibold)).lineLimit(2)
                if app.partial { Text("部分").font(.system(size: 11)).foregroundStyle(SweepStyle.secondary).help("部分位置尚未读取") }
                Spacer(minLength: 8)
                Text(app.hasReadData ? formatBytes(app.bytes) : "尚未读取").font(.system(size: 22, weight: .medium, design: .monospaced)).lineLimit(1)
            }
            HStack(spacing: 12) {
                if personal { Text("个人文件").font(.system(size: 12)).foregroundStyle(color) }
                else { component("程序", app.programBytes); component("数据", app.dataBytes); component("缓存", app.cacheBytes); component("日志", app.logBytes) }
                Spacer(minLength: 0)
                Button("查看文件") { model.browseStorage(nil, owner: app) }.buttonStyle(SweepOutlineButton())
                if !personal { Button(app.candidateBytes > 0 ? "清理项" : "检查清理项") { model.showAppCleanup(app) }.buttonStyle(SweepPrimaryButton(color: color)).disabled(model.busy) }
            }
        }.padding(14).background(SweepStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SweepStyle.line))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 32) }
    }
    private func component(_ name: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).foregroundStyle(SweepStyle.secondary)
            Text(app.partial && bytes == 0 ? "未读取" : formatBytes(bytes)).monospacedDigit()
        }.font(.system(size: 12)).frame(minWidth: 54, alignment: .leading)
    }
}

struct IndexedStorageRow: View {
    @EnvironmentObject var model: AppModel
    let item: IndexedStorageItem
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.isDirectory ? "folder" : "doc").font(.system(size: 20)).foregroundStyle(CleanupScope.optional.color)
                .frame(width: 36, height: 36).background(CleanupScope.optional.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            Button {
                if item.isDirectory { model.browseStorage(item.url) } else { model.storageItemDetail = item }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: item.isDirectory ? 19 : 15, weight: .semibold)).foregroundStyle(SweepStyle.ink).lineLimit(2)
                    Text(item.ownerTitle + (item.partial ? " · 部分" : "")).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
                    if !model.storageSearch.isEmpty { Text(item.url.deletingLastPathComponent().path).font(.system(size: 11)).foregroundStyle(SweepStyle.secondary).lineLimit(1).truncationMode(.middle) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(item.url.path)
            Text(item.state == 0 ? "尚未读取" : formatBytes(item.bytes)).font(.system(size: 17, weight: .medium, design: .monospaced)).frame(minWidth: 80, alignment: .trailing)
            Menu {
                if item.isDirectory { Button("检查此文件夹") { model.inspectCleanupFolder(item.url) }.disabled(model.busy || !model.policy.permits(item.url)) }
                else { Button("预览") { model.preview(item.url) } }
                Button("查看详情") { model.storageItemDetail = item }
                Button("在访达中查看") { model.reveal(item.url) }
                Button("复制完整路径") { model.copyPath(item.url) }
                if item.isDirectory { Button("重新扫描此文件夹") { model.runStorageAnalysis(subtree: item.url) }.disabled(model.busy) }
                if item.partial { Button("访问助手") { model.showingStorageIssues = true } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
        }.padding(12).sweepCard()
    }
}
struct IndexedStorageDetailView: View {
    @EnvironmentObject var model: AppModel
    let item: IndexedStorageItem
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(item.title).font(.system(size: 23, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text(item.state == 0 ? "尚未读取" : formatBytes(item.bytes)).font(.system(size: 28, weight: .medium, design: .monospaced)).foregroundStyle(SweepStyle.accent)
            Text(item.url.path).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            LabeledContent("归属", value: item.ownerTitle)
            LabeledContent("用途", value: item.component.title)
            LabeledContent("文件", value: "\(item.fileCount) 个")
            if item.partial { Text("当前容量仅包含已读取内容").foregroundStyle(SweepStyle.warning) }
            HStack { if !item.isDirectory { Button("预览") { model.preview(item.url) } }; Button("在访达中查看") { model.reveal(item.url) }; Button("复制完整路径") { model.copyPath(item.url) }; Spacer(); Button("完成") { model.storageItemDetail = nil }.keyboardShortcut(.defaultAction) }
        }.font(.system(size: 13)).padding(28).frame(width: 640)
    }
}
struct StorageIssuesView: View {
    @EnvironmentObject var model: AppModel
    private var groups: [(String, [StorageAccessIssue])] {
        Dictionary(grouping: model.storageAccessIssues) { issue in
            let root = model.storageInfo?.roots.first { $0.url.path == issue.root.path } ?? StorageRoot(url: issue.root, title: issue.root.lastPathComponent, kind: .appData)
            let owner = model.ownerResolver.resolve(issue.url, root: root)
            return (owner.id == "unassigned" ? root.title : owner.title) + " · " + issue.kind.title
        }.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("文件访问助手").font(.system(size: 24, weight: .medium)); Spacer(); if model.accessCheckRunning { ProgressView().controlSize(.small) } }
            VStack(alignment: .leading, spacing: 8) {
                if model.storagePermissionCount > 0 {
                    Text("系统设置 → 隐私与安全 → 完全磁盘访问").font(.system(size: 15, weight: .semibold))
                    Text("开启轻扫后点重新检查；系统要求重开时，重开后会自动补扫。").font(.system(size: 13)).foregroundStyle(SweepStyle.secondary)
                } else if model.storageAccessIssues.contains(where: { $0.kind == .restricted }) {
                    Text("完全磁盘访问已通过试读").font(.system(size: 15, weight: .semibold))
                    Text("系统限制的位置会保留明细，无需重复授权。").font(.system(size: 13)).foregroundStyle(SweepStyle.secondary)
                } else { Text("查看无法读取的位置").font(.system(size: 15, weight: .semibold)) }
                if !model.storageAccessStatus.isEmpty { Text(model.storageAccessStatus).font(.system(size: 13, weight: .medium)).foregroundStyle(CleanupScope.optional.color) }
                Text("系统与辅助卷：" + (model.storageVolumes.map { $0.title + " " + formatBytes($0.bytes) }.joined(separator: " · "))).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
            }
            HStack {
                Button("选择文件夹") { model.showingStorageIssues = false; model.chooseStorageFolder() }.disabled(model.busy)
                if model.storagePermissionCount > 0 { Button("前往系统设置", action: model.openFileAccessSettings).buttonStyle(SweepPrimaryButton(color: CleanupScope.optional.color)) }
                Button("复制应用路径") { model.copyPath(Bundle.main.bundleURL) }
                Button("重新检查", action: model.recheckStorageAccess).disabled(model.accessCheckRunning || model.analyzing)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if groups.isEmpty { Text("没有待处理的访问问题").foregroundStyle(SweepStyle.secondary).padding(20) }
                    ForEach(groups, id: \.0) { title, issues in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button { if model.expandedAccessGroups.contains(title) { model.expandedAccessGroups.remove(title) } else { model.expandedAccessGroups.insert(title) } } label: { Label(title, systemImage: model.expandedAccessGroups.contains(title) ? "chevron.down" : "chevron.right") }.buttonStyle(.plain)
                                Spacer(); Text("\(issues.count) 处").foregroundStyle(SweepStyle.secondary)
                            }
                            if model.expandedAccessGroups.contains(title) {
                                ForEach(issues) { issue in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(issue.url.path).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                        Text(issue.detail).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary).fixedSize(horizontal: false, vertical: true)
                                        HStack { Button("在访达中查看") { model.reveal(issue.url) }; Button("重新扫描") { model.showingStorageIssues = false; model.runStorageAnalysis(subtree: StorageAccessProbe.rescanFolder(for: issue)) }.disabled(model.busy) }
                                    }.padding(.leading, 20)
                                }
                            }
                        }.font(.system(size: 13)).padding(16).sweepCard()
                    }
                }
            }.frame(height: 240)
            HStack { Spacer(); Button("完成") { model.showingStorageIssues = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 740).background(SweepStyle.background)
    }
}
struct ScanChooserView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("选择扫描范围").font(.system(size: 24, weight: .medium))
            Text("旧扫描记录没有保存范围，请重新选择一次").font(.system(size: 13)).foregroundStyle(SweepStyle.secondary)
            Button("常用位置") { model.showingScanChooser = false; model.quickScan(); model.section = .results }
            Button("个人大文件") { model.showingScanChooser = false; model.personalScan(); model.section = .results }
            Button("指定文件夹") { model.showingScanChooser = false; model.chooseFolder() }
            HStack { Spacer(); Button("取消") { model.showingScanChooser = false }.keyboardShortcut(.cancelAction) }
        }.padding(28).frame(width: 460)
    }
}
