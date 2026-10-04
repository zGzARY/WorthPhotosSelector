import Foundation

public enum SelectionDisposition: String, Codable { case keep, unselected, unresolved }
public enum SelectionOrigin: String, Codable { case manual, protected, recommendation, single, incomplete }
public struct SelectionEntry: Codable, Identifiable, Equatable {
    public var id: String
    public var fingerprint: String
    public var disposition: SelectionDisposition
    public var origin: SelectionOrigin
    public var reason: String
}
public struct SelectionPlan: Codable, Equatable {
    public var scopeKey: String
    public var groupingComplete: Bool
    public var entries: [SelectionEntry]
    public var keepIDs: [String] { ids(.keep) }
    public var unselectedIDs: [String] { ids(.unselected) }
    public var unresolvedIDs: [String] { ids(.unresolved) }
    /// A stopped scan can output explicit choices, never unfinished automatic recommendations.
    public var permitsOutput: Bool {
        !keepIDs.isEmpty && (groupingComplete || entries.filter { $0.disposition != .unresolved }.allSatisfy {
            $0.origin == .manual || $0.origin == .protected
        })
    }
    public func ids(_ disposition: SelectionDisposition) -> [String] { entries.filter { $0.disposition == disposition }.map(\.id) }
    public static func make(session: SelectionSession, automatic: Bool = true) -> SelectionPlan {
        let complete = session.groupingComplete == true
        let scopeKey = session.scopeKey
        let sameSubject = session.sameSubjectScopeKey == scopeKey
        let records = session.activeRecords
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var entries: [String: SelectionEntry] = [:]
        func set(_ id: String, _ disposition: SelectionDisposition, _ origin: SelectionOrigin, _ reason: String) {
            guard let record = byID[id] else { return }
            entries[id] = SelectionEntry(id: id, fingerprint: record.fingerprint, disposition: disposition, origin: origin, reason: reason)
        }
        for record in records {
            let d = session.decisions[record.id] ?? Decision()
            if session.unavailableCameraIDs?.contains(record.id) == true { set(record.id, .unresolved, .incomplete, "相机目录中暂未找到原片，请重连后核对") }
            else if session.staleIDs.contains(record.id) { set(record.id, .unresolved, .incomplete, "来源已变化，需要重新确认") }
            else if d.locked { set(record.id, .keep, .protected, "已锁定保留") }
            else if d.choice == .keep { set(record.id, .keep, .manual, "你选择了保留") }
            else if d.choice == .exclude { set(record.id, .unselected, .manual, "你选择了不保留") }
            else if session.deferredIDs?.contains(record.id) == true { set(record.id, .unresolved, .incomplete, "你选择了稍后处理") }
        }
        if automatic && complete {
            for group in session.recommendationGroups {
                let unresolved = group.needsReview || !group.members.allSatisfy { id in
                    guard let record = byID[id] else { return false }
                    if group.kind == .exact { return record.supported && !session.staleIDs.contains(id) }
                    return session.hasCompleteAnalysis(record)
                }
                guard !unresolved else { continue }
                let hasKeep = group.members.contains { entries[$0]?.disposition == .keep }
                let available = group.members.filter { entries[$0] == nil }
                let comparable = (group.samePersonConfirmed || sameSubject) && PhotoRanking.hasComparableFaces(group, in: session)
                let ranked = group.kind == .exact ? available.sorted() : PhotoRanking.ranked(group, session: session, confirmed: comparable).filter(available.contains)
                let selected = hasKeep ? Set<String>() : Set(ranked.prefix(max(1, min(2, session.settings.recommendationCount))))
                for id in available {
                    set(id, selected.contains(id) ? .keep : .unselected, .recommendation,
                        selected.contains(id) ? "本组推荐" : "本组已有精选照片")
                }
            }
            let grouped = Set(session.reviewGroups.flatMap(\.members))
            for record in records where entries[record.id] == nil && !grouped.contains(record.id) && session.hasCompleteAnalysis(record) {
                set(record.id, .keep, .single, "未找到相似项，保留这张")
            }
        }
        for record in records where entries[record.id] == nil {
            set(record.id, .unresolved, .incomplete, complete ? "尚未完成分析或需要重新复核" : "分组尚未完成")
        }
        return SelectionPlan(scopeKey: scopeKey, groupingComplete: complete, entries: records.compactMap { entries[$0.id] })
    }
}
