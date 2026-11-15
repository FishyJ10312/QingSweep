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
            if model.scanLabel == "ProxyMedia" { Text(L("代理文件：确认原始素材仍可用后再删除；需要时可重新生成代理。")).font(.system(size: 12)).foregroundStyle(CleanupScope.protected.color).frame(maxWidth: .infinity, alignment: .leading) }
            if model.scanLabel == "CacheClip" { Text(L("渲染缓存：删除后需要重新计算，首次播放可能变慢；请先确认原始素材可用。")).font(.system(size: 12)).foregroundStyle(CleanupScope.protected.color).frame(maxWidth: .infinity, alignment: .leading) }
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
                        Text(L(model.loadingReport ? "正在读取上次结果" : "正在检查文件")).font(.system(size: 20, weight: .medium))
                        Text(L("已检查 \(model.progress.visited) 项")).font(.system(size: 13)).foregroundStyle(SweepStyle.secondary)
                        if model.scanning { Button(L("停止扫描"), action: model.cancelScan).buttonStyle(SweepOutlineButton()) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.items.isEmpty && model.scannedAt == nil {
                    VStack(spacing: 20) {
                        ContentUnavailableView(L("从常用位置开始"), systemImage: "tray")
                        Button(L("扫描常用位置"), action: model.quickScan).buttonStyle(SweepPrimaryButton()).disabled(model.busy)
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
                            if model.cleanupHasMore { Button(L("加载更多 · 每次 100 项"), action: model.loadMoreCleanup).buttonStyle(SweepOutlineButton()).padding(8) }
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
                Text(L("清理")).font(.system(size: 24, weight: .semibold))
                HStack(spacing: 8) {
                    Text(L(model.cleanupOwnerTitle ?? "全部应用"))
                    Text(L("/"))
                    Text(L(model.scanLabel))
                    if model.cleanupIsPartial { Text(L("· 部分结果")).foregroundStyle(SweepStyle.warning) }
                }.font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let date = model.scannedAt { Text(L(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(InterfaceLanguage.current.locale)))).font(.system(size: 12)) }
                Button(L("扫描详情")) { model.showingIssues = true }.buttonStyle(.plain).font(.system(size: 12)).disabled(model.result == nil)
            }.foregroundStyle(SweepStyle.secondary)
            Menu {
                Button(L("重新扫描当前范围"), action: model.rescan)
                Divider()
                Button(L("扫描常用位置"), action: model.quickScan)
                Button(L("查找大文件"), action: model.personalScan)
                Button(L("扫描文件夹"), action: model.chooseFolder)
            } label: { Label(L("扫描"), systemImage: "arrow.clockwise") }.disabled(model.busy)
        }
    }
    private var browserBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(action: model.returnCleanup) { Image(systemName: "arrow.left").frame(width: 16) }
                    .buttonStyle(SweepOutlineButton()).disabled(!model.canReturnCleanup).keyboardShortcut("[", modifiers: .command).accessibilityLabel(L("返回上一级"))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if model.cleanupOwnerFilter != nil { Button(L("全部应用"), action: model.clearCleanupOwner).buttonStyle(.plain); Text(L("/")).foregroundStyle(SweepStyle.secondary) }
                        Button(L(model.cleanupOwnerTitle ?? scope.rawValue)) { model.selectCleanupScope(scope) }.buttonStyle(.plain).foregroundStyle(scope.color)
                        if let group = model.cleanupGroupTitle { Text(L("/")).foregroundStyle(SweepStyle.secondary); Text(L(group)).lineLimit(1).help(L(group)) }
                    }.font(.system(size: 15, weight: .semibold))
                    
                }
                Spacer(minLength: 0)
                Picker(L("显示方式"), selection: $model.presentation) {
                    ForEach(ResultPresentation.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 168)
            }
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(SweepStyle.secondary)
                    TextField(L("搜索此范围"), text: $model.search).textFieldStyle(.plain)
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel(L("清除搜索"))
                    }
                }.font(.system(size: 13)).padding(8).background(SweepStyle.background, in: RoundedRectangle(cornerRadius: 6))
                Menu {
                    Picker(L("用途"), selection: $model.category) {
                        Text(L("全部用途")).tag(Optional<FileCategory>.none)
                        ForEach(FileCategory.allCases) { Text(L($0.title)).tag(Optional($0)) }
                    }
                    Picker(L("大小"), selection: $model.minimumFilter) { Text(L("全部大小")).tag(Int64(0)); Text(L("至少 100 MB")).tag(Int64(100_000_000)); Text(L("至少 1 GB")).tag(Int64(1_000_000_000)) }
                    Toggle(L("只看已选文件"), isOn: $model.onlySelected)
                } label: { Label(L("筛选"), systemImage: "line.3.horizontal.decrease") }.fixedSize()
                Picker(L("排序"), selection: $model.ordering) { ForEach(FileOrdering.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) } }.labelsHidden().frame(width: 112)
            }
        }.padding(12)
    }
    private var listHeading: some View {
        HStack(spacing: 10) {
            Text(L("\(model.filtered.count) 项")).font(.system(size: 13, weight: .medium)).foregroundStyle(SweepStyle.secondary)
            if let config = model.currentScanConfiguration { Text(L("· " + formatBytes(config.minimumBytes) + " 以上")).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary) }
            Spacer(minLength: 4)
            if hasFilters { Button(L("清除筛选"), action: model.clearCleanupFilters).buttonStyle(.plain).font(.system(size: 12)) }
            if model.cleanupScope == .recommended {
                Button { model.selectPriority() } label: {
                    Label(L(model.unselectedRecommendations.isEmpty && !model.currentSelection.isEmpty ? "已选全部推荐" : "全选推荐项"), systemImage: "checklist")
                }.buttonStyle(SweepPrimaryButton(color: scope.color)).disabled(model.busy || model.unselectedRecommendations.isEmpty)
            } else {
                Button(action: model.toggleVisible) {
                    Label(L(model.allVisibleSelected ? "取消全选" : "全选当前范围"), systemImage: model.allVisibleSelected ? "minus.square" : "checkmark.square")
                }.buttonStyle(SweepPrimaryButton(color: scope.color)).disabled(model.busy || model.visibleSelectableItems.isEmpty)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).background(scope.color.opacity(0.025))
    }
    private var emptyResult: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(L(model.cleanupScope == .recommended && !hasFilters ? "此范围没有推荐项" : "没有匹配的文件"), systemImage: "tray")
            if hasFilters { Button(L("清除筛选"), action: model.clearCleanupFilters).buttonStyle(SweepOutlineButton()) }
            if model.cleanupScope == .recommended && !model.scopeItems(.optional).isEmpty { Button(L("查看可自行选择")) { model.selectCleanupScope(.optional) }.buttonStyle(SweepOutlineButton()) }
            Button(L("扫描常用位置"), action: model.quickScan).buttonStyle(.plain).disabled(model.busy)
        }.frame(maxWidth: .infinity).padding(.vertical, 40)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L(model.currentSelection.isEmpty ? "未选择" : formatBytes(model.currentSelectionBytes))).font(.system(size: 18, weight: .semibold, design: .monospaced))
                    if !model.currentSelection.isEmpty { Text(L("/ \(model.currentSelection.count) 项")).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary) }
                }
                if model.otherSelectionCount > 0 {
                    Button(L("其他范围 \(model.otherSelectionCount) 项")) { model.prepareReview() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(scope.color)
                } else if model.cleanupScope == .protected {
                    Text(L("素材默认不选 · 清理前二次确认")).font(.system(size: 11)).foregroundStyle(SweepStyle.secondary)
                }
            }
            Spacer(minLength: 0)
            if !model.currentSelection.isEmpty { Button(L("清空"), action: model.clearCurrentSelection).buttonStyle(.plain).font(.system(size: 12)) }
            Button(L("复核所选"), action: model.prepareCurrentReview).buttonStyle(SweepPrimaryButton(color: scope.color)).disabled(model.currentSelection.isEmpty || model.busy)
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
            HStack { Text(L(title)).font(.system(size: 17, weight: .medium)); Spacer(); Text(L(formatBytes(model.filtered.filter { $0.category == category }.reduce(0) { $0 + $1.bytes }))).foregroundStyle(SweepStyle.secondary) }
            Text(L(impact)).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
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
            Toggle(L("选择 " + assessment.group), isOn: Binding(get: { selectedCount == group.items.count }, set: { _ in model.toggleGroup(group) }))
                .labelsHidden().toggleStyle(.checkbox).tint(scope.color).disabled(model.busy)
            Image(systemName: assessment.category.symbol).font(.system(size: 19)).foregroundStyle(scope.color)
                .frame(width: 44, height: 44).background(scope.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            Button { model.showGroup(group) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(L(assessment.displayGroup)).font(.system(size: 19, weight: .semibold)).foregroundStyle(SweepStyle.ink)
                        Text(L("\(group.items.count) 项")).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
                        if selectedCount > 0 { Text(L("已选 \(selectedCount)")).font(.system(size: 12, weight: .medium)).foregroundStyle(scope.color) }
                    }
                    Text(L(assessment.reason)).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary).lineLimit(1).help(L(assessment.reason))
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text(L(formatBytes(group.bytes))).font(.system(size: 18, weight: .medium, design: .monospaced)).monospacedDigit().frame(minWidth: 90, alignment: .trailing)
            Button { model.inspecting = group.items.first } label: { Image(systemName: "info.circle").frame(width: 28, height: 32) }
                .buttonStyle(.plain).foregroundStyle(SweepStyle.secondary).help(L("查看分类依据"))
            Button { model.showGroup(group) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 32) }
                .buttonStyle(.plain).foregroundStyle(scope.color).help(L("查看文件"))
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
            Toggle(L("选择 ") + item.url.lastPathComponent, isOn: Binding(get: { model.selected.contains(item.id) }, set: { model.toggle(item, on: $0) })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.url.lastPathComponent).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text(L(item.assessment.owner)).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                Text(L(formatBytes(item.bytes))).font(.system(size: 14, weight: .medium)).monospacedDigit()
                Text(item.modified, format: .dateTime.year().month().day().locale(InterfaceLanguage.current.locale)).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
            }.frame(width: 100, alignment: .trailing)
            Button { model.preview(item.url) } label: { Image(systemName: "eye").frame(width: 24, height: 28) }.buttonStyle(.plain).accessibilityLabel(L("预览 ") + item.url.lastPathComponent)
            Menu {
                Button(L("预览")) { model.preview(item.url) }
                Button(L("查看详情")) { model.inspecting = item }
                Button(L("在访达中查看")) { model.reveal(item.url) }
                Button(L("复制完整路径")) { model.copyPath(item.url) }
                Divider()
                Button(L("忽略此文件")) { model.ignore(item.url) }.disabled(model.busy)
                Button(L("忽略所在文件夹")) { model.ignore(item.url.deletingLastPathComponent()) }.disabled(model.busy)
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
            HStack { Image(systemName: item.category.symbol).font(.system(size: 24)).foregroundStyle(SweepStyle.accent); Text(L("文件详情")).font(.system(size: 24, weight: .medium)); Spacer(); Text(L(formatBytes(item.bytes))).font(.system(size: 22, weight: .medium, design: .monospaced)) }
            Text(item.url.lastPathComponent).font(.system(size: 16, weight: .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(item.url.path).font(.system(size: 13)).foregroundStyle(SweepStyle.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Divider()
            LabeledContent(L("所属应用"), value: L(item.assessment.owner))
            LabeledContent(L("用途"), value: L(item.category.title))
            LabeledContent(L("建议"), value: L(item.assessment.disposition.title))
            LabeledContent(L("修改日期"), value: item.modified.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(InterfaceLanguage.current.locale)))
            Text(L(item.assessment.reason)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(L("判断依据")) {
                Text(L(item.assessment.evidence)).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                if let source = item.assessment.sourceURL, let url = URL(string: source) { Link(L("官方说明"), destination: url).font(.system(size: 12)) }
            }
            HStack(spacing: 12) {
                Button(L("预览")) { model.preview(item.url) }
                Button(L("在访达中查看")) { model.reveal(item.url) }
                Button(L("复制完整路径")) { model.copyPath(item.url) }
                Button(L("忽略此文件")) { model.ignore(item.url) }.disabled(model.busy)
                Spacer()
                Button(L("完成")) { model.inspecting = nil }.keyboardShortcut(.defaultAction)
            }
        }.font(.system(size: 13)).padding(28).frame(width: 660)
    }
}
