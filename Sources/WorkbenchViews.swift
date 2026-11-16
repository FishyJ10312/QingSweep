import SwiftUI

struct WorkbenchView: View {
  @EnvironmentObject var model: AppModel
  var body: some View { WorkbenchPanels(tools: model.workbench).environmentObject(model) }
}
struct WorkbenchPanels: View {
  @EnvironmentObject var model: AppModel
  @ObservedObject var tools: WorkbenchModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(L("工具")).font(.system(size: 24, weight: .semibold))
        Spacer()
        if tools.busy{Text(L("任务进行中")).font(.system(size:12)).foregroundStyle(SweepStyle.secondary)}
      }
      if tools.busy{ToolProgressView(tools:tools)}
      HStack(spacing: 8) {
        ForEach(WorkbenchSection.allCases) { section in
          Button {
            tools.section = section
          } label: {
            Label(L(section.rawValue), systemImage: section.icon).frame(maxWidth: .infinity).padding(
              .vertical, 10)
          }.buttonStyle(.plain).foregroundStyle(
            tools.section == section ? Color.white : SweepStyle.ink
          ).background(
            tools.section == section ? CleanupScope.optional.color : SweepStyle.surface,
            in: RoundedRectangle(cornerRadius: 8))
        }
      }
      Group {
        switch tools.section {
        case .resolve: resolve
        case .growth: growth
        case .applications: applications
        case .duplicates: duplicates
        case .archive: archive
        case .startup: startup
        case .tasks:ToolTasksView(tools:tools)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }.padding(16)
      .disabled(model.mutating || model.scanning || model.analyzing || model.loadingReport)
      .alert(
        L("工具"),
        isPresented: Binding(get: { tools.message != nil }, set: { if !$0 { tools.message = nil } })
      ) {
        Button(L("完成"), role: .cancel) { tools.message = nil }
      } message: {
        Text(Localization.error(tools.message ?? ""))
      }
      .sheet(isPresented: $tools.showingManagedReview) {
        ManagedReviewView(tools: tools).environmentObject(model)
      }
      .confirmationDialog(
        L(tools.startupAction?.disabled == true ? "重新启用此启动项？" : "停用此启动项？"),
        isPresented: Binding(
          get: { tools.startupAction != nil }, set: { if !$0 { tools.startupAction = nil } }),
        titleVisibility: .visible
      ) {
        if let entry = tools.startupAction {
          Button(L(entry.disabled == true ? "启用" : "停用")) { tools.changeStartup(entry) }
            .disabled(entry.disabled == nil)
        }
        Button(L("取消"), role: .cancel) { tools.startupAction = nil }
      } message: {
        Text(tools.startupAction?.label ?? "")
      }
  }
  private func header(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L(title)).font(.system(size: 21, weight: .semibold))
      Text(L(subtitle)).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary).fixedSize(
        horizontal: false, vertical: true)
    }
  }
  private func empty(_ title: String, _ icon: String) -> some View {
    ContentUnavailableView(L(title), systemImage: icon).frame(
      maxWidth: .infinity, maxHeight: .infinity)
  }
  private func issues(_ values: [String]) -> some View {
    Group {
      if !values.isEmpty {
        DisclosureGroup(L("未读取与跳过 · \(values.count)")) {
          Text(Localization.error(values.prefix(100).joined(separator: "\n"))).font(.system(size: 11)).textSelection(
            .enabled)
        }.padding(12)
      }
    }
  }
  private func select(_ ids: [String], selection: Binding<Set<String>>) {
    let set = Set(ids)
    if set.isSubset(of: selection.wrappedValue) {
      selection.wrappedValue.subtract(set)
    } else {
      selection.wrappedValue.formUnion(set)
    }
  }
  private var resolve: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        header("达芬奇媒体", "代理、渲染缓存和优化媒体分开查看；是否仍需要由你确认。 ")
        if tools.media.cancelled || tools.media.limited{Text(L(tools.media.cancelled ? "部分结果 · 已停止":"部分结果 · 已达扫描上限")).font(.system(size:12,weight:.medium)).foregroundStyle(CleanupScope.protected.color)}
        Spacer()
        Button(L("选择目录"), action: tools.chooseMedia).buttonStyle(SweepOutlineButton()).disabled(
          model.busy)
        Button(L("检查默认位置")) { tools.scanMedia() }.buttonStyle(
          SweepPrimaryButton(color: CleanupScope.protected.color)
        ).disabled(model.busy)
      }
      HStack(alignment: .top, spacing: 12) {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            Button(L("全部 · \(tools.media.files.count)")) { tools.mediaGroup = nil }.buttonStyle(
              SweepOutlineButton())
            ForEach(tools.media.groups) { group in
              Button {
                tools.mediaGroup = group.id
                tools.mediaLimit = 100
              } label: {
                VStack(alignment: .leading, spacing: 6) {
                  Text(L(group.kind.rawValue)).font(.system(size: 14, weight: .semibold))
                  Text(group.url.lastPathComponent).font(.system(size: 12)).lineLimit(1)
                  Text(L(formatBytes(group.bytes) + " · \(group.files.count) 项")).font(
                    .system(size: 12, design: .monospaced))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(
                  CleanupScope.protected.color.opacity(tools.mediaGroup == group.id ? 0.15 : 0.05),
                  in: RoundedRectangle(cornerRadius: 10))
              }.buttonStyle(.plain).help(group.url.path)
            }
          }
        }.frame(width: 200)
        VStack(spacing: 0) {
          HStack {
            Text(L("媒体清单")).font(.system(size: 18, weight: .semibold))
            Spacer()
            Button(L("全选当前组")) { tools.toggleMediaGroup(tools.visibleMedia) }.buttonStyle(
              SweepPrimaryButton(color: CleanupScope.protected.color)
            ).disabled(tools.visibleMedia.isEmpty || model.busy)
          }.padding(12)
          Divider()
          if tools.visibleMedia.isEmpty {
            empty("选择位置开始检查", "film.stack")
          } else {
            ScrollView {
              LazyVStack(spacing: 0) {
                ForEach(Array(tools.visibleMedia.prefix(tools.mediaLimit))) { file in
                  mediaRow(file)
                  Divider()
                }
                if tools.visibleMedia.count > tools.mediaLimit {
                  Button(L("加载更多")) { tools.mediaLimit += 100 }.padding()
                }
              }
            }
          }
          issues(tools.media.issues)
          Divider()
          HStack {
            Text(L("已选 \(tools.mediaSelected.count) 项"))
            Spacer()
            Button(L("检查所选文件")) {
              model.reviewToolFiles(
                tools.media.files.filter { tools.mediaSelected.contains($0.id) }.map(\.item),
                title: "达芬奇媒体")
            }.buttonStyle(SweepPrimaryButton(color: CleanupScope.protected.color)).disabled(
              tools.mediaSelected.isEmpty || model.busy)
          }.font(.system(size: 12)).padding(12)
        }.sweepCard()
      }
    }
  }
  private func mediaRow(_ file: ResolveMediaFile) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Toggle(
        L("选择 ") + file.item.url.lastPathComponent,
        isOn: Binding(
          get: { tools.mediaSelected.contains(file.id) },
          set: {
            if $0 {
              tools.mediaSelected.insert(file.id)
            } else {
              tools.mediaSelected.remove(file.id)
            }
          })
      ).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
      VStack(alignment: .leading, spacing: 7) {
        Text(file.item.url.lastPathComponent).font(.system(size: 14, weight: .medium))
        Text(file.item.url.path).font(.system(size: 11)).foregroundStyle(SweepStyle.secondary)
          .lineLimit(2).textSelection(.enabled)
        if let facts = file.facts { Text(L(facts.description)).font(.system(size: 12)) }
        if let association = tools.associations.first(where: { $0.media == file.item.url }) {
          Text(
            L(association.available ? "已确认原片 · " : "已确认的原片已变化或离线 · ")
              + association.original.lastPathComponent
          ).font(.system(size: 12)).foregroundStyle(
            association.available ? CleanupScope.optional.color : SweepStyle.warning)
        }
        HStack {
          Button(L("参数与原片候选")) { tools.inspectMedia(file, indexURL: model.storageIndexURL) }
          Button(L("关联原片")) { tools.confirmOriginal(for: file) }
          Button(L("预览")) { model.preview(file.item.url) }
        }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(CleanupScope.optional.color)
          .disabled(model.busy)
        if !file.possibleOriginals.isEmpty {
          DisclosureGroup(L("同名候选 · 尚未确认")) {
            ForEach(file.possibleOriginals, id: \.path) { url in
              HStack {
                Text(url.path).font(.system(size: 11)).lineLimit(2)
                Spacer()
                Button(L("确认为原片")) { tools.confirmOriginal(for: file, url: url) }
              }
            }
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      Text(L(formatBytes(file.item.bytes))).font(.system(size: 12, design: .monospaced))
    }.padding(12)
  }
  private var growth: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        header("空间增长", "比较相同扫描范围和访问状态的记录。授权或范围变化会建立新基线。")
        Spacer()
        Button(L("更新扫描")) { model.runStorageAnalysis() }.buttonStyle(
          SweepPrimaryButton(color: CleanupScope.optional.color)
        ).disabled(model.busy)
      }
      Picker(L("比较"), selection: $tools.growthDays) {
        Text(L("上次记录")).tag(0)
        Text(L("约 7 天")).tag(7)
        Text(L("约 30 天")).tag(30)
      }.pickerStyle(.segmented).frame(width: 320)
      if let pair = tools.growth.comparison(days: tools.growthDays) {
        Text(
          L(pair.0.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(InterfaceLanguage.current.locale)) + " → "
            + pair.1.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(InterfaceLanguage.current.locale)))
        ).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
      }
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(tools.growthChanges) { change in
            HStack {
              Text(L(change.title)).font(.system(size: 15, weight: .medium))
              Spacer()
              Text(L(formatBytes(change.before) + " → " + formatBytes(change.after))).font(
                .system(size: 12)
              ).foregroundStyle(SweepStyle.secondary)
              Text(L((change.delta > 0 ? "+" : "−") + formatBytes(abs(change.delta)))).font(
                .system(size: 15, weight: .semibold, design: .monospaced)
              ).foregroundStyle(
                change.delta > 0 ? CleanupScope.recommended.color : CleanupScope.optional.color
              ).frame(width: 120, alignment: .trailing)
              Button(L("查看")) { model.showStorageOwner(change.id, title: change.title) }
            }.padding(16)
            Divider()
          }
        }
      }.sweepCard()
      if tools.growth.comparison(days: tools.growthDays) == nil {
        Text(L(tools.growth.snapshots.isEmpty ? "完整扫描完成后自动保存第一份记录" : "已有基线，下一次同范围扫描后可比较")).font(
          .system(size: 13)
        ).foregroundStyle(SweepStyle.secondary)
      }
    }
  }
  private var applications: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        header("应用与残留", "仅列出程序本体与标识明确匹配的私有目录。数据、素材与项目默认不选。")
        Spacer()
        Button(L("可能残留"), action: tools.findLeftovers).buttonStyle(SweepOutlineButton()).disabled(
          model.busy)
        Button(L("读取应用"), action: tools.refreshApplications).buttonStyle(
          SweepPrimaryButton(color: CleanupScope.optional.color)
        ).disabled(model.busy)
      }
      HStack(alignment: .top, spacing: 12) {
        VStack {
          TextField(L("搜索应用"), text: $tools.applicationSearch).textFieldStyle(.roundedBorder).padding(
            8)
          ScrollView {
            LazyVStack(spacing: 4) {
              ForEach(
                tools.applications.filter {
                  tools.applicationSearch.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(tools.applicationSearch)
                }, id: \.path
              ) { app in
                Button {
                  tools.inspectApplication(app)
                } label: {
                  VStack(alignment: .leading, spacing: 5) {
                    Text(app.name).font(.system(size: 14, weight: .medium))
                    Text(app.version).font(.system(size: 11)).foregroundStyle(SweepStyle.secondary)
                  }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(
                    tools.inspection?.app.path == app.path
                      ? CleanupScope.optional.color.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(model.busy)
              }
            }
          }
        }.frame(width: 220).sweepCard()
        VStack(spacing: 0) {
          HStack {
            Text(L(tools.managedRetryItems != nil ? "未处理内容" : tools.showingLeftovers ? "可能残留" : tools.inspection?.app.name ?? "应用内容")).font(
              .system(size: 18, weight: .semibold))
            Spacer()
            Button(L("全选当前清单")) {
              select(tools.managedItems.map(\.id), selection: $tools.managedSelected)
            }.buttonStyle(SweepOutlineButton()).disabled(model.busy || tools.managedItems.isEmpty)
          }.padding(12)
          Divider()
          if tools.showingLeftovers {
            Text(L("可能属于外置盘或便携应用，请核实后选择。")).font(.system(size: 12)).foregroundStyle(SweepStyle.warning)
              .padding(12)
          }
          if tools.managedItems.isEmpty {
            empty(tools.inspection == nil ? "选择一个应用" : "暂无可读内容", "app")
          } else {
            ScrollView {
              LazyVStack(spacing: 0) {
                ForEach(tools.managedItems) { item in
                  Toggle(
                    isOn: Binding(
                      get: { tools.managedSelected.contains(item.id) },
                      set: {
                        if $0 {
                          tools.managedSelected.insert(item.id)
                        } else {
                          tools.managedSelected.remove(item.id)
                        }
                      })
                  ) {
                    HStack {
                      VStack(alignment: .leading, spacing: 6) {
                        Text(L(item.role)).font(.system(size: 15, weight: .semibold))
                        Text(item.url.path).font(.system(size: 11)).foregroundStyle(
                          SweepStyle.secondary
                        ).textSelection(.enabled)
                      }
                      Spacer()
                      Text(L(formatBytes(item.bytes))).font(.system(size: 13, design: .monospaced))
                    }
                  }.toggleStyle(.checkbox).padding(14).disabled(model.busy)
                  Divider()
                }
              }
            }
          }
          issues(tools.showingLeftovers ? tools.applicationIssues : tools.inspection?.issues ?? [])
          Divider()
          HStack {
            Text(L("已选 \(tools.managedSelected.count) 项"))
            Spacer()
            Button(L("检查所选内容"), action: tools.prepareManagedReview).buttonStyle(
              SweepPrimaryButton(color: CleanupScope.protected.color)
            ).disabled(model.busy || tools.managedSelected.isEmpty)
          }.padding(12).font(.system(size: 12))
        }.sweepCard()
      }
    }.onAppear { if tools.applications.isEmpty && !model.busy { tools.refreshApplications() } }
  }
  private var duplicates: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        header("精确重复文件", "同大小、片段比较后逐字节流式计算 SHA-256；每组至少保留一份。")
        Spacer()
        Button(L("选择查重范围")) { tools.findDuplicates() }.buttonStyle(
          SweepPrimaryButton(color: CleanupScope.optional.color)
        ).disabled(model.busy)
      }
      if !tools.duplicateRoots.isEmpty {
        Text(tools.duplicateRoots.map(\.path).joined(separator: " · ")).font(.system(size: 11))
          .foregroundStyle(SweepStyle.secondary).lineLimit(2)
      }
      HStack {
        ModuleStat(
          title: "重复组", value: "\(tools.duplicates.groups.count) 组",
          color: CleanupScope.optional.color)
        ModuleStat(
          title: "额外副本分配空间",
          value: formatBytes(tools.duplicates.groups.reduce(0) { $0 + $1.copyBytes }),
          color: CleanupScope.protected.color, detail: "APFS 克隆可能共享空间，实际释放量会不同")
      }
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(Array(tools.duplicates.groups.prefix(tools.duplicateLimit))) { group in
            VStack(alignment: .leading, spacing: 0) {
              HStack {
                Text(L("\(group.files.count) 份相同内容")).font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(L(formatBytes(group.files[0].stamp.size) + " / 份")).font(.system(size: 12))
              }.padding(12).background(CleanupScope.optional.color.opacity(0.06))
              ForEach(group.files) { file in
                HStack {
                  Toggle(
                    L("选择 ") + file.url.lastPathComponent,
                    isOn: Binding(
                      get: { tools.duplicateSelected.contains(file.id) },
                      set: { _ in tools.toggleDuplicate(file, in: group) })
                  ).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
                  VStack(alignment: .leading, spacing: 5) {
                    Text(file.url.lastPathComponent).font(.system(size: 14, weight: .medium))
                    Text(file.url.path).font(.system(size: 11)).foregroundStyle(
                      SweepStyle.secondary
                    ).textSelection(.enabled)
                  }
                  Spacer()
                  if !tools.duplicateSelected.contains(file.id) {
                    Text(L("保留")).font(.system(size: 12)).foregroundStyle(CleanupScope.optional.color)
                  }
                  Button(L("预览")) { model.preview(file.url) }
                }.padding(12)
                Divider()
              }
            }.sweepCard()
          }
          if tools.duplicates.groups.count > tools.duplicateLimit {
            Button(L("加载更多组")) { tools.duplicateLimit += 50 }
          }
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      issues(tools.duplicates.issues)
      HStack {
        Text(L(tools.duplicates.cancelled ? "部分结果 · 已停止" : "已校验 \(tools.duplicates.verified) 项")).font(
          .system(size: 12)
        ).foregroundStyle(SweepStyle.secondary)
        Spacer()
        Button(L("检查所选副本")) {
          do {
            let guards = try DuplicateFinder.guards(
              groups: tools.duplicates.groups, selected: tools.duplicateSelected)
            model.reviewToolFiles(
              tools.duplicates.groups.flatMap(\.files).filter {
                tools.duplicateSelected.contains($0.id)
              }, title: "精确重复文件", guards: guards)
          } catch { tools.message = error.localizedDescription }
        }.buttonStyle(SweepPrimaryButton(color: CleanupScope.protected.color)).disabled(
          model.busy || tools.duplicateSelected.isEmpty)
      }
    }
  }
  private var archive: some View {
    VStack(alignment: .leading, spacing: 12) {
      header("归档与校验", "复制到新目录，内容校验完成后保留来源。清理来源需另行勾选确认。")
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 14) {
          Text(L("归档设置")).font(.system(size: 18, weight: .semibold))
          Button(L("选择来源"), action: tools.chooseArchiveSources).buttonStyle(SweepOutlineButton())
          ForEach(tools.archiveSources, id: \.path) {
            Text($0.path).font(.system(size: 11)).lineLimit(2)
          }
          Divider()
          Button(L("选择目标"), action: tools.chooseArchiveDestination).buttonStyle(SweepOutlineButton())
          if let destination = tools.archiveDestination {
            Text(destination.path).font(.system(size: 11)).lineLimit(3)
          }
          Button(L("复制并校验"), action: tools.startArchive).buttonStyle(
            SweepPrimaryButton(color: CleanupScope.optional.color)
          ).disabled(tools.archiveSources.isEmpty || tools.archiveDestination == nil)
          Spacer()
        }.padding(16).frame(width: 225).sweepCard().disabled(model.busy)
        VStack(alignment: .leading, spacing: 12) {
          Text(L("已校验归档")).font(.system(size: 18, weight: .semibold))
          ScrollView {
            LazyVStack(spacing: 10) {
              ForEach(tools.archives) { receipt in
                VStack(alignment: .leading, spacing: 8) {
                  HStack {
                    Text(L(receipt.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(InterfaceLanguage.current.locale)))).font(
                      .system(size: 15, weight: .medium))
                    Spacer()
                    Text(L(formatBytes(receipt.bytes))).font(.system(size: 13, design: .monospaced))
                    Button(L("检查来源")) { tools.inspectArchive(receipt) }.disabled(model.busy)
                  }
                  Text(receipt.root.path).font(.system(size: 11)).foregroundStyle(
                    SweepStyle.secondary
                  ).textSelection(.enabled)
                  Text(L("\(receipt.files.count) 个文件 · 内容 SHA-256 校验通过")).font(.system(size: 12))
                    .foregroundStyle(CleanupScope.optional.color)
                }.padding(12).sweepCard()
              }
            }
          }
          if !tools.archiveCandidates.isEmpty {
            HStack {
              Text(L("来源文件 · 默认不选")).font(.system(size: 16, weight: .semibold))
              Spacer()
              Button(L("全选来源")) {
                select(tools.archiveCandidates.map(\.id), selection: $tools.archiveSelected)
              }.buttonStyle(SweepOutlineButton()).disabled(model.busy)
            }
            ScrollView {
              LazyVStack {
                ForEach(Array(tools.archiveCandidates.prefix(tools.archiveLimit))) { item in
                  Toggle(
                    item.url.path,
                    isOn: Binding(
                      get: { tools.archiveSelected.contains(item.id) },
                      set: {
                        if $0 {
                          tools.archiveSelected.insert(item.id)
                        } else {
                          tools.archiveSelected.remove(item.id)
                        }
                      })
                  ).font(.system(size: 12)).toggleStyle(.checkbox).disabled(model.busy)
                }
              }
            }.frame(maxHeight: 200)
            if tools.archiveCandidates.count > tools.archiveLimit {
              Button(L("加载更多来源 · \(tools.archiveLimit) / \(tools.archiveCandidates.count)")) {
                tools.archiveLimit += 100
              }
            }
            Button(L("检查所选来源")) {
              model.reviewToolFiles(
                tools.archiveCandidates.filter { tools.archiveSelected.contains($0.id) },
                title: "已归档来源", guards: tools.archiveGuards)
            }.buttonStyle(SweepPrimaryButton(color: CleanupScope.protected.color)).disabled(
              model.busy || tools.archiveSelected.isEmpty)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
  }
  private var startup: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        header("启动项", "管理当前用户的 LaunchAgents；系统和其他后台项目在系统设置中管理。")
        Spacer()
        Button(L("系统登录项"), action: tools.openLoginItems).buttonStyle(SweepOutlineButton())
        Button(L("重新检查"), action: tools.refreshStartups).buttonStyle(
          SweepPrimaryButton(color: CleanupScope.optional.color)
        ).disabled(model.busy)
      }
      ScrollView {
        LazyVStack(spacing: 10) {
          ForEach(tools.startups) { entry in
            HStack {
              VStack(alignment: .leading, spacing: 8) {
                Text(entry.label).font(.system(size: 16, weight: .medium))
                Text(L(entry.program)).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
                  .textSelection(.enabled)
                Text(L(
                  entry.disabled == nil ? "状态待确认，请重新检查"
                    : entry.disabled == true ? (entry.loaded ? "已停用，仍已载入" : "已停用")
                    : entry.loaded ? "已载入" : "已启用，未载入"
                )).font(
                  .system(size: 12)
                ).foregroundStyle(
                  entry.disabled == true ? CleanupScope.protected.color : CleanupScope.optional.color
                )
                if entry.disabledBySweep {
                  Text(L("轻扫有停用记录")).font(.system(size: 12)).foregroundStyle(SweepStyle.secondary)
                }
              }
              Spacer()
              Button(L(entry.disabled == true ? "启用" : "停用")) { tools.startupAction = entry }
                .buttonStyle(SweepOutlineButton()).disabled(model.busy || entry.disabled == nil)
            }.padding(16).sweepCard()
          }
        }
      }
      issues(tools.startupIssues)
    }.onAppear { if tools.startups.isEmpty && !model.busy { tools.refreshStartups() } }
  }
}
struct ManagedReviewView: View {
  @EnvironmentObject var model: AppModel
  @ObservedObject var tools: WorkbenchModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L("确认所选应用内容")).font(.system(size: 24, weight: .semibold))
      Text(L("应用将正常退出；所选内容移到废纸篓，可在清理记录中按批恢复。")).font(.system(size: 13)).foregroundStyle(
        SweepStyle.secondary)
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(tools.managedReview) { item in
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 6) {
                Text(L(item.role + " · " + item.title)).font(.system(size: 14, weight: .medium))
                Text(item.url.path).font(.system(size: 11)).textSelection(.enabled)
              }
              Spacer()
              Text(L(formatBytes(item.bytes))).font(.system(size: 12))
              Button(L("取消此项")) {
                tools.managedReview.removeAll { $0.id == item.id }
                tools.managedSelected.remove(item.id)
                tools.managedAcknowledged = false
              }
            }
          }
        }
      }.frame(height: 300).sweepCard()
      Toggle(L("我已核实数据用途，确认删除所选内容"), isOn: $tools.managedAcknowledged).toggleStyle(.checkbox)
      HStack {
        Button(L("返回")) { tools.showingManagedReview = false }.keyboardShortcut(.cancelAction)
        Spacer()
        Text(L("\(tools.managedReview.count) 项"))
        Button(L("确认移到废纸篓")) { model.moveManagedReview() }.buttonStyle(
          SweepPrimaryButton(color: CleanupScope.protected.color)
        ).disabled(!tools.managedAcknowledged || tools.managedReview.isEmpty || model.busy)
      }
    }.padding(28).frame(width: 720).background(SweepStyle.background)
  }
}
