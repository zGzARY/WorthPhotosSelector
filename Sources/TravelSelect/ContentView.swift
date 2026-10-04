import SwiftUI
#if SWIFT_PACKAGE
import PhotoCore
#endif

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var camera = CameraSource.shared
    @State private var comparison: ComparisonSelection?
    @State private var showDetails = false
    private var comparing: [PhotoRecord] {
        if !model.selectedIDs.isEmpty { return model.comparison }
        return model.currentGroup.map { group in Grouping.ordered(model.session.activeRecords.filter { group.members.contains($0.id) }) } ?? []
    }
    private var gridColumns: [GridItem] {
        let n = model.visibleRecords.count
        if model.queue == "groups", (2...4).contains(n) {
            return Array(repeating: GridItem(.flexible(), spacing: 18), count: n == 4 ? 2 : n)
        }
        return [GridItem(.adaptive(minimum: 235), spacing: 18)]
    }
    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 238, max: 290)
        } detail: {
            VStack(spacing: 0) {
                if model.reviewFinished { reviewComplete }
                else if model.session.activeRecords.isEmpty { welcome }
                else {
                    workspaceHeader
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 20) {
                            ForEach(model.visibleRecords) { record in photoCard(record) }
                        }.padding(24).id(model.previewRevision)
                    }
                    if model.queue == "groups", model.currentGroup != nil { reviewActions }
                }
                Divider()
                statusBar
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("择影 · WorthPhotos")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("从相机／存储卡筛选…") { model.connectCamera() }
                        Button("从「照片」App 选择…") { model.connectPhotos() }
                        Button("从文件夹选择…") { model.importFolder() }
                        if !model.savedSessions.isEmpty {
                            Menu("继续之前的选片") {
                                ForEach(model.savedSessions.filter { $0.id != model.session.id }) { saved in
                                    Button(saved.title + " · \(saved.count) 张") { model.restoreSession(saved) }
                                }
                            }
                        }
                        Divider()
                        Button("开始新的选片") { model.newSession() }
                    } label: { Label("选择照片", systemImage: "photo.badge.plus") }.labelStyle(.titleAndIcon).disabled(model.busy)
                    Button { comparison = ComparisonSelection(records: comparing) } label: {
                        Label("比较\(comparing.count >= 2 ? "（\(comparing.count)）" : "")", systemImage: "rectangle.split.2x1")
                    }.labelStyle(.titleAndIcon).disabled(comparing.count < 2)
                    Button { model.prepareOutput() } label: { Label(model.exportTitle, systemImage: "square.and.arrow.up") }
                        .labelStyle(.titleAndIcon).buttonStyle(.borderedProminent).disabled(!model.canExport)
                    moreMenu
                }
            }
        }
        .tint(.accentColor)
        .inspector(isPresented: $showDetails) {
            ScrollView {
                if let record = model.comparison.first ?? model.visibleRecords.first {
                    ComparisonPane(record: record, analysis: model.session.analyses[record.id],
                                   recommendation: model.session.recommendations[record.id], allowNetwork: model.allowNetwork,
                                   imageHeight: 220, detailsInitiallyExpanded: true).padding(18)
                } else { ContentUnavailableView("选择一张照片查看详情", systemImage: "info.circle") }
            }.inspectorColumnWidth(min: 290, ideal: 320, max: 380)
        }
        .alert("择影 · WorthPhotos", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("知道了") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .sheet(isPresented: $model.showPhotos, onDismiss: { model.maybeOfferCalibration() }) { PhotosPicker(model: model) }
        .sheet(isPresented: $model.showSettings) { SelectionSettingsView(model: model) }
        .sheet(item: $comparison) { selection in
            ComparisonView(records: selection.records, analyses: model.session.analyses,
                           recommendations: model.session.recommendations, allowNetwork: model.allowNetwork)
        }
        .sheet(item: $model.calibration, onDismiss: { if model.session.calibratedScopeKey != model.session.scopeKey { model.skipCalibration() } }) { draft in
            CalibrationView(model: model, draft: draft)
        }
        .sheet(item: $model.outputDraft) { draft in OutputView(model: model, draft: draft) }
        .sheet(item: $model.outputResult) { result in OutputResultView(model: model, result: result) }
        .sheet(isPresented: $model.showCamera) { CameraPicker(model: model) }
        .task { model.maybeOfferCalibration() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "photo.stack.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("择影 · WorthPhotos").font(.headline)
                    Text("留住值得留下的瞬间").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.top, 18)
            Picker("显示分组", selection: $model.groupFilter) {
                Text("全部相似组").tag("all")
                Text("值得我选").tag("attention")
                Text("已确认").tag("reviewed")
            }.labelsHidden().padding(.horizontal, 16)
            List {
                ForEach(Array(model.filteredGroups.enumerated()), id: \.element.id) { index, group in
                    HStack(spacing: 8) {
                        if model.mergeMode {
                            Button {
                                if model.mergeIDs.contains(group.id) { model.mergeIDs.remove(group.id) } else { model.mergeIDs.insert(group.id) }
                            } label: { Image(systemName: model.mergeIDs.contains(group.id) ? "checkmark.circle.fill" : "circle") }.buttonStyle(.plain)
                        }
                        Button { model.chooseGroup(group.id) } label: {
                            HStack(spacing: 10) {
                                if let record = model.record(group.members.first(where: { model.session.recommendations[$0]?.selected == true }) ?? group.members[0]) {
                                    PhotoThumbnail(record: record, allowNetwork: model.allowNetwork)
                                        .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 7))
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("第 \((model.session.reviewGroups.firstIndex(where: { $0.id == group.id }) ?? index) + 1) 组").font(.callout.weight(.medium))
                                    Text("\(group.members.count) 张照片").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if group.members.allSatisfy({ (model.session.decisions[$0]?.choice ?? .unreviewed) != .unreviewed }) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).font(.caption)
                                }
                            }.padding(.vertical, 3).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }.listRowBackground(model.selectedGroupID == group.id && model.queue == "groups" ? Color.accentColor.opacity(0.12) : Color.clear)
                }
            }.listStyle(.sidebar)
            if model.mergeMode {
                HStack {
                    Button("合并 \(model.mergeIDs.count) 组") { model.merge(); model.mergeMode = false }.disabled(model.mergeIDs.count < 2 || model.busy)
                    Button("完成") { model.mergeMode = false; model.mergeIDs = [] }
                }.padding(.horizontal, 14)
            }
            VStack(spacing: 4) {
                queueButton("全部照片", icon: "square.grid.2x2", queue: "all", count: model.session.activeRecords.count)
                queueButton("独立照片", icon: "photo", queue: "unmatched", count: model.session.unmatchedRecords.count)
                queueButton("尚待处理", icon: "clock", queue: "issues", count: model.selectionPlan.unresolvedIDs.count)
            }.padding(.horizontal, 12).padding(.bottom, 14)
        }
    }
    private func queueButton(_ title: String, icon: String, queue: String, count: Int) -> some View {
        Button { model.queue = queue; model.selectedIDs = []; model.reviewFinished = false } label: {
            HStack { Label(title, systemImage: icon); Spacer(); Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
                .font(.callout).padding(8).background(model.queue == queue ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
    }
    private var welcome: some View {
        VStack(spacing: 22) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(.tint)
            VStack(spacing: 10) {
                Text("相似的瞬间，留下最喜欢的").font(.system(size: 28, weight: .semibold))
                Text("选择照片，比较推荐，再生成一个属于你的精选相册。").foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Button("连接相机／存储卡") { model.connectCamera() }.buttonStyle(.borderedProminent)
                Button("从「照片」App 选择") { model.connectPhotos() }.buttonStyle(.bordered)
                Button("选择文件夹") { model.importFolder() }.buttonStyle(.bordered)
            }.controlSize(.large).disabled(model.busy)
            Text("本机分析 · 原照片保持不变").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var reviewComplete: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle").font(.system(size: 48, weight: .light)).foregroundStyle(.tint)
            Text("这一轮选片完成").font(.title2.weight(.semibold))
            Text("精选 \(model.selectionPlan.keepIDs.count) 张 · \(model.selectionPlan.unresolvedIDs.count) 张尚待处理").foregroundStyle(.secondary)
            HStack {
                if !model.selectionPlan.unresolvedIDs.isEmpty { Button("返回待复核照片") { model.resumeDeferred() } }
                Button(model.exportTitle) { model.prepareOutput() }.buttonStyle(.borderedProminent).disabled(!model.canExport)
            }
            Button("撤销上次选择") { model.undo() }.disabled(!model.canUndo)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.queue == "groups" ? "这一组，留哪张？" : model.queue == "unmatched" ? "独立的瞬间" : model.queue == "issues" ? "还有一些照片需要处理" : "你的照片")
                        .font(.system(size: 24, weight: .semibold))
                    Text("\(model.visibleRecords.count) 张 · " + model.session.sourceTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !model.selectedIDs.isEmpty {
                    Button("清空选择（\(model.selectedIDs.count)）") { model.selectedIDs = [] }.font(.caption)
                } else if model.queue == "groups" {
                    Button("全选本组") { model.selectedIDs = Set(model.currentGroup?.members ?? []) }.font(.caption)
                }
                Button { showDetails.toggle() } label: { Image(systemName: "sidebar.right") }.help("照片与推荐详情")
            }
            if model.session.source == .photos && !PhotoAccess.canRead {
                HStack {
                    Text("连接「照片」后即可查看这些照片").font(.callout)
                    Button("连接「照片」") { model.connectPhotos(showPicker: false) }.disabled(model.requestingPhotosAccess)
                    if model.requestingPhotosAccess { Text("请在系统提示中确认访问").font(.caption) }
                }.foregroundStyle(.secondary)
            }
            if model.session.settings.mode != .exact {
                HStack(spacing: 12) {
                    Text("分组").font(.caption).foregroundStyle(.secondary)
                    Picker("分组精细程度", selection: Binding(get: { model.session.settings.groupingLevel ?? .precise }, set: model.setGroupingLevel)) {
                        ForEach(GroupingLevel.allCases, id: \.self) { level in Text(level.label).tag(level) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 340).disabled(model.busy || model.refiningGroup)
                    if model.regrouping { ProgressView().controlSize(.small); Text("正在调整分组").font(.caption).foregroundStyle(.secondary) }
                    else { Text("\(model.session.reviewGroups.count) 组").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }
            }
            if model.session.source == .camera {
                HStack {
                    Text(model.session.cameraSource?.transport == .ptp ? camera.status : "直接读取存储卡 · 确认后仅导入精选原片").font(.caption).foregroundStyle(.secondary)
                    if model.session.cameraSource?.transport == .ptp && !camera.connected { Button("重新连接") { model.connectCamera() }.disabled(model.busy) }
                    if model.refiningGroup { ProgressView().controlSize(.small); Text("正在读取本组原片细节").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let group = model.currentGroup, model.queue == "groups" {
                if group.needsReview || group.members.contains(where: { model.session.staleIDs.contains($0) }) {
                    HStack { Label("这组照片有变化，请重新确认", systemImage: "arrow.triangle.2.circlepath"); Button("已复核") { model.confirmReview() }.disabled(model.busy) }.font(.caption).foregroundStyle(.orange)
                } else if let id = group.members.first(where: { model.session.recommendations[$0]?.selected == true }), let rec = model.session.recommendations[id] {
                    Label(rec.reason, systemImage: rec.needsJudgment ? "hand.tap" : "sparkles")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let notice = model.calibrationNotice {
                HStack { Text(notice).font(.caption).foregroundStyle(.secondary); Spacer(); Button { model.calibrationNotice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            }
        }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 4)
    }
    private func photoCard(_ record: PhotoRecord) -> some View {
        let selected = model.selectedIDs.contains(record.id)
        let decision = model.session.decisions[record.id] ?? Decision()
        let recommended = model.session.recommendations[record.id]?.selected == true
        return Button { model.toggleSelection(record.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                PhotoThumbnail(record: record, allowNetwork: model.allowNetwork)
                    .frame(height: model.queue == "groups" && model.visibleRecords.count <= 4 ? 310 : 210)
                    .overlay(alignment: .topTrailing) {
                        if selected { Image(systemName: "checkmark.circle.fill").font(.title2).symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor).padding(10) }
                    }
                HStack(spacing: 6) {
                    Text(record.name).lineLimit(1).font(.callout.weight(.medium))
                    Spacer(minLength: 4)
                    if decision.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tint) }
                    if decision.choice == .keep || decision.locked { Text("已保留").foregroundStyle(.tint).font(.caption.weight(.medium)) }
                    else if decision.choice == .exclude { Text("不保留").font(.caption).foregroundStyle(.secondary) }
                    else if model.session.deferredIDs?.contains(record.id) == true { Text("待复核").font(.caption).foregroundStyle(.secondary) }
                    else if recommended { Text("建议保留").font(.caption.weight(.medium)).foregroundStyle(.tint) }
                }.padding(12)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: selected ? 2 : 1))
        }.buttonStyle(.plain)
        .highPriorityGesture(TapGesture(count: 2).onEnded { comparison = ComparisonSelection(records: [record]) })
        .contextMenu {
            Button("放大查看") { comparison = ComparisonSelection(records: [record]) }
            Button("保留这张") { model.selectedIDs = [record.id]; model.decide(.keep) }
            Button("不保留这张") { model.selectedIDs = [record.id]; model.decide(.exclude) }
        }
        .accessibilityLabel(record.name + (recommended ? "，建议保留" : "") + (selected ? "，已选中" : ""))
    }
    private var reviewActions: some View {
        HStack(spacing: 12) {
            Button("保留所选") { model.decide(.keep) }.disabled(model.selectedIDs.isEmpty)
            Button("不保留所选") { model.decide(.exclude) }.disabled(model.selectedIDs.isEmpty)
            Spacer()
            Button("稍后处理") { model.nextGroup() }
            Button(model.groupActionTitle, systemImage: "arrow.right") { model.acceptGroup() }.buttonStyle(.borderedProminent).disabled(!model.canAcceptGroup)
        }.disabled(model.busy || model.regrouping).padding(.horizontal, 24).padding(.vertical, 14)
    }
    private var statusBar: some View {
        HStack(spacing: 12) {
            if model.busy {
                if model.total > 0 {
                    ProgressView(value: Double(model.progress), total: Double(model.total)).frame(width: 100)
                    Text("\(model.progress)/\(model.total)").monospacedDigit()
                } else { ProgressView().controlSize(.small) }
                Text(model.phase).lineLimit(1)
                if model.canCancelWork { Button("停止") { model.cancel() } }
            } else {
                Text("精选 \(model.selectionPlan.keepIDs.count) 张 · 待整理 \(model.selectionPlan.unselectedIDs.count) 张")
                if !model.selectionPlan.unresolvedIDs.isEmpty { Text("\(model.selectionPlan.unresolvedIDs.count) 张尚待处理") }
                Spacer()
                if model.session.groupingComplete != true && !model.session.activeRecords.isEmpty { Button("继续分析") { model.analyze() } }
                else if let preference = model.session.preference { Text(preference.strategy.label) }
                else { Text("本机分析") }
            }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 11)
    }
    private var moreMenu: some View {
        Menu {
            Button("选片偏好与设置…") { model.showSettings = true }
            Button("用几组照片校准偏好…") { model.startCalibration() }.disabled(model.busy || model.session.groupingComplete != true)
            Button("照片详情") { showDetails.toggle() }
            Divider()
            Button("撤销上次选择") { model.undo() }.disabled(!model.canUndo || model.busy)
            Button("锁定保留所选") { model.lockSelected() }.disabled(model.selectedIDs.isEmpty || model.busy)
            Button("解除所选保护锁") { model.unlockSelected() }.disabled(model.selectedIDs.isEmpty || model.busy)
            Button("所选恢复待复核") { model.decide(.unreviewed) }.disabled(model.selectedIDs.isEmpty || model.busy)
            Menu("调整分组") {
                Button("拆出所选照片") { model.split() }.disabled(model.selectedIDs.isEmpty)
                Button("选择要合并的组") { model.mergeMode = true }
                Button("只比较所选照片") { model.regroup(visualSelection: true) }.disabled(model.selectedIDs.count < 2)
                Button("整组保留") { model.keepGroup() }
            }.disabled(model.busy)
            Divider()
            if model.session.source == .photos { Button("刷新照片范围") { model.refreshPhotos() }.disabled(model.busy) }
            Button("继续分析") { model.analyze() }.disabled(model.busy || model.session.activeRecords.isEmpty)
            Button("重新分析") { model.analyze(force: true) }.disabled(model.busy || model.session.activeRecords.isEmpty)
            Button("导出选择清单…") { model.exportManifest() }.disabled(model.busy || model.session.activeRecords.isEmpty)
            if model.session.pendingAlbumToken != nil { Button(model.session.source == .photos ? "核对上次相册" : "继续上次导入") { model.reconcilePendingOutput() }.disabled(model.busy) }
        } label: { Image(systemName: "ellipsis.circle") }.help("更多操作")
    }
}
