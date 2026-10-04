import SwiftUI
#if SWIFT_PACKAGE
import PhotoCore
#endif

@main
struct TravelSelectApp: App {
    @StateObject private var model = TravelSelectApp.makeModel()
    private static func makeModel() -> AppModel {
        #if DEBUG
        // A separately named debug build isolates UI acceptance work from the real session.
        if Bundle.main.bundleURL.lastPathComponent == "TravelSelect-Preview.app" {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TravelSelect-Preview-" + String(stableID(Bundle.main.bundlePath).prefix(8)))
            let file = dir.appendingPathComponent("session.json")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path), let seed = Bundle.main.url(forResource: "PreviewSession", withExtension: "json") { try FileManager.default.copyItem(at: seed, to: file) }
                return AppModel(sessionFile: file)
            } catch { return AppModel(sessionFile: file) }
        }
        #endif
        return AppModel()
    }
    var body: some Scene {
        WindowGroup("择影 · WorthPhotos") { ContentView(model: model).frame(minWidth: 1100, minHeight: 720) }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("选择文件夹…") { model.importFolder() }.keyboardShortcut("o")
                Button("新建筛选会话") { model.newSession() }.disabled(model.busy)
            }
            CommandGroup(replacing: .appSettings) {
                Button("选片偏好与设置…") { model.showSettings = true }.keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) {
                Button("从相机／存储卡筛选…") { model.connectCamera() }.disabled(model.busy)
                Button("从「照片」App 选择…") { model.connectPhotos() }.disabled(model.busy)
                Button(model.exportTitle + "…") { model.prepareOutput() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!model.canExport)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { model.undoFromMenu() }.keyboardShortcut("z")
            }
            CommandMenu("照片复核") {
                Button("确认保留") { model.photoShortcut { model.decide(.keep) } }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("不保留所选") { model.photoShortcut { model.decide(.exclude) } }.keyboardShortcut("j", modifiers: [.command, .shift])
                Button("待复核") { model.photoShortcut { model.decide(.unreviewed) } }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("锁定保留") { model.photoShortcut { model.lockSelected() } }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("稍后处理") { model.photoShortcut { model.nextGroup() } }.keyboardShortcut("]", modifiers: [.command])
            }
        }
    }
}
