import Foundation

public struct SelectionSession: Codable {
    public var schema = 3
    public var id = UUID().uuidString
    public var source: SourceKind = .folder
    public var sourceTitle = "尚未选择来源"
    public var records: [PhotoRecord] = []
    public var analyses: [String: AnalysisResult] = [:]
    public var decisions: [String: Decision] = [:]
    public var recommendations: [String: Recommendation] = [:]
    public var groups: [PhotoGroup] = []
    public var settings = AnalysisSettings()
    public var folders: [FolderAccess] = []
    public var staleIDs: Set<String> = []
    public var excludedOutputPaths: [String] = []
    public var receipts: [AlbumReceipt] = []
    public var pendingAlbumToken: String?
    public var pendingAlbumNames: [String] = []
    public var photosScope: PhotosScope?
    public var activePhotoIDs: Set<String>?
    public var groupingComplete: Bool?
    public var preference: PreferenceProfile?
    public var calibrationAnswers: [CalibrationAnswer]?
    public var calibratedScopeKey: String?
    public var sameSubjectScopeKey: String?
    public var pendingOutputPlan: SelectionPlan?
    public var deferredIDs: Set<String>?
    public var cameraSource: CameraSourceDescriptor?
    public var activeCameraIDs: Set<String>?
    public var reviewPosition: ReviewPosition?
    public var unavailableCameraIDs: Set<String>?
    public init() {}

    public var scopeKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let scope = photosScope.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return stableID(source.rawValue + scope + activeRecords.map { $0.id + $0.fingerprint }.sorted().joined(separator: "|"))
    }
    public var scopeHasSameSubject: Bool { guard let key = sameSubjectScopeKey else { return false }; return key == scopeKey }
    public func hasCompleteAnalysis(_ record: PhotoRecord) -> Bool {
        guard !staleIDs.contains(record.id), unavailableCameraIDs?.contains(record.id) != true, hasFeature(record), let a = analyses[record.id],
              a.status == .success, a.qualityComplete == true,
              let score = a.aesthetics, score.isFinite, (-1...1).contains(score) else { return false }
        return true
    }

    public var requiresPhotosScope: Bool { source == .photos && (photosScope == nil || activePhotoIDs == nil) }
    public var activeRecords: [PhotoRecord] {
        if source == .camera {
            let ids = activeCameraIDs ?? []
            return records.filter { $0.source == .camera && ids.contains($0.id) }
        }
        guard source == .photos else { return records }
        guard let photosScope, let activePhotoIDs else { return [] }
        return records.filter { activePhotoIDs.contains($0.id) && photosScope.contains($0.captureDate) }
    }
    public var activeIDs: Set<String> { Set(activeRecords.map(\.id)) }
    public var reviewGroups: [PhotoGroup] {
        let ids = activeIDs
        return groups.filter { $0.members.count > 1 && $0.members.allSatisfy(ids.contains) }
    }
    public var recommendationGroups: [PhotoGroup] { reviewGroups.flatMap(\.selectionGroups) }
    public mutating func deferReview(_ ids: [String]) {
        if deferredIDs == nil { deferredIDs = [] }
        let pending = ids.filter { activeIDs.contains($0) && (decisions[$0]?.choice ?? .unreviewed) == .unreviewed && decisions[$0]?.locked != true }
        deferredIDs?.formUnion(pending)
    }
    public mutating func applyCameraRecords(_ items: [PhotoRecord], descriptor: CameraSourceDescriptor, complete: Bool) {
        source = .camera; sourceTitle = descriptor.name; cameraSource = descriptor
        let previous = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let enriched = items.map { item -> PhotoRecord in
            guard let prior = previous[item.id], prior.fingerprint == item.fingerprint,
                  item.captureDate == nil, prior.captureDate != nil else { return item }
            var result = item; result.captureDate = prior.captureDate; result.timeNote = prior.timeNote
            return result
        }
        importRecords(enriched)
        if complete { activeCameraIDs = Set(items.map(\.id)) }
        else { activeCameraIDs = (activeCameraIDs ?? []).union(items.map(\.id)) }
        groupingComplete = false
    }
    /// Rebind an existing selection without changing its scope or rebuilding groups.
    /// New captures remain outside this session until the user selects a new scope.
    public mutating func reconnectCameraRecords(_ items: [PhotoRecord], descriptor: CameraSourceDescriptor) -> CameraReconnectResult {
        guard source == .camera, cameraSource?.id == descriptor.id else {
            return CameraReconnectResult(changedIDs: [], missingIDs: [], newCount: items.count)
        }
        let active = activeIDs
        let incoming = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var changed = Set<String>(), missing = Set<String>()
        for index in records.indices where active.contains(records[index].id) {
            let old = records[index]
            guard let next = incoming[old.id] else { missing.insert(old.id); continue }
            if old.fingerprint != next.fingerprint {
                records[index] = next; analyses[old.id] = nil; changed.insert(old.id)
            }
            // Identical originals retain learned EXIF, analysis, and review state.
        }
        staleIDs.formUnion(changed); unavailableCameraIDs = missing
        cameraSource = descriptor; sourceTitle = descriptor.name
        return CameraReconnectResult(changedIDs: changed, missingIDs: missing,
            newCount: Set(incoming.keys).subtracting(active).count)
    }
    public func hasFeature(_ record: PhotoRecord) -> Bool {
        guard let result = analyses[record.id] else { return false }
        return result.cacheKey == VisionAnalyzer.cacheKey(record) && result.feature != nil
    }
    public var unmatchedRecords: [PhotoRecord] {
        let grouped = Set(reviewGroups.flatMap(\.members))
        return activeRecords.filter { hasFeature($0) && !grouped.contains($0.id) }
    }
    public mutating func applyPhotosScope(_ scope: PhotosScope, records items: [PhotoRecord]) throws {
        try scope.validate()
        guard items.allSatisfy({ $0.source == .photos && scope.contains($0.captureDate) }) else {
            throw PhotoError.message("读取结果超出所选范围，未应用本次结果")
        }
        source = .photos; photosScope = scope; sourceTitle = "Apple Photos · " + scope.title
        importRecords(items)
        activePhotoIDs = Set(items.map(\.id)); groupingComplete = false
        let ids = activeIDs
        replaceGroups(groups.compactMap { old in
            let members = old.members.filter(ids.contains)
            guard members.count > 1 else { return nil }
            if members == old.members { return old }
            return PhotoGroup(members: members, kind: old.kind, needsReview: true)
        })
        recommendations = recommendations.filter { ids.contains($0.key) }
    }
    /// A manifest describes the current range, not the historical cache.
    public func exportSnapshot() -> SelectionSession {
        var copy = self; copy.records = activeRecords
        let ids = Set(copy.records.map(\.id))
        copy.analyses = analyses.filter { ids.contains($0.key) }
        for id in copy.analyses.keys { copy.analyses[id]?.feature = nil }
        copy.decisions = decisions.filter { ids.contains($0.key) }
        copy.groups = groups.filter { $0.members.allSatisfy(ids.contains) }
        copy.recommendations = recommendations.filter { ids.contains($0.key) }
        copy.staleIDs = staleIDs.intersection(ids)
        copy.deferredIDs = deferredIDs?.intersection(ids)
        copy.calibrationAnswers = calibrationAnswers?.filter { $0.members.allSatisfy(ids.contains) }
        if copy.pendingOutputPlan?.scopeKey != scopeKey { copy.pendingOutputPlan = nil }
        return copy
    }

    public mutating func importRecords(_ items: [PhotoRecord]) {
        var index = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) })
        for item in items {
            let wasFavorite = index[item.id].map { records[$0].favorite }
            if let i = index[item.id] {
                if records[i].fingerprint != item.fingerprint {
                    analyses[item.id] = nil; staleIDs.insert(item.id)
                }
                records[i] = item
            } else { index[item.id] = records.count; records.append(item) }
            if item.favorite && wasFavorite != true {
                var decision = decisions[item.id] ?? Decision()
                decision.locked = true
                if decision.choice == .exclude { decision.choice = .unreviewed }
                decisions[item.id] = decision
            }
        }
    }
    public mutating func decide(_ ids: [String], choice: UserChoice, lock: Bool? = nil) {
        let allowed = activeIDs
        for id in ids where allowed.contains(id) {
            var d = decisions[id] ?? Decision()
            if d.locked && choice != .keep && lock != false { continue }
            d.choice = choice
            if let lock { d.locked = lock }
            decisions[id] = d
            staleIDs.remove(id)
            deferredIDs?.remove(id)
        }
    }
    public mutating func accept(_ group: PhotoGroup) {
        var input = self
        input.deferredIDs?.subtract(group.members)
        // Explicit acceptance can confirm a fully analyzed group after a pause.
        // Only this group's entries are committed; the rest stays unresolved.
        input.groupingComplete = true
        let plan = SelectionPlan.make(session: input)
        for entry in plan.entries where group.members.contains(entry.id) {
            guard (decisions[entry.id]?.choice ?? .unreviewed) == .unreviewed else { continue }
            if entry.disposition == .keep { decide([entry.id], choice: .keep) }
            else if entry.disposition == .unselected { decide([entry.id], choice: .exclude) }
        }
    }
    public func outputIDs(_ choice: UserChoice) -> [String] {
        activeRecords.compactMap { r in
            let d = decisions[r.id] ?? Decision()
            return d.choice == choice && !staleIDs.contains(r.id) && !(choice == .exclude && d.locked) ? r.id : nil
        }
    }
    public mutating func replaceGroups(_ next: [PhotoGroup]) {
        let oldGroups = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let prior = Set(oldGroups.keys)
        groups = next.map { g in
            var g = g
            g.needsReview = g.needsReview || oldGroups[g.id]?.needsReview == true || (!prior.contains(g.id) && g.members.contains { decisions[$0]?.choice != nil && decisions[$0]?.choice != .unreviewed })
            if let old = oldGroups[g.id] { g.samePersonConfirmed = old.samePersonConfirmed }
            return g
        }
    }
}

public struct CameraReconnectResult: Equatable, Sendable {
    public var changedIDs: Set<String>
    public var missingIDs: Set<String>
    public var newCount: Int
}
public struct ReviewPosition: Codable {
    public var groupID: String?
    public var selectedIDs: Set<String>
    public var queue: String
    public var groupFilter: String
    public var finished: Bool
    public init(groupID: String?, selectedIDs: Set<String>, queue: String, groupFilter: String, finished: Bool) {
        self.groupID = groupID; self.selectedIDs = selectedIDs; self.queue = queue
        self.groupFilter = groupFilter; self.finished = finished
    }
}

public enum SessionStore {
    public static func savedSessions(in directory: URL) throws -> [SavedSessionSummary] {
        let index = directory.appendingPathComponent("sessions/index.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        return try JSONDecoder().decode([SavedSessionSummary].self, from: Data(contentsOf: index))
    }
    public static func archive(_ session: SelectionSession, in directory: URL) throws -> [SavedSessionSummary] {
        guard !session.records.isEmpty else { return try savedSessions(in: directory) }
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try save(session, to: archiveURL(session.id, in: directory))
        var summaries = try savedSessions(in: directory)
        summaries.removeAll { $0.id == session.id }
        summaries.insert(SavedSessionSummary(id: session.id, title: session.sourceTitle, source: session.source,
            count: session.activeRecords.count, cameraID: session.cameraSource?.id), at: 0)
        try JSONEncoder().encode(summaries).write(to: root.appendingPathComponent("index.json"), options: .atomic)
        return summaries
    }
    public static func archiveURL(_ id: String, in directory: URL) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw PhotoError.message("会话标识无效") }
        return directory.appendingPathComponent("sessions/\(id).json")
    }
    public static func data(_ session: SelectionSession) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(session)
    }
    public static func save(_ session: SelectionSession, to url: URL) throws {
        try data(session).write(to: url, options: .atomic)
    }
    public static func load(from url: URL) throws -> SelectionSession {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        var result = try decoder.decode(SelectionSession.self, from: Data(contentsOf: url))
        guard [1, 2, 3].contains(result.schema) else { throw PhotoError.message("会话版本不兼容") }
        if result.schema == 1 {
            result.schema = 2
            if result.settings.mode == .travel { result.settings.mode = .scene }
            result.groupingComplete = false
        }
        result.schema = 3
        if result.requiresPhotosScope { result.groups = []; result.recommendations = [:] }
        for id in result.analyses.keys where result.analyses[id]?.status == .running {
            result.analyses[id]?.status = .cancelled
        }
        return result
    }
}

public struct SavedSessionSummary: Codable, Identifiable {
    public var id: String
    public var title: String
    public var source: SourceKind
    public var count: Int
    public var cameraID: String?
}
