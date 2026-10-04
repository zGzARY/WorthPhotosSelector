import SwiftUI
import AppKit
import Photos
#if SWIFT_PACKAGE
import PhotoCore
#endif

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
struct ReviewSnapshot {
    var decisions: [String: Decision]
    var groups: [PhotoGroup]
    var staleIDs: Set<String>
    var preference: PreferenceProfile?
    var calibrationAnswers: [CalibrationAnswer]?
    var calibratedScopeKey: String?
    var sameSubjectScopeKey: String?
    var savedProfile: PreferenceProfile?
    var deferredIDs: Set<String>?
    var selectedGroupID: String?
    var selectedIDs: Set<String>
    var queue: String
    var groupFilter: String
    var reviewFinished: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published var session = SelectionSession()
    @Published var selectedGroupID: String?
    @Published var selectedIDs = Set<String>()
    @Published var mergeIDs = Set<String>()
    @Published var queue = "groups"
    @Published var busy = false
    @Published var canCancelWork = true
    @Published var progress = 0
    @Published var total = 0
    @Published var phase = "选择一个文件夹，开始本地筛选"
    @Published var message: String?
    @Published var undoStack: [ReviewSnapshot] = []
    @Published var allowNetwork = false
    @Published var showPhotos = false
    @Published var previewRevision = 0
    @Published var albums: [PhotoAlbum] = []
    @Published var photosStatus = "点击连接后才请求授权"
    @Published var requestingPhotosAccess = false
    @Published var libraryChanged = false
    @Published var includeExcludedAlbum = false
    @Published var preferences = PreferenceSettings()
    @Published var selectionPlan = SelectionPlan.make(session: SelectionSession())
    @Published var showSettings = false
    @Published var calibration: CalibrationDraft?
    @Published var outputDraft: OutputDraft?
    @Published var outputResult: OutputResult?
    @Published var groupFilter = "all"
    @Published var mergeMode = false
    @Published var calibrationNotice: String?
    @Published var reviewFinished = false
    @Published var regrouping = false
    @Published var showCamera = false
    @Published var savedSessions: [SavedSessionSummary] = []
    @Published var loadingCamera = false
    @Published var refiningGroup = false
    private var hierarchy: SceneHierarchy?
    private var hierarchyScope: String?
    private var regroupTask: Task<Void, Never>?
    private var regroupRevision = UUID()
    private var refineTask: Task<Void, Never>?
    private var refineRevision = UUID()
    var task: Task<Void, Never>?
    private var cancelFlag = CancelFlag()
    private var scopeRevision = UUID()
    private var showedAutomaticGroup = false
    private var maySaveSession = true
    private var scopedURLs: [URL] = []
    private let sessionURL: URL
    private let preferencesURL: URL
    private var saveTask: Task<Void, Never>?
    private var libraryObserver: LibraryObserver?
    private var terminateObserver: NSObjectProtocol?

    init(sessionFile: URL? = nil) {
        let dir = sessionFile?.deletingLastPathComponent() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TravelSelect", isDirectory: true)
        sessionURL = sessionFile ?? dir.appendingPathComponent("session.json")
        preferencesURL = dir.appendingPathComponent("preferences.json")
        if let data = try? Data(contentsOf: preferencesURL), let settings = try? JSONDecoder().decode(PreferenceSettings.self, from: data) { preferences = settings }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: sessionURL.path) {
                session = try SessionStore.load(from: sessionURL)
                let oldData = try Data(contentsOf: sessionURL)
                if (try? JSONSerialization.jsonObject(with: oldData) as? [String: Any])?["schema"] as? Int == 2 {
                    let backup = dir.appendingPathComponent("session-v2-backup.json")
                    if !FileManager.default.fileExists(atPath: backup.path) { try oldData.write(to: backup, options: .withoutOverwriting) }
                }
                if (try? JSONSerialization.jsonObject(with: oldData) as? [String: Any])?["schema"] as? Int == 1 {
                    let backup = dir.appendingPathComponent("session-v1-backup.json")
                    if !FileManager.default.fileExists(atPath: backup.path) { try oldData.write(to: backup, options: .withoutOverwriting) }
                }
                for access in session.folders {
                    var stale = false
                    let url = try URL(resolvingBookmarkData: access.bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
                    if stale || !url.startAccessingSecurityScopedResource() { message = "文件夹授权已失效，请重新选择原文件夹。" }
                    else { scopedURLs.append(url) }
                }
                selectedGroupID = session.reviewGroups.first?.id
                queue = selectedGroupID == nil ? "all" : "groups"
                restoreReviewPosition()
                phase = session.requiresPhotosScope ? "旧会话未保存筛选条件，请重新选择范围；缓存与人工决定已保留" : "已恢复所选范围；可继续未完成的分析"
                if session.source == .photos && PhotoAccess.canRead { observeLibrary() }
            } else {
                session.settings.groupingLevel = .balanced
            }
        } catch { maySaveSession = false; message = "恢复会话失败，原会话文件已保护；请新建会话后继续：\(error.localizedDescription)" }
        if session.preference == nil { session.preference = preferences.savedProfile }
        session.recommendations = Grouping.recommend(session: session)
        selectionPlan = SelectionPlan.make(session: session)
        savedSessions = (try? SessionStore.savedSessions(in: dir)) ?? []
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { try? self?.saveImmediately() }
        }
    }
    var currentGroup: PhotoGroup? { session.reviewGroups.first { $0.id == selectedGroupID } }
    var visibleRecords: [PhotoRecord] {
        switch queue {
        case "missing": return session.activeRecords.filter { $0.captureDate == nil }
        case "issues": let ids = Set(selectionPlan.unresolvedIDs); return session.activeRecords.filter { ids.contains($0.id) }
        case "unmatched": return session.unmatchedRecords
        case "all": return session.activeRecords
        default:
            let ids = Set(currentGroup?.members ?? [])
            return session.activeRecords.filter { ids.contains($0.id) }
        }
    }
    var comparison: [PhotoRecord] { Grouping.ordered(session.activeRecords.filter { selectedIDs.contains($0.id) }) }
    var filteredGroups: [PhotoGroup] {
        session.reviewGroups.filter { group in
            if groupFilter == "attention" { return group.needsReview || group.members.contains { session.recommendations[$0]?.needsJudgment == true && (session.decisions[$0]?.choice ?? .unreviewed) == .unreviewed } }
            if groupFilter == "reviewed" { return group.members.allSatisfy { (session.decisions[$0]?.choice ?? .unreviewed) != .unreviewed } }
            return true
        }
    }
    var exportTitle: String { session.source != .photos && session.pendingAlbumToken != nil ? "继续导入" : session.source == .photos ? "生成精选相册" : session.source == .camera ? "将精选导入「照片」" : "导出精选照片" }
    var canExport: Bool { !busy && !regrouping && !refiningGroup && selectionPlan.permitsOutput }
    var groupActionTitle: String {
        guard let group = currentGroup else { return "采用推荐并下一组" }
        if group.members.allSatisfy({ session.decisions[$0]?.locked == true || (session.decisions[$0]?.choice ?? .unreviewed) != .unreviewed }) { return "完成本组并下一组" }
        return group.members.contains { (session.decisions[$0]?.choice ?? .unreviewed) != .unreviewed } ? "确认本组并下一组" : "采用推荐并下一组"
    }
    var canAcceptGroup: Bool {
        guard !busy, !regrouping, !refiningGroup, let group = currentGroup else { return false }
        var candidate = session; candidate.deferredIDs?.subtract(group.members)
        candidate.groupingComplete = true
        if let index = candidate.groups.firstIndex(where: { $0.id == group.id }) { candidate.groups[index].needsReview = false }
        return SelectionPlan.make(session: candidate).entries.filter { group.members.contains($0.id) }.allSatisfy { $0.disposition != .unresolved }
    }
    func record(_ id: String) -> PhotoRecord? { session.activeRecords.first { $0.id == id } }
    func toggleSelection(_ id: String) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }
    var canUndo: Bool { !undoStack.isEmpty }
    func snapshot() {
        undoStack.append(ReviewSnapshot(decisions: session.decisions, groups: session.groups, staleIDs: session.staleIDs,
            preference: session.preference, calibrationAnswers: session.calibrationAnswers,
            calibratedScopeKey: session.calibratedScopeKey, sameSubjectScopeKey: session.sameSubjectScopeKey, savedProfile: preferences.savedProfile,
            deferredIDs: session.deferredIDs, selectedGroupID: selectedGroupID, selectedIDs: selectedIDs, queue: queue,
            groupFilter: groupFilter, reviewFinished: reviewFinished))
        if undoStack.count > 20 { undoStack.removeFirst() }
    }
    func persist() {
        session.reviewPosition = ReviewPosition(groupID: selectedGroupID, selectedIDs: selectedIDs, queue: queue,
            groupFilter: groupFilter, finished: reviewFinished)
        if !busy { session.recommendations = Grouping.recommend(session: session) }
        selectionPlan = SelectionPlan.make(session: session)
        guard maySaveSession else { return }
        saveTask?.cancel()
        let snapshot = session, url = sessionURL
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let data = try await Task.detached(priority: .utility) { try SessionStore.data(snapshot) }.value
                try Task.checkCancellation()
                try data.write(to: url, options: .atomic)
            } catch is CancellationError {} catch { message = "会话保存失败：\(error.localizedDescription)" }
        }
    }
    func saveImmediately() throws {
        guard maySaveSession else { return }
        session.reviewPosition = ReviewPosition(groupID: selectedGroupID, selectedIDs: selectedIDs, queue: queue,
            groupFilter: groupFilter, finished: reviewFinished)
        saveTask?.cancel(); try SessionStore.save(session, to: sessionURL)
    }
    func newSession() {
        guard !busy else { return }
        let alert = NSAlert(); alert.messageText = "开始新的筛选会话？"
        alert.informativeText = "当前进度会自动保存，可以从“选择照片”菜单返回继续。"
        alert.addButton(withTitle: "新建"); alert.addButton(withTitle: "取消")
        guard session.records.isEmpty || alert.runModal() == .alertFirstButtonReturn else { return }
        do { try archiveCurrentSession() } catch { message = error.localizedDescription; return }
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }; scopedURLs = []
        maySaveSession = true; scopeRevision = UUID(); showedAutomaticGroup = false
        session = SelectionSession(); session.preference = preferences.savedProfile; calibrationNotice = nil; selectedIDs = []; mergeIDs = []; selectedGroupID = nil; undoStack = []
        session.settings.groupingLevel = .balanced; hierarchy = nil; reviewFinished = false
        phase = "选择照片来源"; persist()
    }
    func importFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = "选择照片文件夹。只读取所选范围，原片不变。"
        guard panel.runModal() == .OK else { return }
        if session.source != .folder {
            do { try archiveCurrentSession(); activateSession(SelectionSession()) }
            catch { message = error.localizedDescription; return }
            session.settings.groupingLevel = .balanced
        }
        do {
            for url in panel.urls {
                if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
                let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                if !session.folders.contains(where: { $0.path == url.path }) { session.folders.append(FolderAccess(path: url.path, bookmark: bookmark)) }
            }
        } catch { message = "无法保存文件夹授权：\(error.localizedDescription)"; return }
        session.source = .folder; session.sourceTitle = panel.urls.map(\.lastPathComponent).joined(separator: "、")
        let roots = panel.urls, excluding = session.excludedOutputPaths
        begin("读取文件夹")
        let flag = cancelFlag
        task = Task {
            do {
                let items = try await Task.detached { try FolderSource.scan(roots, excluding: excluding, cancelled: { flag.cancelled }) }.value
                let previousScope = session.scopeKey
                session.importRecords(items)
                if previousScope != session.scopeKey { session.preference = preferences.savedProfile; calibrationNotice = nil }
                for r in items where !r.supported { session.analyses[r.id] = AnalysisResult(status: .unsupported, issues: r.notes) }
                selectedGroupID = nil; queue = "all"; scopeRevision = UUID(); showedAutomaticGroup = false; undoStack = []; selectedIDs = []; mergeIDs = []
                phase = "已读取 \(items.count) 个文件，开始分析与分组"; persist()
                busy = false; analyze(); return
            } catch { message = error is CancellationError ? "读取已取消，未导入不完整列表。" : error.localizedDescription }
            busy = false
        }
    }
    func begin(_ label: String, canCancel: Bool = true) { busy = true; canCancelWork = canCancel; progress = 0; total = 0; phase = label; cancelFlag = CancelFlag() }
    func cancel() {
        cancelFlag.cancel(); task?.cancel(); refineTask?.cancel()
        if loadingCamera { CameraSource.shared.close(); loadingCamera = false; busy = false; persist() }
        phase = "正在取消，保留已完成结果…"
    }
    func cameraDisconnected() {
        guard session.source == .camera, session.cameraSource?.transport == .ptp else { return }
        if loadingCamera { loadingCamera = false; busy = false }
        else if busy { cancelFlag.cancel(); task?.cancel() }
        refineTask?.cancel(); refiningGroup = false
        phase = "相机连接已暂停，选片进度已保存"
        do { try saveImmediately() } catch { message = "会话保存失败：" + error.localizedDescription }
        persist()
    }
    private func applyGrouping(_ update: GroupingUpdate, revision: UUID) {
        guard revision == scopeRevision else { return }
        for id in update.invalidFeatureIDs {
            session.analyses[id]?.feature = nil
            session.analyses[id]?.status = .partial
            if session.analyses[id]?.issues.contains("视觉特征缓存损坏，需重新分析") != true {
                session.analyses[id]?.issues.append("视觉特征缓存损坏，需重新分析")
            }
        }
        session.replaceGroups(update.groups)
        session.recommendations = Grouping.recommend(session: session)
        if currentGroup == nil { selectedGroupID = session.reviewGroups.first?.id }
        if !showedAutomaticGroup, let first = session.reviewGroups.first {
            showedAutomaticGroup = true
            if queue == "all" { chooseGroup(first.id) }
        }
    }
    func analyze(force: Bool = false) {
        guard !busy, !session.activeRecords.isEmpty else { return }
        hierarchy = nil; refineTask?.cancel(); refiningGroup = false
        if session.settings.mode == .exact { regroup(); return }
        begin("分析并自动分组；结果随进度更新")
        session.groupingComplete = false
        let records = Grouping.ordered(session.activeRecords), flag = cancelFlag, network = allowNetwork
        let revision = scopeRevision
        if force { for record in records { session.analyses[record.id] = nil } }
        let engine = VisualGroupingEngine(settings: session.settings)
        task = Task {
            let seeded = await engine.seed(records: records, analyses: session.analyses)
            guard revision == scopeRevision else { return }
            applyGrouping(seeded, revision: revision)
            let pending = records.filter { $0.supported && (VisionAnalyzer.needsAnalysis($0, result: session.analyses[$0.id]) ||
                ($0.source == .camera && $0.timeNote == "相机尚未提供可信拍摄时间")) }
            total = pending.count
            for start in stride(from: 0, to: pending.count, by: 2) {
                if flag.cancelled || Task.isCancelled || revision != scopeRevision { break }
                let batch = Array(pending[start..<min(start + 2, pending.count)])
                let cached = session.analyses
                for record in batch {
                    var result = session.analyses[record.id] ?? AnalysisResult(cacheKey: VisionAnalyzer.cacheKey(record))
                    result.status = .running; session.analyses[record.id] = result
                }
                await withTaskGroup(of: (String, AnalysisResult).self) { group in
                    for record in batch {
                        group.addTask {
                            do {
                                try Task.checkCancellation()
                                let record = try await PhotoSource.prepareForAnalysis(record)
                                await MainActor.run {
                                    guard revision == self.scopeRevision,
                                          let index = self.session.records.firstIndex(where: { $0.id == record.id }) else { return }
                                    self.session.records[index] = record
                                }
                                let input = try await PhotoSource.image(record, allowNetwork: network)
                                let result = await VisionAnalyzer.analyze(input.image, record: record, cached: cached[record.id],
                                    inputSignature: record.source == .camera ? input.signature : nil,
                                    inputKind: input.kind, permitsQuality: input.permitsQuality) { partial in
                                    let update = await engine.add(record, result: partial)
                                    await MainActor.run {
                                        guard revision == self.scopeRevision else { return }
                                        self.session.analyses[record.id] = partial
                                        self.applyGrouping(update, revision: revision)
                                    }
                                }
                                return (record.id, result)
                            } catch {
                                var result = cached[record.id] ?? AnalysisResult(cacheKey: VisionAnalyzer.cacheKey(record))
                                let cloud = (error as? PhotoLoadError) == .cloud
                                result.status = error is CancellationError ? .cancelled : cloud ? .cloudUnavailable : .failed
                                result.issues = [error.localizedDescription]
                                return (record.id, result)
                            }
                        }
                    }
                    for await (id, result) in group {
                        guard revision == scopeRevision else { continue }
                        session.analyses[id] = result; progress += 1
                    }
                }
                session.recommendations = Grouping.recommend(session: session)
                if progress % 20 == 0 { persist() }
            }
            guard revision == scopeRevision else { return }
            let stopped = flag.cancelled || Task.isCancelled
            for record in pending where session.analyses[record.id]?.status == nil || session.analyses[record.id]?.status == .running || session.analyses[record.id]?.status == .pending {
                var result = session.analyses[record.id] ?? AnalysisResult(cacheKey: VisionAnalyzer.cacheKey(record))
                result.status = .cancelled; session.analyses[record.id] = result
            }
            // Finalizing cached features does not request another image or discard
            // completed groups when the analysis was cancelled.
            if let final = try? await engine.finish() { applyGrouping(final, revision: revision) }
            session.groupingComplete = !stopped
            session.recommendations = Grouping.recommend(session: session)
            busy = false
            let count = session.reviewGroups.count
            phase = stopped ? "已暂停；保留 \(count) 个相似组，可继续处理" : "分组完成：\(count) 个相似组 · \(session.unmatchedRecords.count) 张未找到相似项"
            persist(); maybeOfferCalibration(); refineCameraGroup()
        }
    }
    func regroup(visualSelection: Bool = false) {
        guard !busy, !session.activeRecords.isEmpty else { return }
        let scope: Set<String>? = visualSelection ? selectedIDs.intersection(session.activeIDs) : nil
        if visualSelection && (scope?.count ?? 0) < 2 { message = "先在照片网格中选择至少 2 张照片，再执行仅视觉比较。"; return }
        var input = session
        if visualSelection { input.settings.mode = .visualOnly }
        begin(visualSelection ? "仅比较选中照片，忽略拍摄时间" : "使用缓存重新分组")
        let flag = cancelFlag, revision = scopeRevision
        task = Task {
            do {
                let output = try await Task.detached { try Grouping.groups(session: input, scope: scope, cancelled: { flag.cancelled }) }.value
                guard revision == scopeRevision else { return }
                if let scope {
                    let remaining = session.groups.compactMap { group -> PhotoGroup? in
                        let ids = group.members.filter { !scope.contains($0) && session.activeIDs.contains($0) }
                        return ids.isEmpty ? nil : PhotoGroup(members: ids, kind: ids.count == 1 ? .single : group.kind)
                    }
                    session.replaceGroups(output + remaining)
                } else { session.replaceGroups(output) }
                session.groupingComplete = scope == nil ? true : input.groupingComplete
                refreshRecommendations(); selectedGroupID = session.reviewGroups.first?.id
                queue = selectedGroupID == nil ? "unmatched" : "groups"
                phase = "\(session.reviewGroups.count) 个相似组 · \(session.unmatchedRecords.count) 张未找到相似项"; persist()
            } catch { message = error is CancellationError ? "分组已取消，保留此前分组。" : error.localizedDescription }
            if revision == scopeRevision { busy = false; persist(); maybeOfferCalibration() }
        }
    }
    func refreshRecommendations() { session.recommendations = Grouping.recommend(session: session); persist() }
    func chooseGroup(_ id: String) {
        NSApp?.keyWindow?.makeFirstResponder(nil); selectedGroupID = id; queue = "groups"; selectedIDs = []; reviewFinished = false
        refineCameraGroup()
    }
    func photoShortcut(_ action: () -> Void) { if !(NSApp?.keyWindow?.firstResponder is NSTextView) { action() } }
    func undoFromMenu() {
        if let editor = NSApp?.keyWindow?.firstResponder as? NSTextView { editor.undoManager?.undo() }
        else { undo() }
    }
    func decide(_ choice: UserChoice) {
        guard !busy, !selectedIDs.isEmpty else { return }
        snapshot(); session.decide(Array(selectedIDs), choice: choice); persist()
    }
    func lockSelected() { guard !busy else { return }; snapshot(); session.decide(Array(selectedIDs), choice: .keep, lock: true); persist() }
    func unlockSelected() {
        guard !busy else { return }; snapshot()
        for id in selectedIDs { session.decisions[id]?.locked = false }; persist()
    }
    func undo() {
        guard !busy, let previous = undoStack.popLast() else { return }
        let currentIDs = session.activeIDs
        let historical = session.decisions.filter { !currentIDs.contains($0.key) }
        session.decisions = historical.merging(previous.decisions.filter { currentIDs.contains($0.key) }) { _, previous in previous }
        session.groups = previous.groups.compactMap { g in
            let ids = g.members.filter { currentIDs.contains($0) }
            guard !ids.isEmpty else { return nil }
            if ids == g.members { return g }
            var restored = PhotoGroup(members: ids, kind: g.kind, needsReview: true, samePersonConfirmed: g.samePersonConfirmed)
            restored.recommendationUnits = g.recommendationUnits?.map { $0.filter(currentIDs.contains) }.filter { !$0.isEmpty }
            return restored
        }
        session.staleIDs.formUnion(previous.staleIDs)
        session.preference = previous.preference; session.calibrationAnswers = previous.calibrationAnswers
        session.calibratedScopeKey = previous.calibratedScopeKey; session.sameSubjectScopeKey = previous.sameSubjectScopeKey
        preferences.savedProfile = previous.savedProfile; savePreferences()
        session.deferredIDs = previous.deferredIDs
        selectedGroupID = previous.selectedGroupID; selectedIDs = previous.selectedIDs
        queue = previous.queue; groupFilter = previous.groupFilter; reviewFinished = previous.reviewFinished
        refreshRecommendations()
    }
    func acceptGroup() {
        guard canAcceptGroup, let group = currentGroup else { return }
        let order = filteredGroups
        snapshot()
        session.deferredIDs?.subtract(group.members)
        if let index = session.groups.firstIndex(where: { $0.id == group.id }) { session.groups[index].needsReview = false }
        session.accept(session.groups.first(where: { $0.id == group.id }) ?? group)
        persist(); advanceReview(after: group.id, order: order)
    }
    func keepGroup() { guard let g = currentGroup, !busy else { return }; snapshot(); session.decide(g.members, choice: .keep); persist() }
    func nextGroup() {
        guard !busy, !regrouping, let group = currentGroup else { return }
        let order = filteredGroups
        snapshot(); session.deferReview(group.members); persist()
        advanceReview(after: group.id, order: order)
    }
    private func advanceReview(after id: String, order: [PhotoGroup]) {
        let start = order.firstIndex(where: { $0.id == id }) ?? -1
        let candidates = Array(order.dropFirst(start + 1)) + Array(order.prefix(max(0, start)))
        if let next = candidates.first(where: { group in
            group.members.contains { (session.decisions[$0]?.choice ?? .unreviewed) == .unreviewed &&
                session.decisions[$0]?.locked != true && session.deferredIDs?.contains($0) != true }
        }) { chooseGroup(next.id) }
        else { selectedGroupID = nil; selectedIDs = []; reviewFinished = true; queue = "complete"; refineTask?.cancel() }
    }
    func resumeDeferred() {
        groupFilter = "all"
        if let group = session.reviewGroups.first(where: { $0.members.contains { session.deferredIDs?.contains($0) == true } }) { chooseGroup(group.id) }
        else { reviewFinished = false; queue = "issues" }
    }
    func setGroupingLevel(_ level: GroupingLevel) {
        guard !busy, !refiningGroup, session.settings.mode != .exact else { return }
        regroupTask?.cancel(); regroupRevision = UUID()
        let revision = regroupRevision, scope = scopeRevision, input = session
        let anchor = selectedIDs.first ?? currentGroup?.members.first
        regrouping = true
        regroupTask = Task {
            do {
                let tree: SceneHierarchy
                if let cached = hierarchy, hierarchyScope == input.scopeKey { tree = cached }
                else {
                    let worker = Task.detached { try SceneHierarchy.make(session: input, cancelled: { Task.isCancelled }) }
                    tree = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                }
                try Task.checkCancellation()
                guard revision == regroupRevision, scope == scopeRevision else { return }
                hierarchy = tree; hierarchyScope = input.scopeKey
                session.settings.groupingLevel = level; session.settings.mode = .scene
                session.replaceGroups(tree.groups(level: level)); reviewFinished = false
                if let anchor, let target = session.reviewGroups.first(where: { $0.members.contains(anchor) }) { selectedGroupID = target.id; queue = "groups" }
                else { selectedGroupID = session.reviewGroups.first?.id; queue = selectedGroupID == nil ? "unmatched" : "groups" }
                selectedIDs.formIntersection(Set(visibleRecords.map(\.id)))
                persist()
            } catch is CancellationError {} catch { message = error.localizedDescription }
            if revision == regroupRevision { regrouping = false }
        }
    }
    func split() {
        guard let g = currentGroup, !busy else { return }
        let splitIDs = g.members.filter { selectedIDs.contains($0) }
        guard !splitIDs.isEmpty else { return }; snapshot()
        session.groups.removeAll { $0.id == g.id }
        let remaining = g.members.filter { !selectedIDs.contains($0) }
        if !remaining.isEmpty { session.groups.append(PhotoGroup(members: remaining, kind: .manual, needsReview: true)) }
        session.groups += splitIDs.map { PhotoGroup(members: [$0], kind: .single) }
        selectedGroupID = session.reviewGroups.first?.id; if selectedGroupID == nil { queue = "unmatched" }; refreshRecommendations()
    }
    func merge() {
        guard mergeIDs.count >= 2, !busy else { return }; snapshot()
        let ids = session.groups.filter { mergeIDs.contains($0.id) }.flatMap(\.members)
        session.groups.removeAll { mergeIDs.contains($0.id) }
        let g = PhotoGroup(members: ids, kind: .manual, needsReview: true)
        session.groups.insert(g, at: 0); mergeIDs = []; chooseGroup(g.id); refreshRecommendations()
    }
    func confirmSamePerson(_ value: Bool) {
        guard let i = session.groups.firstIndex(where: { $0.id == selectedGroupID }) else { return }
        snapshot(); session.groups[i].samePersonConfirmed = value; refreshRecommendations()
    }
    func confirmReview() {
        guard let g = currentGroup else { return }; snapshot()
        session.staleIDs.subtract(g.members)
        if let i = session.groups.firstIndex(where: { $0.id == g.id }) { session.groups[i].needsReview = false }; persist()
    }
    func exportManifest() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "照片选择清单.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let clean = session.exportSnapshot(); try SessionStore.save(clean, to: url); message = "选择清单已保存，包含未复核与分析失败项目。" }
        catch { message = error.localizedDescription }
    }
    func exportFolder() { prepareOutput() }
    static func stamp() -> String { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }

    private func observeLibrary() {
        if libraryObserver == nil {
            libraryObserver = LibraryObserver { [weak self] in Task { @MainActor in self?.libraryChanged = true } }
        }
    }
    func connectPhotos(showPicker: Bool = true) {
        guard !busy else { return }
        if !session.records.isEmpty && session.source != .photos {
            do {
                try archiveCurrentSession()
                if let old = savedSessions.first(where: { $0.source == .photos }) {
                    activateSession(try SessionStore.load(from: SessionStore.archiveURL(old.id, in: sessionURL.deletingLastPathComponent())))
                } else { var fresh = SelectionSession(); fresh.source = .photos; fresh.settings.groupingLevel = .balanced; activateSession(fresh) }
            } catch { message = error.localizedDescription; return }
        }
        showPhotos = showPicker
        guard !requestingPhotosAccess else { return }
        let needsPermission = PhotoAccess.status == .notDetermined
        requestingPhotosAccess = needsPermission
        photosStatus = needsPermission ? "正在等待系统照片授权，请在 macOS 提示中确认访问" : PhotoAccess.label
        Task {
            if needsPermission { _ = await PhotoAccess.request() }
            requestingPhotosAccess = false; photosStatus = PhotoAccess.label
            guard PhotoAccess.canRead else { return }
            do {
                albums = try await Task.detached { try PhotoLibrarySource.shared.albums() }.value
                observeLibrary(); previewRevision += 1
                if !showPicker { maybeOfferCalibration() }
            } catch { message = error.localizedDescription }
        }
    }
    func importPhotos(scope: PhotosScope) {
        guard !busy, PhotoAccess.canRead else { return }
        showPhotos = false; begin("读取所选范围（包含连拍成员，不含隐藏照片和视频）")
        let flag = cancelFlag, revision = scopeRevision
        task = Task {
            do {
                let items = try await Task.detached { try PhotoLibrarySource.shared.fetch(scope: scope, cancelled: { flag.cancelled }) }.value
                try Task.checkCancellation()
                guard revision == scopeRevision, !flag.cancelled else { throw CancellationError() }
                try applyLoadedPhotos(items, scope: scope)
                return
            } catch { message = error is CancellationError ? "读取已取消，保留此前范围" : error.localizedDescription }
            busy = false; phase = "未应用新范围；此前选择保持有效"
        }
    }
    /// Commit a successfully fetched range as one operation, then start the
    /// shared pipeline. Failed/cancelled fetches never call this method.
    func applyLoadedPhotos(_ items: [PhotoRecord], scope: PhotosScope) throws {
        let previousScope = session.scopeKey
        try session.applyPhotosScope(scope, records: items)
        if previousScope != session.scopeKey { session.preference = preferences.savedProfile; calibrationNotice = nil }
        scopeRevision = UUID(); showedAutomaticGroup = false
        selectedIDs = []; selectedGroupID = nil; mergeIDs = []; undoStack = []; queue = "all"
        PreviewCache.shared.cache.removeAllObjects()
        libraryChanged = false; persist(); busy = false
        if items.isEmpty { phase = "所选范围没有照片，请调整相册或日期" }
        else { analyze() }
    }
    func refreshPhotos() {
        guard session.source == .photos, !busy else { return }
        guard let scope = session.photosScope else { connectPhotos(); return }
        importPhotos(scope: scope)
    }
    func exportPhotos() { prepareOutput() }

    func savePreferences() {
        do { try JSONEncoder().encode(preferences).write(to: preferencesURL, options: .atomic) }
        catch { message = "偏好未能保存：\(error.localizedDescription)" }
    }
    func setScopeSameSubject(_ value: Bool) {
        guard !busy else { return }; snapshot()
        session.sameSubjectScopeKey = value ? session.scopeKey : nil
        refreshRecommendations()
    }
    func resetPreferences() {
        guard !busy else { return }; snapshot()
        preferences.savedProfile = nil; session.preference = nil
        session.calibratedScopeKey = session.scopeKey
        calibrationNotice = "已恢复整体画面优先；你的人工选择保持不变"
        savePreferences(); refreshRecommendations()
    }
    func maybeOfferCalibration() {
        guard !busy, !showPhotos, !showSettings, session.groupingComplete == true, calibration == nil, outputDraft == nil,
              session.source != .photos || PhotoAccess.canRead,
              session.calibratedScopeKey != session.scopeKey,
              preferences.askEveryScope || (session.preference == nil && preferences.savedProfile == nil) else { return }
        startCalibration(automatic: true)
    }
    func startCalibration(automatic: Bool = false) {
        guard !busy, session.groupingComplete == true else { return }
        let groups = PreferenceCalibration.candidates(session: session)
        if groups.isEmpty {
            if !automatic { calibrationNotice = "当前没有适合校准的争议组，可以直接浏览精选" }
            session.calibratedScopeKey = session.scopeKey; persist(); return
        }
        showSettings = false
        calibration = CalibrationDraft(session: session, groups: groups)
    }
    func finishCalibration(_ draft: CalibrationDraft, answers: [CalibrationAnswer], sameSubjectScope: Bool, remember: Bool) {
        guard !busy, draft.session.scopeKey == session.scopeKey else {
            calibration = nil; message = "照片范围已改变，请重新选择偏好样本"; return
        }
        snapshot()
        session.sameSubjectScopeKey = sameSubjectScope ? session.scopeKey : nil
        if let profile = PreferenceCalibration.fit(answers: answers, session: session) {
            session.preference = profile
            calibrationNotice = "已采用：\(profile.strategy.label)。这只是有限的选片偏好，可随时调整。"
        } else {
            // An uninformative or contradictory answer must not invent a preference.
            if session.preference == nil { session.preference = PreferenceProfile() }
            calibrationNotice = "已记住你对这些照片的选择；这些答案不足以改变其他组的排序"
        }
        for answer in answers where answer.response == .preferred {
            guard let winner = answer.preferredID, let group = session.groups.first(where: { $0.id == answer.groupID }),
                  group.members == answer.members, group.members.contains(winner),
                  group.members.allSatisfy({ id in record(id).map { answer.fingerprints[id] == $0.fingerprint } == true }) else { continue }
            if answer.sameSubject, let i = session.groups.firstIndex(where: { $0.id == group.id }) { session.groups[i].samePersonConfirmed = true }
            for id in group.members where (session.decisions[id]?.choice ?? .unreviewed) == .unreviewed {
                session.decide([id], choice: id == winner ? .keep : .exclude)
            }
        }
        session.calibrationAnswers = (session.calibrationAnswers ?? []) + answers
        session.calibratedScopeKey = session.scopeKey
        if remember { preferences.savedProfile = session.preference; savePreferences() }
        calibration = nil; refreshRecommendations()
    }
    func skipCalibration() {
        session.calibratedScopeKey = session.scopeKey; calibration = nil; persist()
    }
    func prepareOutput() {
        guard canExport else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "M月d日 HH:mm"
        do {
            let copies = session.source == .photos ? try PhotoLibrarySource.shared.copyRequiredIDs(session: session, plan: selectionPlan) : []
            var resume: ImportResumeSummary?
            if session.source != .photos, let token = session.pendingAlbumToken, let old = session.pendingOutputPlan {
                let journal = try OriginalPhotoImporter.journal(at: originalImportJournalURL(token))
                let current = Set(selectionPlan.keepIDs), previous = Set(old.keepIDs)
                let records = Dictionary(uniqueKeysWithValues: session.activeRecords.map { ($0.id, $0) })
                resume = ImportResumeSummary(recreateAlbum: PhotoAccess.canRead && journal.albumID.map { !SystemOriginalImportLibrary.albumExists($0) } == true, completed: journal.entries.filter { current.contains($0.key) && $0.value.complete }.count,
                    added: current.subtracting(previous).sorted().compactMap { records[$0]?.name },
                    removed: previous.subtracting(current).sorted().compactMap { records[$0]?.name })
            }
            outputDraft = OutputDraft(session: session, plan: selectionPlan,
                defaultName: resume == nil || resume?.recreateAlbum == true ? "择影 · " + formatter.string(from: Date()) : session.pendingAlbumNames.first ?? "择影",
                copyRequiredIDs: copies, resume: resume)
        } catch { message = error.localizedDescription }
    }
    func performOutput(_ draft: OutputDraft, name: String, includeUnselected: Bool, destination: OutputDestination? = nil) {
        guard !busy, draft.plan == SelectionPlan.make(session: session), draft.plan.permitsOutput else {
            outputDraft = nil; message = "照片选择已改变，请重新查看精选清单"; return
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let target = destination ?? draft.defaultDestination
        if target == .folder && session.source == .folder { copyOutput(draft, name: title, includeUnselected: includeUnselected) }
        else if session.source == .photos { createOutputAlbums(draft, name: title, includeUnselected: includeUnselected) }
        else { importSelectedOriginals(draft, name: title) }
    }
    private func importSelectedOriginals(_ draft: OutputDraft, name: String) {
        let plan = draft.plan, input = draft.session
        let baseToken = PhotoLibrarySource.outputToken(session: input, includeExcluded: false, plan: plan)
        let token = draft.resume?.recreateAlbum == true ? baseToken + "-reexport-" + UUID().uuidString :
            (session.pendingOutputPlan == plan ? session.pendingAlbumToken ?? baseToken : baseToken)
        outputDraft = nil; begin("正在准备将精选原片导入「照片」")
        let flag = cancelFlag
        task = Task {
            if input.source == .camera { CameraSource.shared.setImportingOriginals(true) }
            defer { if input.source == .camera { CameraSource.shared.setImportingOriginals(false) } }
            do {
                if !PhotoAccess.canRead { _ = await PhotoAccess.request() }
                guard PhotoAccess.canRead else { throw PhotoError.message("未获得照片图库权限；你的选片进度已保存") }
                if let oldToken = session.pendingAlbumToken, oldToken != token || session.pendingOutputPlan != plan {
                    phase = "正在核对已完成照片并更新续传清单"
                    let journal = try await OriginalPhotoImporter.rebase(session: input, plan: plan, oldToken: oldToken,
                        newToken: token, sourceURL: originalImportJournalURL(oldToken), targetURL: originalImportJournalURL(token),
                        replacementAlbumName: draft.resume?.recreateAlbum == true ? name : nil)
                    session.pendingAlbumToken = token; session.pendingOutputPlan = plan; session.pendingAlbumNames = [journal.albumName]
                } else if session.pendingAlbumToken == nil {
                    session.pendingAlbumNames = try session.receipts.first(where: { $0.token == token })?.names ?? PhotoLibrarySource.shared.availableAlbumNames(base: name, includeUnselected: false)
                    session.pendingAlbumToken = token; session.pendingOutputPlan = plan
                }
                try saveImmediately()
                let outputName = session.pendingAlbumNames.first ?? name
                let receipt = try await OriginalPhotoImporter.run(session: input, plan: plan, name: outputName, token: token,
                    journalURL: originalImportJournalURL(token), cancelled: { flag.cancelled }) { completed, expected, label in
                        await MainActor.run { self.progress = completed; self.total = expected; self.phase = label }
                    }
                session.receipts.removeAll { $0.token == token }
                session.receipts.append(receipt)
                session.pendingAlbumToken = nil; session.pendingAlbumNames = []; session.pendingOutputPlan = nil
                try saveImmediately()
                outputResult = OutputResult(title: "精选原片已导入", summary: "\(plan.keepIDs.count) 张照片已保存到「照片」，相机和存储卡上的原片保持不变。",
                    names: receipt.names, folder: nil, isPhotos: true)
            } catch is CancellationError { message = "导入已停止，已完成的照片和记录保留；重试会先核对已导入项。" }
            catch { message = error.localizedDescription + "\n选片进度和已完成的导入记录已保留。" }
            busy = false; phase = "原片保持原位"; persist()
        }
    }
    private func copyOutput(_ draft: OutputDraft, name: String, includeUnselected: Bool) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "选择保存位置，照片会复制到新的文件夹中。"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let access = parent.startAccessingSecurityScopedResource()
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var destination = parent.appendingPathComponent(safeName == "." || safeName == ".." ? "择影" : safeName)
        while FileManager.default.fileExists(atPath: destination.path) { destination = parent.appendingPathComponent(safeName + "-" + String(UUID().uuidString.prefix(6))) }
        let dest = destination, input = draft.session, plan = draft.plan
        session.excludedOutputPaths.append(dest.path); outputDraft = nil; persist()
        begin("正在保存精选照片"); let flag = cancelFlag
        task = Task {
            let report = await Task.detached { SafeExport.copy(session: input, destination: dest, plan: plan, includeUnselected: includeUnselected, cancelled: { flag.cancelled }) }.value
            if access { parent.stopAccessingSecurityScopedResource() }
            busy = false
            let keeps = Set(plan.keepIDs), rest = Set(plan.unselectedIDs)
            let saved = report.items.filter { $0.state == "copied" }
            let failures = report.items.filter { $0.state == "failed" }.count
            let summary = "精选 \(saved.filter { keeps.contains($0.id) }.count)/\(keeps.count) 张" +
                (includeUnselected ? " · 待整理 \(saved.filter { rest.contains($0.id) }.count)/\(rest.count) 张" : "") +
                (failures > 0 ? "\n\(failures) 张复制失败，详情见文件夹中的复制结果。" : "") +
                (report.cancelled ? "\n已停止，已完成的副本仍然保留。" : "") +
                (report.manifestSaved ? "" : "\n清单未能保存。") + report.errors.joined(separator: "\n")
            let expected = keeps.count + (includeUnselected ? rest.count : 0)
            let complete = report.copiedCount == expected && !report.cancelled && report.errors.isEmpty && report.manifestSaved
            outputResult = OutputResult(title: complete ? "照片已保存" : report.copiedCount == 0 ? "尚未保存照片" : "已保存部分照片", summary: summary,
                                        names: [dest.lastPathComponent], folder: dest, isPhotos: false, isComplete: complete)
            phase = complete ? "精选已保存，原照片保持不变" : "有照片尚未保存，可查看结果后重试"; persist()
        }
    }
    private func createOutputAlbums(_ draft: OutputDraft, name: String, includeUnselected: Bool) {
        let plan = draft.plan, input = draft.session
        let include = includeUnselected && !plan.unselectedIDs.isEmpty
        let token = PhotoLibrarySource.outputToken(session: input, includeExcluded: include, plan: plan)
        if let receipt = session.receipts.first(where: { $0.token == token }) {
            outputDraft = nil
            outputResult = OutputResult(title: "这些精选已经保存", summary: "未重复创建相册", names: receipt.names, folder: nil, isPhotos: true)
            return
        }
        if session.pendingAlbumToken != nil && session.pendingAlbumToken != token {
            message = "上次创建相册的结果还需核对。请在更多菜单中选择“核对上次相册”。"; return
        }
        if session.pendingAlbumToken == nil {
            do { session.pendingAlbumNames = try PhotoLibrarySource.shared.availableAlbumNames(base: name, includeUnselected: include) }
            catch { message = error.localizedDescription; return }
            session.pendingAlbumToken = token
            session.pendingOutputPlan = plan
        }
        do { try saveImmediately() } catch { message = "无法保存本次选择，尚未创建相册：\(error.localizedDescription)"; return }
        let names = session.pendingAlbumNames
        outputDraft = nil; begin("正在创建精选相册；请等待系统完成", canCancel: false)
        task = Task {
            do {
                let stale = try await Task.detached { try PhotoLibrarySource.shared.validateOutput(session: input, includeExcluded: include, plan: plan) }.value
                guard stale.isEmpty else {
                    session.staleIDs.formUnion(stale); session.pendingAlbumToken = nil; session.pendingAlbumNames = []; session.pendingOutputPlan = nil
                    throw PhotoError.message("\(stale.count) 张照片已变化或不可访问，请刷新来源。本次未创建相册。")
                }
                try Task.checkCancellation()
                let receipt = try await PhotoLibrarySource.shared.createAlbums(session: input, names: names, includeExcluded: include, token: token, plan: plan,
                    allowNetwork: allowNetwork, approvedCopyIDs: draft.copyRequiredIDs, journalURL: outputJournalURL(token))
                session.receipts.append(receipt); session.pendingAlbumToken = nil; session.pendingAlbumNames = []; session.pendingOutputPlan = nil
                try saveImmediately()
                outputResult = OutputResult(title: "精选相册已创建", summary: "精选 \(plan.keepIDs.count) 张" + (include ? " · 待整理 \(plan.unselectedIDs.count) 张" : ""), names: receipt.names, folder: nil, isPhotos: true)
            } catch { message = error.localizedDescription + "\n可从更多菜单核对上次相册，或重试同一选择。" }
            busy = false; phase = "原照片与原相册保持不变"; persist()
        }
    }
    func reconcilePendingOutput() {
        guard !busy, let token = session.pendingAlbumToken else { return }
        if session.source != .photos, let plan = session.pendingOutputPlan {
            _ = plan
            prepareOutput()
            return
        }
        do {
            if let plan = session.pendingOutputPlan {
                if let receipt = try PhotoLibrarySource.shared.recoverReceipt(token: token, names: session.pendingAlbumNames, session: session, includeExcluded: session.pendingAlbumNames.count > 1, plan: plan, journalURL: outputJournalURL(token)) {
                    session.receipts.append(receipt)
                    outputResult = OutputResult(title: "已找到创建好的相册", summary: "照片数量与上次选择一致", names: receipt.names, folder: nil, isPhotos: true)
                } else { message = "上次尚未创建相册，可以重新生成。" }
            } else {
                let ids = try PhotoLibrarySource.shared.inspectPendingAlbums(names: session.pendingAlbumNames)
                guard ids.isEmpty else { message = "找到旧版记录中的相册，请在「照片」中核对：\n" + session.pendingAlbumNames.joined(separator: "\n"); return }
            }
            session.pendingAlbumToken = nil; session.pendingAlbumNames = []; session.pendingOutputPlan = nil
            try saveImmediately()
        } catch { message = error.localizedDescription }
    }
    func openPhotos() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app"))
    }
    private func archiveCurrentSession() throws {
        guard maySaveSession else { throw PhotoError.message("当前会话读取失败，请先恢复原会话") }
        try saveImmediately()
        savedSessions = try SessionStore.archive(session, in: sessionURL.deletingLastPathComponent())
    }
    private func activateSession(_ next: SelectionSession) {
        saveTask?.cancel(); task?.cancel(); refineTask?.cancel(); regroupTask?.cancel()
        scopeRevision = UUID(); regroupRevision = UUID(); refineRevision = UUID(); hierarchy = nil; hierarchyScope = nil
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }; scopedURLs = []
        session = next; busy = false; refiningGroup = false; regrouping = false; loadingCamera = false
        selectedGroupID = next.reviewGroups.first?.id; queue = selectedGroupID == nil ? "all" : "groups"
        selectedIDs = []; mergeIDs = []; undoStack = []; reviewFinished = false; groupFilter = "all"
        restoreReviewPosition()
        calibration = nil; calibrationNotice = nil; outputDraft = nil; outputResult = nil
        PreviewCache.shared.cache.removeAllObjects(); previewRevision += 1
        for access in next.folders {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: access.bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
                if !stale && url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
                else { message = "文件夹授权已失效，请重新选择原文件夹" }
            } catch { message = "请重新授权原文件夹：" + error.localizedDescription }
        }
        phase = "已恢复选片进度"; persist()
    }
    private func restoreReviewPosition() {
        guard let position = session.reviewPosition else { return }
        selectedGroupID = position.groupID.flatMap { id in session.reviewGroups.contains { $0.id == id } ? id : nil }
        selectedIDs = position.selectedIDs.intersection(session.activeIDs)
        groupFilter = ["all", "attention", "reviewed"].contains(position.groupFilter) ? position.groupFilter : "all"
        queue = position.queue == "groups" && selectedGroupID == nil ? "all" : position.queue
        reviewFinished = position.finished
    }
    func restoreSession(_ summary: SavedSessionSummary) {
        guard !busy, !regrouping else { return }
        do {
            try archiveCurrentSession()
            let next = try SessionStore.load(from: SessionStore.archiveURL(summary.id, in: sessionURL.deletingLastPathComponent()))
            CameraSource.shared.close(); activateSession(next)
            if next.source == .photos { observeLibrary() }
            if next.source == .camera && next.cameraSource?.transport == .ptp { phase = "选择已恢复；连接原相机后可以继续" }
        } catch { message = error.localizedDescription }
    }
    func connectCamera() {
        guard !busy else { return }
        showCamera = true; CameraSource.shared.discover()
    }
    func selectCamera(_ descriptor: CameraSourceDescriptor) {
        guard !busy else { return }
        do {
            if session.cameraSource?.id != descriptor.id {
                try archiveCurrentSession()
                if let saved = savedSessions.first(where: { $0.cameraID == descriptor.id }) {
                    activateSession(try SessionStore.load(from: SessionStore.archiveURL(saved.id, in: sessionURL.deletingLastPathComponent())))
                } else {
                    var fresh = SelectionSession(); fresh.source = .camera; fresh.sourceTitle = descriptor.name
                    fresh.cameraSource = descriptor; fresh.settings.groupingLevel = .balanced; activateSession(fresh)
                }
            }
            let restoring = !session.activeRecords.isEmpty
            loadingCamera = true; begin(restoring ? "正在重连原相机，已完成分组保留" : "正在读取相机目录；原片保留在相机中")
            CameraSource.shared.onCatalog = { [weak self] descriptor, records, complete in
                guard let self, self.session.source == .camera, self.session.cameraSource?.id == descriptor.id else { return }
                guard complete else {
                    self.phase = "正在读取相机目录 · 已发现 \(records.count) 张"; return
                }
                // Incomplete catalogs can temporarily omit RAW partners or EXIF.
                // Commit only the finished snapshot so those updates do not
                // invalidate previously reviewed originals or an active analysis.
                guard self.loadingCamera else { return }
                self.completeCameraConnection(descriptor, records: records, restoring: restoring)
            }
            CameraSource.shared.onDisconnect = { [weak self] _ in self?.cameraDisconnected() }
            try CameraSource.shared.open(descriptor)
            showCamera = false
        } catch { loadingCamera = false; busy = false; message = error.localizedDescription }
    }
    func completeCameraConnection(_ descriptor: CameraSourceDescriptor, records: [PhotoRecord], restoring: Bool) {
        guard session.cameraSource?.id == descriptor.id else { return }
        loadingCamera = false; busy = false; showCamera = false
        if restoring {
            let result = session.reconnectCameraRecords(records, descriptor: descriptor)
            phase = "相机已重连；保留 \(session.reviewGroups.count) 个相似组，可继续选片或导入"
            if !result.changedIDs.isEmpty || !result.missingIDs.isEmpty || result.newCount > 0 {
                message = "原范围中 \(result.changedIDs.count) 张发生变化、\(result.missingIDs.count) 张暂不可读取；另有 \(result.newCount) 张新照片未加入本次范围。现有分组已保留。"
            }
            persist()
            previewRevision += 1
        } else {
            scopeRevision = UUID(); session.applyCameraRecords(records, descriptor: descriptor, complete: true)
            phase = "相机目录读取完成，开始分析"; queue = "all"
            persist(); analyze()
        }
    }
    func importStorage() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "选择相机或存储卡中的 DCIM 文件夹，直接读取原片所在位置。"
        guard panel.runModal() == .OK, let root = panel.url else { return }
        do {
            try archiveCurrentSession()
            let descriptor = CameraSourceDescriptor(id: stableID("storage|" + root.standardizedFileURL.path), name: root.lastPathComponent, transport: .storage, rootPath: root.path)
            if let saved = savedSessions.first(where: { $0.cameraID == descriptor.id }) {
                activateSession(try SessionStore.load(from: SessionStore.archiveURL(saved.id, in: sessionURL.deletingLastPathComponent())))
            } else { var fresh = SelectionSession(); fresh.source = .camera; fresh.settings.groupingLevel = .balanced; activateSession(fresh) }
            if root.startAccessingSecurityScopedResource() { scopedURLs.append(root) }
            let bookmark = try root.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            session.folders = [FolderAccess(path: root.path, bookmark: bookmark)]
            session.cameraSource = descriptor; session.sourceTitle = descriptor.name; showCamera = false
            begin("正在读取存储卡；无需先复制到本机")
            let flag = cancelFlag, revision = scopeRevision
            task = Task {
                do {
                    let records = try await Task.detached {
                        let files = try FolderSource.scan([root], cancelled: { flag.cancelled })
                        let photos = try files.filter { ExternalAssets.isPhoto(name: $0.name) }.map { try ExternalAssets.inspectStorage(URL(fileURLWithPath: $0.locator)) }
                        return ExternalAssets.pairStorageRecords(photos, descriptor: descriptor)
                    }.value
                    try Task.checkCancellation()
                    guard revision == scopeRevision else { return }
                    session.applyCameraRecords(records, descriptor: descriptor, complete: true)
                    busy = false; persist(); analyze()
                } catch { if revision == scopeRevision { busy = false; message = error.localizedDescription } }
            }
        } catch { message = error.localizedDescription }
    }
    private func refineCameraGroup() {
        refineTask?.cancel(); refineRevision = UUID()
        guard !busy, session.source == .camera, session.cameraSource?.transport == .ptp, let group = currentGroup else { refiningGroup = false; return }
        let records = session.activeRecords.filter { group.members.contains($0.id) && session.analyses[$0.id]?.inputKind == "cameraPreview" && !session.hasCompleteAnalysis($0) }
        guard !records.isEmpty else { refiningGroup = false; return }
        let revision = scopeRevision, refinement = refineRevision
        refiningGroup = true
        refineTask = Task {
            for record in records {
                if Task.isCancelled || revision != scopeRevision || refinement != refineRevision { break }
                do {
                    let input = try await PhotoSource.image(record, allowOriginal: true)
                    try Task.checkCancellation()
                    let result = await VisionAnalyzer.analyze(input.image, record: record, cached: session.analyses[record.id],
                        inputSignature: input.signature, inputKind: input.kind, permitsQuality: input.permitsQuality)
                    guard revision == scopeRevision, refinement == refineRevision, !Task.isCancelled else { break }
                    session.analyses[record.id] = result; hierarchy = nil; persist()
                } catch is CancellationError { break }
                catch { if revision == scopeRevision { calibrationNotice = "原片细节尚未读完：" + error.localizedDescription }; break }
            }
            guard revision == scopeRevision, refinement == refineRevision else { return }
            refiningGroup = false
            if !Task.isCancelled, let level = session.settings.groupingLevel { setGroupingLevel(level) }
        }
    }
    private func outputJournalURL(_ token: String) -> URL { sessionURL.deletingLastPathComponent().appendingPathComponent("photos-output-" + token + ".json") }
    private func originalImportJournalURL(_ token: String) -> URL { sessionURL.deletingLastPathComponent().appendingPathComponent("original-import-" + token + ".json") }
}
