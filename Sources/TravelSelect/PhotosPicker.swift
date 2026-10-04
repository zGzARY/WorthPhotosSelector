import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import PhotoCore
#endif

struct PhotosPicker: View {
    @ObservedObject var model: AppModel
    @State private var albumID: String
    @State private var useDates: Bool
    @State private var from: Date
    @State private var through: Date
    @State private var timeZoneID: String
    @State private var count: Int?
    @State private var countError: String?
    @State private var counting = false

    init(model: AppModel) {
        self.model = model
        let scope = model.session.photosScope
        _albumID = State(initialValue: scope?.albumID ?? "")
        _useDates = State(initialValue: scope == nil || scope?.startDate != nil)
        _from = State(initialValue: scope?.startDate ?? Calendar.current.date(byAdding: .day, value: -7, to: Date())!)
        _through = State(initialValue: scope?.endDateExclusive?.addingTimeInterval(-1) ?? Date())
        _timeZoneID = State(initialValue: scope?.timeZoneIdentifier ?? TimeZone.current.identifier)
    }
    private var scope: PhotosScope? {
        let title = model.albums.first { $0.id == albumID }?.title ?? model.session.photosScope?.albumTitle
        if useDates {
            return try? PhotosScope.days(albumID: albumID.isEmpty ? nil : albumID, albumTitle: title,
                                        from: from, through: through, timeZone: TimeZone(identifier: timeZoneID) ?? .current)
        }
        return try? PhotosScope(albumID: albumID.isEmpty ? nil : albumID, albumTitle: title, timeZoneIdentifier: timeZoneID)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("选择照片范围").font(.title2.bold())
            Text(model.photosStatus).foregroundStyle(.secondary)
            Group {
                Picker("图库／相册", selection: $albumID) {
                    Text("系统图库").tag("")
                    if let saved = model.session.photosScope, let id = saved.albumID,
                       !model.albums.contains(where: { $0.id == id }) {
                        Text(saved.albumTitle ?? "上次所选相册").tag(id)
                    }
                    ForEach(model.albums) { Text($0.title).tag($0.id) }
                }
                Toggle("按日期筛选", isOn: $useDates)
                if useDates {
                    DatePicker("开始日期", selection: $from, displayedComponents: .date)
                    DatePicker("结束日期（包含当天）", selection: $through, displayedComponents: .date)
                    Text("日期时区：\(timeZoneID)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(albumID.isEmpty ? "当前为系统图库的全部日期。" : "当前为所选相册的全部日期。").font(.caption).foregroundStyle(.secondary)
                }
                if scope == nil { Text("结束日期不能早于开始日期。").foregroundStyle(.red) }
                if !PhotoAccess.canRead { Text("完成系统授权后显示匹配数量和可选相册。").font(.caption).foregroundStyle(.secondary) }
                if counting { HStack { ProgressView().controlSize(.small); Text("正在核对符合条件的照片…") } }
                else if let count { Text("符合所选范围：\(count) 张照片").font(.headline) }
                else if let countError { Text(countError).font(.caption).foregroundStyle(.orange) }
                Toggle("允许从 iCloud 下载后在本机分析", isOn: $model.allowNetwork)
                Text("相册与日期共同生效。应用后自动分析和分组；只处理照片，包含连拍成员。下载开关不控制「照片」App 的同步。").font(.caption).foregroundStyle(.secondary)
            }
            if !PhotoAccess.canRead {
                if model.requestingPhotosAccess { ProgressView("等待 macOS 授权…").controlSize(.small) }
                Button("打开照片隐私设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!) }
                Button("重新检查授权") { model.connectPhotos() }.disabled(model.requestingPhotosAccess)
            }
            HStack {
                Button("取消") { model.showPhotos = false }
                Spacer()
                Button("开始选片") { if let scope { model.importPhotos(scope: scope) } }
                    .buttonStyle(.borderedProminent).disabled(!PhotoAccess.canRead || scope == nil || counting || count == nil)
            }
        }
        .padding(26).frame(width: 550)
        .environment(\.timeZone, TimeZone(identifier: timeZoneID) ?? .current)
        .task(id: "\(scope?.hashValue ?? 0)|\(model.photosStatus)") {
            count = nil; countError = nil
            guard let scope, PhotoAccess.canRead else { counting = false; return }
            counting = true
            do {
                try await Task.sleep(for: .milliseconds(200))
                let value = try await Task.detached { try PhotoLibrarySource.shared.count(scope: scope) }.value
                try Task.checkCancellation()
                count = value; counting = false
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                countError = error.localizedDescription; counting = false
            }
        }
    }
}
