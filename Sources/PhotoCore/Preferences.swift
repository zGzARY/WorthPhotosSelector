import Foundation

public enum PreferenceStrategy: String, Codable, CaseIterable {
    case overall, balanced, portrait
    public var faceWeight: Float {
        switch self { case .overall: return 0; case .balanced: return 0.25; case .portrait: return 0.75 }
    }
    public var label: String {
        switch self { case .overall: return "整体画面优先"; case .balanced: return "兼顾人物"; case .portrait: return "人物优先" }
    }
}
public struct PreferenceProfile: Codable, Equatable {
    public var strategy: PreferenceStrategy
    public var version = 1
    public var answerCount: Int
    public init(strategy: PreferenceStrategy = .overall, answerCount: Int = 0) {
        self.strategy = strategy; self.answerCount = answerCount
    }
}
public struct PreferenceSettings: Codable {
    public var savedProfile: PreferenceProfile?
    public var askEveryScope = false
    public init() {}
}
public enum CalibrationResponse: String, Codable { case preferred, indifferent, skipped }
public struct CalibrationAnswer: Codable, Equatable {
    public var groupID: String
    public var members: [String]
    public var fingerprints: [String: String]
    public var preferredID: String?
    public var response: CalibrationResponse
    public var sameSubject: Bool
    public init(group: PhotoGroup, records: [PhotoRecord], preferredID: String? = nil,
                response: CalibrationResponse, sameSubject: Bool = false) {
        groupID = group.id; members = group.members
        fingerprints = Dictionary(uniqueKeysWithValues: records.filter { group.members.contains($0.id) }.map { ($0.id, $0.fingerprint) })
        self.preferredID = preferredID; self.response = response; self.sameSubject = sameSubject
    }
}

public enum PhotoRanking {
    public static func aesthetic(_ result: AnalysisResult?) -> Float? {
        guard let score = result?.aesthetics, score.isFinite, (-1...1).contains(score) else { return nil }
        return (score + 1) / 2
    }
    public static func face(_ result: AnalysisResult?) -> Float? {
        guard let faces = result?.faces, faces.count == 1, let score = faces[0].quality,
              score.isFinite, (0...1).contains(score) else { return nil }
        return score
    }
    public static func hasComparableFaces(_ group: PhotoGroup, in session: SelectionSession) -> Bool {
        group.members.allSatisfy { face(session.analyses[$0]) != nil }
    }
    public static func usesFaces(_ group: PhotoGroup, in session: SelectionSession) -> Bool {
        (group.samePersonConfirmed || session.scopeHasSameSubject) && hasComparableFaces(group, in: session)
    }
    public static func score(_ id: String, group: PhotoGroup, session: SelectionSession,
                             strategy: PreferenceStrategy? = nil, confirmed: Bool? = nil) -> Float? {
        guard let a = aesthetic(session.analyses[id]) else { return nil }
        let comparable = confirmed ?? usesFaces(group, in: session)
        let weight = comparable ? (strategy ?? session.preference?.strategy ?? .overall).faceWeight : 0
        guard weight > 0, let f = face(session.analyses[id]) else { return a }
        return (1 - weight) * a + weight * f
    }
    public static func ranked(_ group: PhotoGroup, session: SelectionSession,
                              strategy: PreferenceStrategy? = nil, confirmed: Bool? = nil) -> [String] {
        let comparable = confirmed ?? usesFaces(group, in: session)
        return group.members.filter { !session.staleIDs.contains($0) && score($0, group: group, session: session, strategy: strategy, confirmed: comparable) != nil }
            .sorted {
                let a = score($0, group: group, session: session, strategy: strategy, confirmed: comparable)!
                let b = score($1, group: group, session: session, strategy: strategy, confirmed: comparable)!
                return a == b ? $0 < $1 : a > b
            }
    }
    /// This detects disagreement between measurements, not proof of identity.
    public static func hasSignalConflict(_ group: PhotoGroup, session: SelectionSession) -> Bool {
        guard group.members.count > 1, hasComparableFaces(group, in: session),
              group.members.allSatisfy({ aesthetic(session.analyses[$0]) != nil }) else { return false }
        let a = group.members.max { aesthetic(session.analyses[$0])! < aesthetic(session.analyses[$1])! }!
        let f = group.members.max { face(session.analyses[$0])! < face(session.analyses[$1])! }!
        return aesthetic(session.analyses[a])! > aesthetic(session.analyses[f])! && face(session.analyses[f])! > face(session.analyses[a])!
    }
    public static func isClose(_ ranked: [String], count: Int, group: PhotoGroup, session: SelectionSession, confirmed: Bool? = nil) -> Bool {
        let k = max(1, count)
        guard ranked.count > k,
              let a = score(ranked[k - 1], group: group, session: session, confirmed: confirmed),
              let b = score(ranked[k], group: group, session: session, confirmed: confirmed) else { return false }
        return a - b < 0.03
    }
}

public enum PreferenceCalibration {
    public static func candidates(session: SelectionSession, limit: Int = 3) -> [PhotoGroup] {
        let records = Dictionary(uniqueKeysWithValues: session.activeRecords.map { ($0.id, $0) })
        let sameSubject = session.scopeHasSameSubject
        let eligible = session.reviewGroups.filter { group in
            group.selectionGroups.count == 1 && !group.needsReview && group.members.allSatisfy { id in
                guard let record = records[id] else { return false }
                let decision = session.decisions[id] ?? Decision()
                return !decision.locked && decision.choice == .unreviewed && session.hasCompleteAnalysis(record)
            }
        }
        return eligible.filter { group in
            let comparable = (group.samePersonConfirmed || sameSubject) && PhotoRanking.hasComparableFaces(group, in: session)
            return PhotoRanking.hasSignalConflict(group, session: session) || PhotoRanking.isClose(PhotoRanking.ranked(group, session: session, confirmed: comparable), count: 1, group: group, session: session, confirmed: comparable)
        }.sorted {
            let a = PhotoRanking.hasSignalConflict($0, session: session), b = PhotoRanking.hasSignalConflict($1, session: session)
            return a == b ? $0.id < $1.id : a && !b
        }.prefix(max(0, limit)).map { $0 }
    }
    public static func fit(answers: [CalibrationAnswer], session: SelectionSession) -> PreferenceProfile? {
        let records = Dictionary(uniqueKeysWithValues: session.activeRecords.map { ($0.id, $0) })
        let groups = Dictionary(uniqueKeysWithValues: session.groups.map { ($0.id, $0) })
        let sameSubject = session.scopeHasSameSubject
        let valid = answers.filter { answer in
            answer.response == .preferred && answer.preferredID.map(answer.members.contains) == true &&
            groups[answer.groupID]?.members == answer.members &&
            answer.members.allSatisfy { id in records[id].map { answer.fingerprints[id] == $0.fingerprint && session.hasCompleteAnalysis($0) } == true } &&
            (answer.sameSubject || sameSubject) &&
            answer.members.allSatisfy { PhotoRanking.face(session.analyses[$0]) != nil }
        }
        guard !valid.isEmpty else { return nil }
        let prior = session.preference?.strategy ?? .overall
        let matches = PreferenceStrategy.allCases.filter { strategy in
            valid.allSatisfy { answer in
                let group = PhotoGroup(members: answer.members, kind: .similar, samePersonConfirmed: true)
                guard let winner = answer.preferredID, let chosen = PhotoRanking.score(winner, group: group, session: session, strategy: strategy, confirmed: true) else { return false }
                return answer.members.allSatisfy { (PhotoRanking.score($0, group: group, session: session, strategy: strategy, confirmed: true) ?? .infinity) <= chosen }
            }
        }
        guard !matches.isEmpty else { return nil }
        let selected = matches.contains(prior) ? prior : matches.min {
            let a = abs($0.faceWeight - prior.faceWeight), b = abs($1.faceWeight - prior.faceWeight)
            return a == b ? $0.faceWeight < $1.faceWeight : a < b
        }!
        return PreferenceProfile(strategy: selected, answerCount: valid.count)
    }
}
