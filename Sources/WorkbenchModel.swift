import AppKit
import Combine
import Foundation
import ServiceManagement

enum WorkbenchSection: String, CaseIterable, Identifiable {
  case resolve = "达芬奇"
  case growth = "增长"
  case applications = "应用"
  case duplicates = "重复文件"
  case archive = "归档"
  case startup = "启动项"
  case tasks = "任务"
  var id: String { rawValue }
  var icon: String {
    switch self {
    case .resolve: return "film.stack"
    case .growth: return "chart.line.uptrend.xyaxis"
    case .applications: return "app.badge"
    case .duplicates: return "square.on.square"
    case .archive: return "externaldrive"
    case .startup: return "power"
    case .tasks: return "list.bullet.rectangle"
    }
  }
}
@MainActor final class WorkbenchModel: ObservableObject {
  let home: URL
  let support: URL
  @Published var section: WorkbenchSection = .resolve
  @Published var busy = false
  @Published var progress = ""
  @Published var progressData = OperationProgress(phase: "准备")
  @Published var activeStarted: Date?
  @Published var tasks: [ToolTaskRecord] = []
  @Published var taskLoadIssue: String?
  @Published var message: String?
  @Published var media = ResolveMediaReport()
  @Published var mediaSelected = Set<String>()
  @Published var mediaLimit = 100
  @Published var mediaGroup: String?
  @Published var associations: [MediaAssociation] = []
  @Published var duplicates = DuplicateResult()
  @Published var duplicateSelected = Set<String>()
  @Published var duplicateLimit = 50
  @Published var duplicateRoots: [URL] = []
  @Published var applications: [InstalledApplication] = []
  @Published var applicationSearch = ""
  @Published var inspection: AppInspection?
  @Published var managedSelected = Set<String>()
  @Published var leftovers: [ManagedItem] = []
  @Published var showingLeftovers = false
  @Published var managedRetryItems: [ManagedItem]?
  @Published var managedReview: [ManagedItem] = []
  @Published var showingManagedReview = false
  @Published var managedAcknowledged = false
  @Published var applicationIssues: [String] = []
  @Published var archiveSources: [URL] = []
  @Published var archiveDestination: URL?
  @Published var archives: [ArchiveReceipt] = []
  @Published var archiveCandidates: [ScanItem] = []
  @Published var archiveSelected = Set<String>()
  @Published var archiveLimit = 100
  var archiveGuards: [String: RetainedCopy] = [:]
  @Published var startups: [StartupEntry] = []
  @Published var startupIssues: [String] = []
  @Published var startupAction: StartupEntry?
  @Published var startupReceipts: [StartupReceipt] = []
  @Published var growth = GrowthHistory()
  @Published var growthDays = 0
  @Published var memoryTrend = MemoryTrend()
  @Published var menuEnabled = false {
    didSet {
      save(menuEnabled, "monitor-enabled.json")
      configureMenu()
    }
  }
  var openMainWindow: (() -> Void)?
  private var monitor: MemoryMenuMonitor?
  private var token: ScanCancellation?
  private var activeID: UUID?
  private var relay: OperationProgressRelay?
  private var canSaveTasks = true
  private var tasksURL: URL { support.appendingPathComponent("task-history.json") }
  init(home: URL) {
    self.home = home
    support = home.appendingPathComponent("Library/Application Support/QingSweep")
    associations = load([MediaAssociation].self, "media-associations.json") ?? []
    archives = load([ArchiveReceipt].self, "archives.json") ?? []
    startupReceipts = load([StartupReceipt].self, "startup-items.json") ?? []
    growth = GrowthHistory(snapshots: load([GrowthSnapshot].self, "growth-history.json") ?? [])
    menuEnabled = load(Bool.self, "monitor-enabled.json") ?? false
    do { tasks = try ToolTaskStore.load(tasksURL) } catch {
      canSaveTasks = false
      taskLoadIssue = "任务记录无法读取，新任务暂存于本次会话"
    }
    if home == FileManager.default.homeDirectoryForCurrentUser, menuEnabled { configureMenu() }
  }
  private func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
    guard let data = try? Data(contentsOf: support.appendingPathComponent(name)),
      data.count < 50_000_000
    else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }
  private func save<T: Encodable>(_ value: T, _ name: String) {
    do {
      try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
      try JSONEncoder().encode(value).write(
        to: support.appendingPathComponent(name), options: .atomic)
    } catch { message = "记录保存失败：" + error.localizedDescription }
  }
  private func saveTasks() {
    guard canSaveTasks else { return }
    do { try ToolTaskStore.save(tasks, to: tasksURL) } catch {
      canSaveTasks = false
      taskLoadIssue = "任务记录保存失败，新任务暂存于本次会话"
    }
  }
  func rebuildTaskHistory() {
    guard !busy else { return }
    do {
      if FileStamp.read(tasksURL) != nil {
        try FileManager.default.moveItem(
          at: tasksURL,
          to: support.appendingPathComponent(
            "task-history-unreadable-" + UUID().uuidString + ".json"))
      }
      try ToolTaskStore.save(tasks, to: tasksURL)
      canSaveTasks = true
      taskLoadIssue = nil
    } catch { taskLoadIssue = "暂时无法重建任务记录：" + error.localizedDescription }
  }
  func unselect(_ paths: Set<String>) {
    mediaSelected.subtract(paths)
    duplicateSelected.subtract(paths)
    archiveSelected.subtract(paths)
  }
  func didMove(_ urls: [URL]) {
    let removed = Set(urls.map(\.path))
    unselect(removed)
    media.files.removeAll { removed.contains($0.id) }
    duplicates.groups = duplicates.groups.compactMap { group in
      let remaining = group.files.filter { !removed.contains($0.id) }
      return remaining.count > 1 ? DuplicateGroup(id: group.id, files: remaining) : nil
    }
    archiveCandidates.removeAll { removed.contains($0.id) }
  }
  func stop() {
    token?.cancel()
    progress = "正在停止后续操作"
    progressData.phase = "正在停止"
    progressData.current = ""
  }
  private func begin(_ plan: ToolTaskPlan) -> ScanCancellation? {
    guard !busy else { return nil }
    let id = UUID()
    let started = Date()
    let value = ScanCancellation()
    activeID = id
    activeStarted = started
    token = value
    busy = true
    progress = "正在检查"
    progressData = OperationProgress(phase: "准备")
    tasks.insert(
      ToolTaskRecord(
        id: id, started: started, ended: nil, plan: plan, status: .running, progress: progressData),
      at: 0)
    tasks = Array(tasks.prefix(50))
    saveTasks()
    relay = OperationProgressRelay { [weak self] update in
      Task { @MainActor in
        guard let self, self.activeID == id, self.busy, self.token?.isCancelled != true else {
          return
        }
        self.progressData = update
        self.progress = update.phase + (update.current.isEmpty ? "" : " · " + update.current)
        if let index = self.tasks.firstIndex(where: { $0.id == id }) {
          self.tasks[index].progress = update
        }
      }
    }
    return value
  }
  private func end(
    count: Int = 0, issues: [String] = [], failed: Bool = false, partial: Bool = false,
    committed: Bool = false
  ) {
    let status: ToolTaskStatus =
      token?.isCancelled == true && !committed
      ? .cancelled
      : failed
        ? .failed
        : partial ? .partial : issues.isEmpty ? .completed : count > 0 ? .partial : .failed
    if let id = activeID, let index = tasks.firstIndex(where: { $0.id == id }) {
      tasks[index].ended = Date()
      tasks[index].status = status
      tasks[index].resultCount = count
      tasks[index].issueCount = issues.count
      tasks[index].details = Array(issues.prefix(100))
      tasks[index].progress.phase = status.rawValue
    }
    activeID = nil
    activeStarted = nil
    relay = nil
    token = nil
    busy = false
    progress = ""
    saveTasks()
  }
  func scanMedia(roots: [URL]? = nil) {
    let home = self.home
    let roots =
      roots
      ?? ["Movies/ProxyMedia", "Movies/CacheClip", "Movies/OptimizedMedia"].map {
        home.appendingPathComponent($0)
      }.filter { FileStamp.read($0) != nil }
    guard let token = begin(ToolTaskPlan(kind: .media, roots: roots)), let relay else { return }
    mediaSelected = []
    mediaGroup = nil
    mediaLimit = 100
    guard !roots.isEmpty else {
      end(issues: ["未找到默认目录"], failed: true)
      message = "未找到默认目录，请选择达芬奇的缓存或代理文件夹"
      return
    }
    Task {
      let result = await Task.detached(priority: .utility) {
        ResolveMediaAudit.scan(roots: roots, home: home, cancellation: token) {
          relay.send(OperationProgress(phase: "扫描", current: $0))
        }
      }.value
      media = result
      end(count: result.files.count, issues: result.issues, partial: result.limited)
    }
  }
  func chooseMedia() {
    if let url = choose(title: "选择 ProxyMedia、CacheClip 或 OptimizedMedia 文件夹", directories: true)
      .first
    {
      scanMedia(roots: [url])
    }
  }
  var visibleMedia: [ResolveMediaFile] {
    media.files.filter { mediaGroup == nil || $0.group.path == mediaGroup }
  }
  func toggleMediaGroup(_ files: [ResolveMediaFile]) {
    let ids = Set(files.map(\.id))
    if ids.isSubset(of: mediaSelected) {
      mediaSelected.subtract(ids)
    } else {
      mediaSelected.formUnion(ids)
    }
  }
  func inspectMedia(_ file: ResolveMediaFile, indexURL: URL) {
    guard let token = begin(ToolTaskPlan(kind: .mediaDetails, roots: [file.item.url])) else {
      return
    }
    Task {
      do {
        let facts = try? await VideoInspector.inspect(file.item.url, stamp: file.item.stamp)
        let matches = try await Task.detached(priority: .utility) {
          try ResolveMediaAudit.possibleOriginals(for: file, index: StorageIndex(url: indexURL))
        }.value
        if !token.isCancelled, let index = media.files.firstIndex(where: { $0.id == file.id }) {
          media.files[index].facts = facts
          media.files[index].possibleOriginals = matches
        }
        if facts == nil && matches.isEmpty {
          let text = "此格式暂无可读视频参数，也未找到同名原片。可手动关联原片。"
          message = text
          end(issues: [text])
        } else {
          end(count: 1)
        }
      } catch {
        message = error.localizedDescription
        end(issues: [error.localizedDescription], failed: true)
      }
    }
  }
  func confirmOriginal(for file: ResolveMediaFile, url: URL? = nil) {
    guard !busy, let original = url ?? choose(title: "选择你已核实的原片", directories: false).first,
      LocalFiles.noLinks(original), let stamp = FileStamp.read(original), stamp.isRegular,
      !stamp.isDataless, original != file.item.url
    else { return }
    associations.removeAll { $0.media == file.item.url }
    associations.append(
      MediaAssociation(
        media: file.item.url, original: original, originalStamp: stamp, confirmedAt: Date()))
    save(associations, "media-associations.json")
  }
  func findDuplicates(roots: [URL]? = nil) {
    let roots = roots ?? choose(title: "选择查重范围", directories: true, multiple: true)
    guard !roots.isEmpty, let token = begin(ToolTaskPlan(kind: .duplicates, roots: roots)),
      let relay
    else { return }
    duplicateRoots = roots
    duplicateSelected = []
    duplicateLimit = 50
    let home = self.home
    Task {
      let result = await Task.detached(priority: .utility) {
        DuplicateFinder.scan(
          roots: roots, home: home, cancellation: token, progressData: { relay.send($0) })
      }.value
      duplicates = result
      end(count: result.groups.count, issues: result.issues)
    }
  }
  func toggleDuplicate(_ item: ScanItem, in group: DuplicateGroup) {
    if duplicateSelected.contains(item.id) {
      duplicateSelected.remove(item.id)
    } else if group.files.filter({ !duplicateSelected.contains($0.id) }).count > 1 {
      duplicateSelected.insert(item.id)
    } else {
      message = "每组至少保留一份文件"
    }
  }
  func refreshApplications() {
    guard let token = begin(ToolTaskPlan(kind: .applications)) else { return }
    let home = self.home
    Task {
      let apps = await Task.detached(priority: .utility) { AppInventory.collect(home: home) }.value
      if !token.isCancelled { applications = apps }
      end(count: apps.count)
    }
  }
  func inspectApplication(_ app: InstalledApplication) {
    guard
      let token = begin(
        ToolTaskPlan(kind: .application, roots: [URL(fileURLWithPath: app.path)], application: app))
    else { return }
    managedSelected = []
    managedRetryItems = nil
    inspection = nil
    showingLeftovers = false
    let home = self.home
    Task {
      let result = await Task.detached(priority: .utility) {
        AppInventory.inspect(app, home: home, cancellation: token)
      }.value
      inspection = result
      end(count: result.items.count, issues: result.issues)
    }
  }
  func findLeftovers() {
    guard let token = begin(ToolTaskPlan(kind: .leftovers)) else { return }
    managedSelected = []
    managedRetryItems = nil
    inspection = nil
    showingLeftovers = true
    let home = self.home
    Task {
      let apps = await Task.detached(priority: .utility) { AppInventory.collect(home: home) }.value
      let result = await Task.detached(priority: .utility) {
        AppInventory.possibleLeftovers(home: home, installed: apps, cancellation: token)
      }.value
      applications = apps
      leftovers = result.0
      applicationIssues = result.1
      end(count: result.0.count, issues: result.1)
    }
  }
  var managedItems: [ManagedItem] {
    managedRetryItems ?? (showingLeftovers ? leftovers : inspection?.items ?? [])
  }
  func loadManagedRetry(_ items: [ManagedItem]) {
    managedRetryItems = items
    showingLeftovers = false
    inspection = nil
    managedSelected = Set(items.map(\.id))
    managedReview = items
    managedAcknowledged = false
    showingManagedReview = !items.isEmpty
  }
  func prepareManagedReview() {
    managedReview = managedItems.filter { managedSelected.contains($0.id) }
    managedAcknowledged = false
    showingManagedReview = !managedReview.isEmpty
  }
  func chooseArchiveSources() {
    let urls = choose(title: "选择归档来源", directories: true, files: true, multiple: true)
    if !urls.isEmpty {
      archiveSources = urls
      archiveCandidates = []
      archiveSelected = []
    }
  }
  func chooseArchiveDestination() {
    if let url = choose(title: "选择归档目标文件夹", directories: true).first { archiveDestination = url }
  }
  func startArchive() {
    guard let destination = archiveDestination, !archiveSources.isEmpty,
      let token = begin(
        ToolTaskPlan(kind: .archive, roots: archiveSources, destination: destination)), let relay
    else { return }
    let sources = archiveSources
    Task {
      do {
        let receipt = try await Task.detached(priority: .utility) {
          try ArchiveCopy.copy(
            sources: sources, destination: destination, cancellation: token,
            progressData: { relay.send($0) })
        }.value
        archives.insert(receipt, at: 0)
        save(archives, "archives.json")
        end(count: receipt.files.count, committed: true)
        message = "归档已校验，来源保留。"
      } catch {
        message = error.localizedDescription + "。来源未处理；如有未完成副本，会保留在目标的‘未完成’目录。"
        end(issues: [error.localizedDescription], failed: true)
      }
    }
  }
  func inspectArchive(_ receipt: ArchiveReceipt) {
    guard
      let token = begin(
        ToolTaskPlan(kind: .verifyArchive, roots: receipt.sourceRoots, archiveID: receipt.id))
    else { return }
    archiveCandidates = []
    archiveSelected = []
    archiveLimit = 100
    archiveGuards = [:]
    let home = self.home
    Task {
      do {
        let found = try await Task.detached(priority: .utility) {
          try ArchiveCopy.cleanupCandidates(receipt, home: home, cancellation: token)
        }.value
        archiveCandidates = found.0
        archiveGuards = found.1
        end(count: found.0.count)
        if found.0.isEmpty { message = "没有符合清理范围且仍与归档一致的来源文件" }
      } catch {
        message = error.localizedDescription
        end(issues: [error.localizedDescription], failed: true)
      }
    }
  }
  func refreshStartups() {
    guard let token = begin(ToolTaskPlan(kind: .startups)) else { return }
    let home = self.home
    let receipts = startupReceipts
    Task {
      let result = await Task.detached(priority: .utility) {
        StartupItems.collect(home: home, receipts: receipts, cancellation: token)
      }.value
      startups = result.0
      startupIssues = result.1
      end(count: result.0.count, issues: result.1)
    }
  }
  func changeStartup(_ entry: StartupEntry) {
    guard let token = begin(ToolTaskPlan(kind: .startupChange, roots: [entry.url])) else { return }
    startupAction = nil
    let home = self.home
    Task {
      do {
        let receipt = try await Task.detached(priority: .utility) {
          try StartupItems.set(
            entry, enabled: entry.disabledBySweep, home: home, cancellation: token)
        }.value
        startupReceipts.removeAll { $0.label == receipt.label && $0.path == receipt.path }
        startupReceipts.append(receipt)
        save(startupReceipts, "startup-items.json")
        end(count: 1, committed: true)
      } catch {
        message = error.localizedDescription
        end(issues: [error.localizedDescription], failed: true)
      }
      refreshStartups()
    }
  }
  func repeatTask(_ record: ToolTaskRecord) {
    guard !busy else { return }
    let plan = record.plan
    switch plan.kind {
    case .media:
      section = .resolve
      scanMedia(roots: plan.roots)
    case .duplicates:
      section = .duplicates
      findDuplicates(roots: plan.roots)
    case .archive:
      section = .archive
      archiveSources = plan.roots
      archiveDestination = plan.destination
      archiveCandidates = []
      archiveSelected = []
    case .verifyArchive:
      section = .archive
      if let receipt = archives.first(where: { $0.id == plan.archiveID }) {
        inspectArchive(receipt)
      } else {
        message = "归档记录已不存在"
      }
    case .applications:
      section = .applications
      refreshApplications()
    case .application:
      section = .applications
      if let app = plan.application { inspectApplication(app) }
    case .leftovers:
      section = .applications
      findLeftovers()
    case .startups:
      section = .startup
      refreshStartups()
    case .startupChange: section = .startup
    case .mediaDetails: section = .resolve
    }
  }
  func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
  func recordGrowth(_ snapshot: GrowthSnapshot, force: Bool = false) {
    if growth.snapshots.last?.date == snapshot.date
      && growth.snapshots.last?.coverage == snapshot.coverage
    {
      return
    }
    growth.record(snapshot, force: force)
    save(growth.snapshots, "growth-history.json")
  }
  var growthChanges: [GrowthChange] {
    guard let pair = growth.comparison(days: growthDays) else { return [] }
    return GrowthHistory.changes(from: pair.0, to: pair.1)
  }
  func recordMemory(_ snapshot: SystemSnapshot) {
    memoryTrend.record(snapshot)
    monitor?.update(snapshot)
  }
  func refreshMemoryMenu(_ snapshot: SystemSnapshot) { monitor?.update(snapshot) }
  private func configureMenu() {
    if menuEnabled {
      if monitor == nil {
        monitor = MemoryMenuMonitor(
          open: { [weak self] in self?.openMainWindow?() },
          disable: { [weak self] in self?.menuEnabled = false })
      }
    } else {
      monitor = nil
    }
  }
  func choose(title: String, directories: Bool, files: Bool = false, multiple: Bool = false)
    -> [URL]
  {
    guard !busy else { return [] }
    let panel = NSOpenPanel()
    panel.title = L(title)
    panel.canChooseDirectories = directories
    panel.canChooseFiles = files || !directories
    panel.allowsMultipleSelection = multiple
    panel.prompt = L("选择")
    panel.directoryURL = home
    return panel.runModal() == .OK ? panel.urls : []
  }
}
@MainActor final class MemoryMenuMonitor: NSObject {
  private let item: NSStatusItem
  private let open: () -> Void
  private let disable: () -> Void
  init(open: @escaping () -> Void, disable: @escaping () -> Void) {
    self.open = open
    self.disable = disable
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    item.button?.title = L("轻扫")
    update(SystemSnapshot.sample())
  }
  deinit { NSStatusBar.system.removeStatusItem(item) }
  func update(_ snapshot: SystemSnapshot) {
    item.button?.title = L("轻扫 · ") + L(snapshot.pressureLabel)
    let menu = NSMenu()
    for title in [
      "内存压力：" + snapshot.pressureLabel, "正在使用：" + formatBytes(snapshot.memoryUsed),
      "交换空间：" + formatBytes(snapshot.swap), "磁盘可用：" + formatBytes(snapshot.diskFree),
    ] { menu.addItem(NSMenuItem(title: L(title), action: nil, keyEquivalent: "")) }
    if snapshot.diskFree < 20_000_000_000 {
      menu.addItem(NSMenuItem(title: L("磁盘可用空间较少"), action: nil, keyEquivalent: ""))
    }
    menu.addItem(.separator())
    for app in snapshot.processes.prefix(3) {
      menu.addItem(
        NSMenuItem(title: app.name + " · " + formatBytes(app.bytes), action: nil, keyEquivalent: "")
      )
    }
    menu.addItem(.separator())
    let open = NSMenuItem(title: L("打开轻扫"), action: #selector(show), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    let off = NSMenuItem(title: L("关闭菜单栏监控"), action: #selector(turnOff), keyEquivalent: "")
    off.target = self
    menu.addItem(off)
    item.menu = menu
  }
  @objc private func show() {
    open()
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title.contains("轻扫") })?
      .makeKeyAndOrderFront(nil)
  }
  @objc private func turnOff() { disable() }
}
