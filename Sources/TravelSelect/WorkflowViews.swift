import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import PhotoCore
#endif

struct OutputView: View {
    @ObservedObject var model: AppModel
    let draft: OutputDraft
    @State private var name: String
    @State private var destination: OutputDestination
    @State private var includeUnselected = false
    @State private var showList = false
    @State private var listCategory = SelectionDisposition.keep
    init(model: AppModel, draft: OutputDraft) {
        self.model = model; self.draft = draft; _name = State(initialValue: draft.defaultName)
        _destination = State(initialValue: draft.defaultDestination)
    }
    private var photos: Bool { destination == .photos }
    private var importsOriginals: Bool { photos && draft.session.source != .photos }
    private var originalSize: String? {
        let ids = Set(draft.plan.keepIDs)
        let records = draft.session.activeRecords.filter { ids.contains($0.id) }
        guard records.allSatisfy({ $0.byteSize != nil }) else { return nil }
        return ByteCountFormatter.string(fromByteCount: records.reduce(0) { $0 + ($1.byteSize ?? 0) }, countStyle: .file)
    }
    private var copyCount: Int { draft.copyRequiredIDs.intersection(Set(draft.plan.keepIDs + (includeUnselected ? draft.plan.unselectedIDs : []))).count }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: photos ? "photo.stack.fill" : "folder.fill").font(.system(size: 34, weight: .light)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(draft.resume?.recreateAlbum == true ? "重新导出精选照片" : draft.resume != nil ? "继续导入精选照片" : photos ? "把选好的照片放进新相册" : "把选好的照片保存到新文件夹").font(.title2.weight(.semibold))
                    Text(draft.resume?.recreateAlbum == true ? "旧相册已移除，创建新相册并核对已有照片" : draft.resume != nil ? "沿用原相册，先核对已完成照片" : photos ? "新相册会出现在「照片」App 中" : "下一步选择保存位置，原照片保持原位").font(.callout).foregroundStyle(.secondary)
                }
            }
            if draft.session.source == .folder {
                Picker("保存到", selection: $destination) {
                    Text("文件夹").tag(OutputDestination.folder)
                    Text("「照片」图库").tag(OutputDestination.photos)
                }.pickerStyle(.segmented)
            }
            TextField(photos ? "相册名称" : "文件夹名称", text: $name).textFieldStyle(.roundedBorder).disabled(draft.resume != nil && draft.resume?.recreateAlbum != true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(draft.plan.keepIDs.count)").font(.system(size: 38, weight: .light, design: .rounded)).monospacedDigit().foregroundStyle(.tint)
                Text("张精选照片").font(.headline)
                Spacer()
                Text("人工选择与保护锁优先").font(.caption).foregroundStyle(.secondary)
            }
            if !importsOriginals { Toggle(isOn: $includeUnselected) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(photos ? "同时创建「待整理」相册" : "同时创建「待整理」文件夹")
                    Text("收集其余已完成筛选的 \(draft.plan.unselectedIDs.count) 张照片").font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(draft.plan.unselectedIDs.isEmpty) }
            let confirmed = draft.plan.entries.filter { $0.disposition == .keep && ($0.origin == .manual || $0.origin == .protected) }.count
            Text("已确认 \(confirmed) 张 · 推荐及独立照片 \(draft.plan.keepIDs.count - confirmed) 张").font(.caption).foregroundStyle(.secondary)
            if let resume = draft.resume {
                VStack(alignment: .leading, spacing: 5) {
                    if resume.recreateAlbum {
                        Text("原记录包含 \(resume.completed) 张：仍在图库中的核对后复用，已删除的从来源重新导入。")
                    } else { Text("记录已完成 \(resume.completed) 张 · 核对后续传 \(draft.plan.keepIDs.count - resume.completed) 张") }
                    if !resume.added.isEmpty { Text("新增：" + resume.added.joined(separator: "、")) }
                    if !resume.removed.isEmpty { Text("取消：" + resume.removed.joined(separator: "、")) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            if !draft.plan.groupingComplete {
                Text("分析尚未全部完成；本次只输出你已确认保留的照片，其余留待处理。").font(.caption).foregroundStyle(.secondary)
            }
            if importsOriginals {
                Text("仅导入以上精选原文件" + (originalSize.map { "，共约 " + $0 } ?? "") + "。RAW＋JPEG 配对会一起保存，原片继续保留在来源设备上。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !draft.plan.unresolvedIDs.isEmpty {
                Label("还有 \(draft.plan.unresolvedIDs.count) 张未完成分析或需要复核，本次不自动整理。", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
            }
            if copyCount > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    Text("其中 \(copyCount) 张来自共享相册，将先保存副本到个人图库。").font(.callout)
                    Text("保留共享相册中可取得的画质。副本会占用空间；共享照片的画质可能低于拍摄原片。").font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("查看照片清单", isExpanded: $showList) {
                if showList {
                    VStack(spacing: 10) {
                        Picker("清单", selection: $listCategory) {
                            Text("精选").tag(SelectionDisposition.keep)
                            Text("待整理").tag(SelectionDisposition.unselected)
                            Text("尚待处理").tag(SelectionDisposition.unresolved)
                        }.pickerStyle(.segmented)
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(draft.plan.entries.filter { $0.disposition == listCategory }) { entry in
                                    HStack {
                                        Text(draft.session.records.first { $0.id == entry.id }?.name ?? "照片").lineLimit(1)
                                        Spacer()
                                        Text(entry.reason).foregroundStyle(.secondary).lineLimit(1)
                                    }.font(.caption).padding(.vertical, 6)
                                    Divider()
                                }
                            }
                        }.frame(height: 170)
                    }.padding(.top, 12)
                }
            }.font(.callout)
            Text(importsOriginals ? "原片会保存到系统照片图库中的\(draft.resume == nil || draft.resume?.recreateAlbum == true ? "新" : "原")相册。未入选和待复核照片不导入。" : photos ? "原照片和原相册保持不变。加入新相册不会删除或移动照片，也不会释放空间。" : "复制原始文件，不覆盖或移走来源照片。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { model.outputDraft = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(draft.resume?.recreateAlbum == true ? "创建新相册并重新导出" : draft.resume != nil ? "更新清单并继续导入" : importsOriginals ? "导入精选原片" : photos ? "创建相册" : "选择保存位置…") { model.performOutput(draft, name: name, includeUnselected: importsOriginals ? false : includeUnselected, destination: destination) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            }
        }.padding(30).frame(width: 590)
    }
}

struct OutputResultView: View {
    @ObservedObject var model: AppModel
    let result: OutputResult
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: result.isComplete ? "checkmark.circle" : "exclamationmark.circle").font(.system(size: 48, weight: .light)).foregroundStyle(result.isComplete ? Color.accentColor : .orange)
            Text(result.title).font(.title2.weight(.semibold))
            Text(result.summary).multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(spacing: 7) { ForEach(result.names, id: \.self) { Text($0).font(.headline).textSelection(.enabled) } }
            if result.isPhotos { Text("在「照片」App 的相册列表中查看以上相册。").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("完成") { model.outputResult = nil }.keyboardShortcut(.cancelAction)
                Button(result.isPhotos ? "打开「照片」" : "打开结果文件夹") {
                    if result.isPhotos { model.openPhotos() }
                    else if let folder = result.folder { NSWorkspace.shared.open(folder) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(34).frame(width: 520)
    }
}

struct CalibrationView: View {
    @ObservedObject var model: AppModel
    let draft: CalibrationDraft
    @State private var index = 0
    @State private var roundCount: Int
    @State private var preferred: String?
    @State private var answers: [CalibrationAnswer] = []
    @State private var sameSubject = false
    @State private var scopeSameSubject: Bool
    @State private var remember = true
    @State private var enlarged: PhotoRecord?
    init(model: AppModel, draft: CalibrationDraft) {
        self.model = model; self.draft = draft
        _roundCount = State(initialValue: draft.groups.count)
        _scopeSameSubject = State(initialValue: draft.session.scopeHasSameSubject)
        _sameSubject = State(initialValue: draft.groups.first?.samePersonConfirmed ?? false)
    }
    private var group: PhotoGroup { draft.groups[index] }
    private var records: [PhotoRecord] { Grouping.ordered(draft.session.activeRecords.filter { group.members.contains($0.id) }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("这一组，你更喜欢哪张？").font(.title2.weight(.semibold))
                    Text("第 \(index + 1) / \(roundCount) 组 · 选择会保留到本次结果，评分取舍会根据有效答案调整。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if index == 0 && draft.groups.count > 1 {
                    Picker("选择几组", selection: $roundCount) {
                        Text("选 1 组").tag(1)
                        Text("选 \(draft.groups.count) 组").tag(draft.groups.count)
                    }.pickerStyle(.segmented).frame(width: 180)
                }
                Button("稍后再选") { model.skipCalibration() }.keyboardShortcut(.cancelAction)
            }
            GeometryReader { geometry in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: ComparisonLayout.columnCount(count: records.count, width: geometry.size.width)), spacing: 22) {
                        ForEach(records) { record in
                            VStack(spacing: 12) {
                                ComparisonPane(record: record, analysis: nil, allowNetwork: model.allowNetwork,
                                               imageHeight: records.count <= 3 ? 320 : 250, allowDetails: false)
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { enlarged = record })
                                Button(preferred == record.id ? "已选择这张" : "更喜欢这张") { preferred = record.id }
                                    .buttonStyle(.bordered).tint(preferred == record.id ? .accentColor : .secondary)
                            }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(preferred == record.id ? Color.accentColor : .clear, lineWidth: 2))
                        }
                    }.padding(2)
                }
            }
            if PhotoRanking.hasComparableFaces(group, in: draft.session) {
                Toggle("这组照片中的人物是同一个人", isOn: $sameSubject).disabled(scopeSameSubject)
                    .font(.callout)
            }
            DisclosureGroup("偏好的适用范围") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("本次范围内的单人照片都是同一位主角", isOn: $scopeSameSubject)
                    Text("确认同一人物后，才比较人脸拍摄质量；多人照和未确认的组继续按整体画面排序。此确认只用于本次照片范围。").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.font(.caption)
            HStack(spacing: 16) {
                Toggle("保存为下次的偏好", isOn: $remember).font(.caption)
                Spacer()
                Button("跳过这组") { advance(.skipped) }
                Button("差不多") { advance(.indifferent) }
                Button(index + 1 == roundCount ? "完成选择" : "下一组") { advance(.preferred) }
                    .buttonStyle(.borderedProminent).disabled(preferred == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 1120, height: 760)
        .sheet(item: $enlarged) { record in
            ComparisonView(records: [record], analyses: [:], recommendations: [:], allowNetwork: model.allowNetwork, allowDetails: false)
        }
    }
    private func advance(_ response: CalibrationResponse) {
        let answer = CalibrationAnswer(group: group, records: records, preferredID: response == .preferred ? preferred : nil,
                                       response: response, sameSubject: sameSubject || scopeSameSubject)
        answers.append(answer)
        if index + 1 >= roundCount {
            model.finishCalibration(draft, answers: answers, sameSubjectScope: scopeSameSubject, remember: remember)
        } else {
            index += 1; preferred = nil; sameSubject = draft.groups[index].samePersonConfirmed
        }
    }
}

struct SelectionSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var groupingSettings: AnalysisSettings
    init(model: AppModel) { self.model = model; _groupingSettings = State(initialValue: model.session.settings) }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("选片偏好与设置").font(.title2.weight(.semibold)); Spacer(); Button("完成") { model.showSettings = false }.keyboardShortcut(.cancelAction) }.padding(22)
            Form {
                Section("选片偏好") {
                    LabeledContent("当前取舍", value: model.session.preference?.strategy.label ?? "整体画面优先")
                    Toggle("每次选择新范围后询问偏好", isOn: $model.preferences.askEveryScope).onChange(of: model.preferences.askEveryScope) { _, _ in model.savePreferences() }
                    HStack {
                        Button("用几组照片重新校准") {
                            model.showSettings = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.startCalibration() }
                        }.disabled(model.busy || model.session.groupingComplete != true)
                        Button("恢复默认偏好") { model.resetPreferences() }.disabled(model.busy)
                    }
                    Toggle("本次范围的单人照片为同一主角", isOn: Binding(get: { model.session.scopeHasSameSubject }, set: model.setScopeSameSubject)).disabled(model.busy || model.session.activeRecords.isEmpty)
                    if let group = model.currentGroup {
                        Toggle("当前这一组是同一个人", isOn: Binding(get: { group.samePersonConfirmed }, set: model.confirmSamePerson)).disabled(model.busy)
                    }
                    Text("偏好只调整整体画面与人脸拍摄质量的取舍，不代表已经学会完整审美。人物确认只用于当前范围。").font(.caption).foregroundStyle(.secondary)
                }
                Section("分组与推荐") {
                    Picker("每种相近画面推荐", selection: $model.session.settings.recommendationCount) { Text("1 张").tag(1); Text("2 张").tag(2) }
                        .onChange(of: model.session.settings.recommendationCount) { _, _ in model.refreshRecommendations() }
                    Picker("分组方式", selection: $groupingSettings.mode) {
                        Text("相似画面与自动拍摄时间").tag(GroupMode.scene)
                        if model.session.source == .folder { Text("文件完全相同").tag(GroupMode.exact) }
                    }
                    if groupingSettings.mode != .exact {
                        Picker("分组精细程度", selection: Binding(get: { groupingSettings.groupingLevel ?? .precise }, set: { groupingSettings.groupingLevel = $0 })) {
                            ForEach(GroupingLevel.allCases, id: \.self) { level in Text(level.label).tag(level) }
                        }.pickerStyle(.segmented)
                        Text("拍摄时间自动辅助分组；较大的场景中，每种相近画面分别推荐。切换档位复用已有分析。").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("应用分组设置") {
                        model.session.settings.mode = groupingSettings.mode
                        model.showSettings = false
                        if groupingSettings.mode == .exact { model.regroup() }
                        else { model.setGroupingLevel(groupingSettings.groupingLevel ?? .precise) }
                    }.disabled(model.session.activeRecords.isEmpty)
                }.disabled(model.busy)
                if model.session.source == .photos {
                    Section("照片来源") {
                        Toggle("允许从 iCloud 下载后在本机分析", isOn: $model.allowNetwork).disabled(model.busy)
                        Text("开启后可处理尚未下载的照片；不会上传照片。此开关不控制「照片」App 自身的同步。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
        }.frame(width: 590, height: 650)
    }
}
