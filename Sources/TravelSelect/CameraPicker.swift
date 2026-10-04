import SwiftUI
#if SWIFT_PACKAGE
import PhotoCore
#endif

struct CameraPicker: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var camera = CameraSource.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("从相机直接选片", systemImage: "camera").font(.title2.weight(.semibold))
            Text("先看预览并选择，确认后只把精选原片导入「照片」。").foregroundStyle(.secondary)
            ForEach(camera.devices) { device in
                HStack(spacing: 14) {
                    Image(systemName: "camera.fill").font(.title)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name).font(.headline)
                        Text("USB 相机 · 原片保持原位").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.session.cameraSource?.id == device.id && !model.session.activeRecords.isEmpty ? "重连并恢复选片" : "开始选片") { model.selectCamera(device) }.buttonStyle(.borderedProminent)
                }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
            Text(camera.status).font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("存储卡或外接相机文件夹").font(.headline)
                    Text("如果能在 Finder 中看到存储卡，直接选择其中的照片文件夹。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("选择文件夹…") { model.importStorage() }
            }
            HStack {
                Button("关闭") { model.showCamera = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("刷新设备") { camera.refreshDevices() }
            }
        }.padding(30).frame(width: 590).task { camera.discover() }
    }
}
