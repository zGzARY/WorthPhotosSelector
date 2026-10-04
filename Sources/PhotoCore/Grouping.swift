import Foundation
import Vision

public enum Grouping {
    public static func ordered(_ records: [PhotoRecord]) -> [PhotoRecord] {
        records.sorted {
            if $0.captureDate != $1.captureDate { return ($0.captureDate ?? .distantFuture) < ($1.captureDate ?? .distantFuture) }
            return $0.id < $1.id
        }
    }
    public static func cluster(records: [PhotoRecord], settings: AnalysisSettings,
                               eligible: Set<String>, cancelled: () -> Bool = { false },
                               distance: (String, String) throws -> Float) throws -> [PhotoGroup] {
        var accumulator = GroupAccumulator(settings: settings)
        for record in ordered(records) where eligible.contains(record.id) {
            try accumulator.insert(record, cancelled: cancelled, distance: distance)
        }
        return accumulator.groups
    }
    public static func groups(session: SelectionSession, scope: Set<String>? = nil,
                              cancelled: () -> Bool = { false }) throws -> [PhotoGroup] {
        let records = scope.map { ids in session.activeRecords.filter { ids.contains($0.id) } } ?? session.activeRecords
        if session.settings.mode == .exact {
            guard session.source == .folder else { throw PhotoError.message("Photos 预览不是原始资源，不能用于文件级完全重复检测。") }
            return try FolderSource.exactGroups(records, cancelled: cancelled)
        }
        if let level = session.settings.groupingLevel {
            var input = session
            if scope != nil {
                input.records = records
                input.activePhotoIDs = Set(records.map(\.id)); input.activeCameraIDs = Set(records.map(\.id))
            }
            return try SceneHierarchy.make(session: input, cancelled: cancelled).groups(level: level)
        }
        var features: [String: VNFeaturePrintObservation] = [:]
        for record in records {
            if cancelled() { throw CancellationError() }
            guard session.hasFeature(record), let data = session.analyses[record.id]?.feature,
                  let feature = try? VisionAnalyzer.feature(data) else { continue }
            features[record.id] = feature
        }
        return try cluster(records: records, settings: session.settings, eligible: Set(features.keys), cancelled: cancelled) { a, b in
            try VisionAnalyzer.distance(features[a]!, features[b]!)
        }
    }
    public static func recommend(session: SelectionSession) -> [String: Recommendation] {
        var all: [String: Recommendation] = [:]
        let scopeConfirmed = session.scopeHasSameSubject
        for group in session.recommendationGroups {
            let facesComparable = (group.samePersonConfirmed || scopeConfirmed) && PhotoRanking.hasComparableFaces(group, in: session)
            let strategy = session.preference?.strategy ?? .overall
            let ranked = PhotoRanking.ranked(group, session: session, confirmed: facesComparable).filter {
                session.decisions[$0]?.choice != .exclude || session.decisions[$0]?.locked == true
            }
            let fixed = Set(group.members.filter {
                !session.staleIDs.contains($0) && (session.decisions[$0]?.locked == true || session.decisions[$0]?.choice == .keep)
            })
            let count = max(1, min(2, session.settings.recommendationCount))
            let selected = fixed.isEmpty ? Set(ranked.prefix(count)) : fixed
            let conflict = PhotoRanking.hasSignalConflict(group, session: session)
            let close = PhotoRanking.isClose(ranked, count: count, group: group, session: session, confirmed: facesComparable)
            let missing = group.members.contains { PhotoRanking.aesthetic(session.analyses[$0]) == nil || session.staleIDs.contains($0) }
            for id in group.members {
                let analysis = session.analyses[id]
                let reason: String
                if session.staleIDs.contains(id) { reason = "来源已变化，请重新确认" }
                else if session.decisions[id]?.locked == true { reason = "已锁定保留" }
                else if session.decisions[id]?.choice == .keep { reason = "你选择了保留" }
                else if session.decisions[id]?.choice == .exclude { reason = "你选择了不保留" }
                else if PhotoRanking.aesthetic(analysis) == nil { reason = "评分尚不可用，留给你确认" }
                else {
                    let basis = facesComparable && strategy != .overall ? "按你的偏好，兼顾整体画面与人脸拍摄质量" : "按整体画面评分推荐"
                    let explanation = conflict ? (facesComparable ? "；两项指标支持不同照片，值得你选" : "；人像指标与整体评分不同，可先确认是否同一人") : ""
                    let limitation = !facesComparable && strategy != .overall ? "；本组未确认可比较的人脸，暂用整体评分" : ""
                    reason = (selected.contains(id) ? basis : "本组有其他照片排名更高") + explanation + limitation
                }
                all[id] = Recommendation(selected: selected.contains(id), reason: reason,
                    needsJudgment: group.needsReview || analysis?.status != .success || missing || conflict || close)
            }
        }
        return all
    }
}

/// Only feature-ready records enter this accumulator. Singletons here mean
/// compared but unmatched; pending/failed records are never placeholder groups.
private struct GroupAccumulator {
    var settings: AnalysisSettings
    var bins: [[PhotoRecord]] = []
    var ids = Set<String>()
    var groups: [PhotoGroup] { bins.map { PhotoGroup(members: $0.map(\.id), kind: $0.count > 1 ? .similar : .single) } }
    mutating func insert(_ record: PhotoRecord, cancelled: () -> Bool = { false },
                         distance: (String, String) throws -> Float) throws {
        guard !ids.contains(record.id) else { return }
        if cancelled() { throw CancellationError() }
        guard settings.distance.isFinite, settings.distance >= 0 else { throw PhotoError.message("相似程度参数无效") }
        var target: Int?
        for index in bins.indices.reversed() {
            if settings.mode == .travel {
                guard let date = record.captureDate, let first = bins[index].first,
                      first.captureDate != nil else { continue }
                let dates = bins[index].compactMap(\.captureDate) + [date]
                guard dates.max()!.timeIntervalSince(dates.min()!) <= settings.timeSpan else { continue }
                if (record.timeNote?.contains("未含时区") == true) != (first.timeNote?.contains("未含时区") == true) { continue }
            }
            var fits = true
            for member in bins[index] {
                if cancelled() { throw CancellationError() }
                let value = try distance(record.id, member.id)
                guard value.isFinite, value >= 0 else { throw PhotoError.message("视觉距离无效，请重新分析相关照片") }
                if value > settings.distance { fits = false; break }
            }
            if fits { target = index; break }
        }
        if let target { bins[target].append(record) } else { bins.append([record]) }
        ids.insert(record.id)
    }
}

public struct GroupingUpdate: Sendable {
    public var groups: [PhotoGroup]
    public var invalidFeatureIDs: Set<String>
}

/// Owns decoded features off the UI thread. Each arrival compares only the new
/// record; finish replays a stable order independently of completion timing.
public actor VisualGroupingEngine {
    private var settings: AnalysisSettings
    private var accumulator: GroupAccumulator
    private var records: [String: PhotoRecord] = [:]
    private var features: [String: VNFeaturePrintObservation] = [:]
    private var invalid = Set<String>()
    public init(settings: AnalysisSettings) { self.settings = settings; accumulator = GroupAccumulator(settings: settings) }
    public func add(_ record: PhotoRecord, result: AnalysisResult) -> GroupingUpdate {
        guard result.cacheKey == VisionAnalyzer.cacheKey(record), let data = result.feature else { return update }
        guard features[record.id] == nil else { records[record.id] = record; return update }
        do {
            let feature = try VisionAnalyzer.feature(data)
            features[record.id] = feature
            try accumulator.insert(record) { a, b in try VisionAnalyzer.distance(features[a]!, features[b]!) }
            records[record.id] = record; invalid.remove(record.id)
        } catch { features[record.id] = nil; invalid.insert(record.id) }
        return update
    }
    public func seed(records: [PhotoRecord], analyses: [String: AnalysisResult]) -> GroupingUpdate {
        for record in Grouping.ordered(records) {
            if let result = analyses[record.id] { _ = add(record, result: result) }
        }
        return update
    }
    public func finish(cancelled: @Sendable () -> Bool = { false }) throws -> GroupingUpdate {
        if let level = settings.groupingLevel {
            let hierarchy = try SceneHierarchy.build(records: Array(records.values), eligible: Set(features.keys),
                useTime: settings.mode != .visualOnly, cancelled: cancelled) { a, b in
                    try VisionAnalyzer.distance(features[a]!, features[b]!)
                }
            return GroupingUpdate(groups: hierarchy.groups(level: level), invalidFeatureIDs: invalid)
        }
        var final = GroupAccumulator(settings: settings)
        for record in Grouping.ordered(Array(records.values)) {
            try final.insert(record, cancelled: cancelled) { a, b in try VisionAnalyzer.distance(features[a]!, features[b]!) }
        }
        accumulator = final
        return update
    }
    private var update: GroupingUpdate { GroupingUpdate(groups: accumulator.groups, invalidFeatureIDs: invalid) }
}
