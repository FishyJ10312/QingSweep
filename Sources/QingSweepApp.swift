import SwiftUI
import AppKit

@main struct QingSweepApp: App {
    @NSApplicationDelegateAdaptor(QingSweepApplicationDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("轻扫 · 磁盘与内存", id: "main") {
            ContentView().environmentObject(model).onAppear { delegate.model = model }
        }.defaultSize(width: 1360, height: 760)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandMenu("扫描") {
                    Button("重新扫描", action: model.rescan).keyboardShortcut("r", modifiers: .command).disabled(model.busy)
                    Button("扫描个人大文件", action: model.personalScan).disabled(model.busy)
                    Button("选择文件夹…", action: model.chooseFolder).keyboardShortcut("o", modifiers: .command).disabled(model.busy)
                    Divider()
                    Button("停止扫描", action: model.cancelScan).disabled(!model.scanning)
                }
            }
    }
}
