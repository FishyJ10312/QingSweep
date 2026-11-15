import SwiftUI

func decisionColor(_ value: CleanupDisposition) -> Color {
    switch value { case .priority: return SweepStyle.accent; case .conditional: return SweepStyle.warning; case .manual: return .secondary; case .protected: return .secondary; case .unknown: return .secondary }
}
struct ResultsView: View {
    @EnvironmentObject var model: AppModel
    private var hasFilters: Bool { model.category != nil || model.groupFilter != nil || !model.search.isEmpty || model.minimumFilter > 0 || model.onlySelected }
    private var scope: CleanupScope { model.cleanupScope ?? .recommended }
    var body: some View {
        VStack(spacing: 12) {
            header
            if model.scanLabel == "ProxyMedia" { Text("代理文件：确认原始素材仍可用后再删除；需要时可重新生成代理。").font(.system(size: 12)).foregroundStyle(CleanupScope.protected.color).frame(maxWidth: .infinity, alignment: .leading) }
            if model.scanLabel == "CacheClip" { Text("渲染缓存：删除后需要重新计算，首次播放可能变慢；请先确认原始素材可用。").font(.system(size: 12)).foregroundStyle(CleanupScope.protected.color).frame(maxWidth: .infinity, alignment: .leading) }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(CleanupScope.allCases) { value in
                        let values = model.scopeItems(value)
                        ScopeSidebarCard(scope: value,
                            capacity: model.loadingReport ? "读取中" : model.scannedAt == nil ? "待扫描" : formatBytes(values.reduce(0) { $0 + $1.bytes }),
                            count: model.scannedAt == nil ? nil : values.count, selected: model.cleanupScope == value) {
                            model.selectCleanupScope(value)
                        }.disabled(model.scanning || model.loadingReport)
                    }
                    Spacer(minLength: 0)
                }.frame(width: 200)
            VStack(spacing: 0) {
                if model.scanning || model.loadingReport {
                    VStack(spacing: 20) {
                        ProgressView().controlSize(.large)
                        Text(model.loadingReport ? "正在读取上次结果" : "正在检查文件").font(.system(size: 20, weight: .medium))
                        Text("已检查 \(model.progress.visited) 项").font(.system(size: 13)).foregroundStyle(SweepStyle.secondary)
                        if model.scanning { Button("停止扫描", action: model.cancelScan).buttonStyle(SweepOutlineButton()) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.items.isEmpty && model.scannedAt == nil {
                    VStack(spacing: 20) {
                        ContentUnavailableView("从常用位置开始", systemImage: "tray")
                        Button("扫描常用位置", action: model.quickScan).buttonStyle(SweepPrimaryButton()).disabled(model.busy)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    browserBar
                    Divider()
                    listHeading
                    ScrollView {
                        LazyVStack(spacing: model.presentation == .groups ? 8 : 0) {
                            if model.presentation == .groups {
                                ForEach(model.displayedCleanupGroups) { ClassificationGroupView(group: $0) }
                            } else {
                                ForEach(model.displayedCleanupFiles) { FileRow(item: $0); Divider() }
                            }
                            if model.filtered.isEmpty { emptyResult }
                            if model.cleanupHasMore { Button("加载更多 · 每次 100 项", action: model.loadMoreCleanup).buttonStyle(SweepOutlineButton()).padding(8) }
                        }.padding(12)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                footer
            }
            .background(SweepStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SweepStyle.line))
            }
        }.padding(16).foregroundStyle(SweepStyle.ink).tint(scope.color)
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("清理").font(.system(size: 24, weight: .semibold))
                HStack(spacing: 8) {
                    Text(model.cleanupOwnerTitle ?? "全部应用")
                    Text("/")
                    Text(model.scanLabel)
                    if model.cleanupIsPartial { Text("· 部分结果").foregroundStyle(SweepStyle.warning) }
                }.font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let date = model.scannedAt { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)) }
                Button("扫描详情") { model.showingIssues = true }.buttonStyle(.plain).font(.system(size: 12)).disabled(model.result == nil)
            }.foregroundStyle(SweepStyle.secondary)
            Menu {
                Button("重新扫描当前范围", action: model.rescan)
                Divider()
                Button("扫描常用位置", action: model.quickScan)
                Button("查找大文件", action: model.personalScan)
                Button("扫描文件夹", action: model.chooseFolder)
            } label: { Label("扫描", systemImage: "arrow.clockwise") }.disabled(model.busy)
        }
    }
    private var browserBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(action: model.returnCleanup) { Image(systemName: "arrow.left").frame(width: 16) }
                    .buttonStyle(SweepOutlineButton()).disabled(!model.canReturnCleanup).keyboardShortcut("[", modifiers: .command).accessibilityLabel("返回上一级")
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if model.cleanupOwnerFilter != nil { Button("全部应用", action: model.clearCleanupOwner).buttonStyle(.plain); Text("/").foregroundStyle(SweepStyle.secondary) }
                        Button(model.cleanupOwnerTitle ?? scope.rawValue) { model.selectCleanupScope(scope) }.buttonStyle(.plain).foregroundStyle(scope.color)
                        if let group = model.cleanupGroupTitle { Text("/").foregroundStyle(SweepStyle.secondary); Text(group).lineLimit(1).help(group) }
                    }.font(.system(size: 15, weight: .semibold))
                    
                }
                Spacer(minLength: 0)
                Picker("显示方式", selection: $model.presentation) {
                    ForEach(ResultPresentation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 168)
            }
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(SweepStyle.secondary)
                    TextField("搜索此范围", text: $model.search).textFieldStyle(.plain)
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }.font(.system(size: 13)).padding(8).background(SweepStyle.background, in: RoundedRectangle(cornerRadius: 6))
                Menu {
                    Picker("用途", selection: $model.category) {
                        Text("全部用途").tag(Optional<FileCategory>.none)
                        ForEach(FileCategory.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    Picker("大小", selection: $model.minimumFilter) { Text("全部大小").tag(Int64(0)); Text("至少 100 MB").tag(Int64(100_000_000)); Text("至少 1 GB").tag(Int64(1_000_000_000)) }
                    Toggle("只看已选文件", isOn: $model.onlySelected)
                } label: { Label("筛选", systemImage: "line.3.horizontal.decrease") }.fixedSize()
                Picker("排序", selection: $model.ordering) { ForEach(FileOrdering.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 112)
            }
        }.padding(12)
    }
    private var listHeading: some View {
        HStack(spacing: 10) {
            Text("\(model.filtered.count) 项").font(.system(size: 13, weight: .medium)).foregroundStyle(SweepStyle.secondary)
            if let config = model.currentScanConfiguration { Text("· " + formatBytes(config.minimumBytes) + " 以上").font(.system(size: 12)).foregroundStyle(SweepStyle.secondary) }
            Spacer(minLength: 4)
            if hasFilters { Button("清除筛选", action: model.clearCleanupFilters).buttonStyle(.plain).font(.system(size: 12)) }
            if model.cleanupScope == .recommended {
                Button { model.selectPriority() } label: {
                    Label(model.unselectedRecommendations.isEmpty && !model.currentSelection.isEmpty ? "已选全部推荐" : "全选推荐项", systemImage: "checklist")
                }.buttonStyle(SweepPrimaryButton(color: scope.color)).disabled(model.busy || model.unselectedRecommendations.isEmpty)
            } else {
                Button(action: model.toggleVisible) {
                    Label(model.allVisibleSelected ? "取消全选" : "全选当前范围", systemImage: model.allVisibleSelected ? "minus.square" : "checkmark.square")
                }.buttonStyle(SweepPrimaryButton(color: scope.color)).disabled(model.busy || model.visibleSelectableItems.isEmpty)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).background(scope.color.opacity(0.025))
    }
    private var emptyResult: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(model.cleanupScope == .recommended && !hasFilters ? "此范围没有推荐项" : "没有匹配的文件", systemImage: "tray")
            if hasFilters { Button("清除筛选", action: model.clearCleanupFilters).buttonStyle(SweepOutlineButton()) }
            if model.cleanupScope == .recommended && !model.scopeItems(.optional).isEmpty { Button("查看可自行选择") { model.selectCleanupScope(.optional) }.buttonStyle(SweepOutlineButton()) }
            Button("扫描常用位置", action: model.quickScan).buttonStyle(.plain).disabled(model.busy)
        }.frame(maxWidth: .infinity).padding(.vertical, 40)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.currentSelection.isEmpty ? "未选择" : formatBytes(model.currentSelectionBytes)).font(.system(size: 18, weight: .semibold, design: .monospaced))
                    if !model.currentSelection.isEmpty { Text("/ \(model.currentSelection.count) 项").font(.system(size: 12)).foregroundStyle(SweepStyle.secondary) }
                }
                if model.otherSelectionCount > 0 {
                    Button("其他范围 \(model.otherSelectionCount) 项") { model.prepareReview() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(scope.color)
                } else if model.cleanupScope == .protected {
                    Text("素材默认不选 · 清理前二次确认").font(.system(size: 11)).foregroundStyle(SweepStyle.secondary)
                }
            }
            Spacer(minLength: 0)
            if !model.currentSelection.isEmpty { Button("清空", action: model.clearCurrentSelection).buttonStyle(.plain).font(.system(size: 12)) }
            Button("复核所选", action: model.prepareCurrentReview).buttonStyle(SweepPrimaryButton(color: scope.color)).disabled(model.currentSelection.isEmpty || model.busy)
        }.padding(12).background(scope.color.opacity(0.025))
    }

}
struct AppCleanupSectionView: View {
    @EnvironmentObject var model: AppModel
    let category: FileCategory
    private var title: String { category == .log ? "日志" : category.title }
    private var impact: String {
        switch category {
        case .cache: return "使用时会重新生成或下载，首次打开可能更慢"
        case .log: return "移除历史诊断记录，可能影响旧问题的排查"
        default: return "保留已安装程序；这份离线安装介质将移到废纸篓"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).font(.system(size: 17, weight: .medium)); Spacer(); Text(formatBytes(model.filtered.filter { $0.category == category }.reduce(0) { $0 + $1.bytes })).foregroundStyle(SweepStyle.secondary) }
            Text(impact).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
            if model.presentation == .groups { ForEach(model.groups.filter { $0.assessment.category == category }) { ClassificationGroupView(group: $0) } }
            else { ForEach(model.filtered.filter { $0.category == category }) { FileRow(item: $0); Divider() } }
        }.padding(.bottom, 16)
    }
}
struct ClassificationGroupView: View {
    @EnvironmentObject var model: AppModel
    let group: AssessmentGroup
    private var assessment: FileAssessment { group.assessment }
    private var scope: CleanupScope { .forAssessment(assessment) }
    private var selectedCount: Int { group.items.filter { model.selected.contains($0.id) }.count }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Toggle("选择 " + assessment.group, isOn: Binding(get: { selectedCount == group.items.count }, set: { _ in model.toggleGroup(group) }))
                .labelsHidden().toggleStyle(.checkbox).tint(scope.color).disabled(model.busy)
            Image(systemName: assessment.category.symbol).font(.system(size: 19)).foregroundStyle(scope.color)
                .frame(width: 44, height: 44).background(scope.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            Button { model.showGroup(group) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(assessment.displayGroup).font(.system(size: 19, weight: .semibold)).foregroundStyle(SweepStyle.ink)
                        Text("\(group.items.count) 项").font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
                        if selectedCount > 0 { Text("已选 \(selectedCount)").font(.system(size: 12, weight: .medium)).foregroundStyle(scope.color) }
                    }
                    Text(assessment.reason).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary).lineLimit(1).help(assessment.reason)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text(formatBytes(group.bytes)).font(.system(size: 18, weight: .medium, design: .monospaced)).monospacedDigit().frame(minWidth: 90, alignment: .trailing)
            Button { model.inspecting = group.items.first } label: { Image(systemName: "info.circle").frame(width: 28, height: 32) }
                .buttonStyle(.plain).foregroundStyle(SweepStyle.secondary).help("查看分类依据")
            Button { model.showGroup(group) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 32) }
                .buttonStyle(.plain).foregroundStyle(scope.color).help("查看文件")
        }.padding(12)
            .background(selectedCount > 0 ? scope.color.opacity(0.04) : SweepStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selectedCount > 0 ? scope.color.opacity(0.45) : SweepStyle.line))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(scope.color).frame(width: 3, height: 32) }
    }
}
struct FileRow: View {
    @EnvironmentObject var model: AppModel
    let item: ScanItem
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Toggle("选择 " + item.url.lastPathComponent, isOn: Binding(get: { model.selected.contains(item.id) }, set: { model.toggle(item, on: $0) })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.url.lastPathComponent).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text(item.assessment.owner).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                Text(formatBytes(item.bytes)).font(.system(size: 14, weight: .medium)).monospacedDigit()
                Text(item.modified, format: .dateTime.year().month().day()).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
            }.frame(width: 100, alignment: .trailing)
            Button { model.preview(item.url) } label: { Image(systemName: "eye").frame(width: 24, height: 28) }.buttonStyle(.plain).accessibilityLabel("预览 " + item.url.lastPathComponent)
            Menu {
                Button("预览") { model.preview(item.url) }
                Button("查看详情") { model.inspecting = item }
                Button("在访达中查看") { model.reveal(item.url) }
                Button("复制完整路径") { model.copyPath(item.url) }
                Divider()
                Button("忽略此文件") { model.ignore(item.url) }.disabled(model.busy)
                Button("忽略所在文件夹") { model.ignore(item.url.deletingLastPathComponent()) }.disabled(model.busy)
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 26)
        }.padding(.horizontal, 12).padding(.vertical, 16)
            .background(model.selected.contains(item.id) ? CleanupScope.forAssessment(item.assessment).color.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle()).onTapGesture(count: 2) { model.inspecting = item }
    }
}
struct EvidenceView: View {
    @EnvironmentObject var model: AppModel
    let item: ScanItem
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Image(systemName: item.category.symbol).font(.system(size: 24)).foregroundStyle(SweepStyle.accent); Text("文件详情").font(.system(size: 24, weight: .medium)); Spacer(); Text(formatBytes(item.bytes)).font(.system(size: 22, weight: .medium, design: .monospaced)) }
            Text(item.url.lastPathComponent).font(.system(size: 16, weight: .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(item.url.path).font(.system(size: 13)).foregroundStyle(SweepStyle.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Divider()
            LabeledContent("所属应用", value: item.assessment.owner)
            LabeledContent("用途", value: item.category.title)
            LabeledContent("建议", value: item.assessment.disposition.title)
            LabeledContent("修改日期", value: item.modified.formatted(date: .complete, time: .shortened))
            Text(item.assessment.reason).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("判断依据") {
                Text(item.assessment.evidence).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                if let source = item.assessment.sourceURL, let url = URL(string: source) { Link("官方说明", destination: url).font(.system(size: 12)) }
            }
            HStack(spacing: 12) {
                Button("预览") { model.preview(item.url) }
                Button("在访达中查看") { model.reveal(item.url) }
                Button("复制完整路径") { model.copyPath(item.url) }
                Button("忽略此文件") { model.ignore(item.url) }.disabled(model.busy)
                Spacer()
                Button("完成") { model.inspecting = nil }.keyboardShortcut(.defaultAction)
            }
        }.font(.system(size: 13)).padding(28).frame(width: 660)
    }
}
