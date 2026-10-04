import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCore

final class PreferenceAndOutputTests: XCTestCase {
    func session(_ values: [(String, Float, Float?)]) -> SelectionSession {
        var s = SelectionSession()
        for (id, aesthetic, face) in values {
            let r = PhotoRecord(id: id, source: .folder, locator: "/synthetic/" + id, name: id)
            s.records.append(r)
            var a = AnalysisResult(cacheKey: VisionAnalyzer.cacheKey(r), status: .success, feature: Data([1]), aesthetics: aesthetic,
                                   faces: face.map { [FaceMeasure(x: 0, y: 0, width: 0.3, height: 0.3, quality: $0)] } ?? [])
            a.qualityComplete = true; s.analyses[id] = a
        }
        s.groups = [PhotoGroup(members: values.map { $0.0 }, kind: .similar)]
        s.groupingComplete = true
        return s
    }
    func answer(_ s: SelectionSession, winner: String, sameSubject: Bool = true) -> CalibrationAnswer {
        CalibrationAnswer(group: s.groups[0], records: s.records, preferredID: winner, response: .preferred, sameSubject: sameSubject)
    }
    func testScreenshotConflictUsesActualPreferenceAndExplainsDisagreement() {
        var s = session([("964", 0.7988281, 0.74658203), ("965", 0.8701172, 0.5371094), ("966", 0.6, 0.4)])
        var rec = Grouping.recommend(session: s)
        XCTAssertTrue(rec["965"]!.selected)
        XCTAssertTrue(rec["965"]!.needsJudgment)
        XCTAssertTrue(PhotoRanking.hasSignalConflict(s.groups[0], session: s))
        let profile = PreferenceCalibration.fit(answers: [answer(s, winner: "964")], session: s)
        XCTAssertEqual(profile?.strategy, .balanced)
        s.preference = profile
        XCTAssertTrue(Grouping.recommend(session: s)["965"]!.selected, "No implicit identity assumption")
        s.groups[0].samePersonConfirmed = true
        rec = Grouping.recommend(session: s)
        XCTAssertTrue(rec["964"]!.selected); XCTAssertFalse(rec["965"]!.selected)
        XCTAssertEqual(SelectionPlan.make(session: s).keepIDs, ["964"])
    }
    func testPreferenceTransfersToAnUnseenConfirmedGroup() {
        var s = session([("a", 0.8, 0.75), ("b", 0.87, 0.54)])
        let learned = PreferenceCalibration.fit(answers: [answer(s, winner: "a")], session: s)
        let unseen = session([("x", 0.71, 0.79), ("y", 0.84, 0.43)])
        s.records += unseen.records; s.analyses.merge(unseen.analyses) { _, rhs in rhs }
        s.groups += [PhotoGroup(members: ["x", "y"], kind: .similar, samePersonConfirmed: true)]
        s.preference = learned
        XCTAssertTrue(Grouping.recommend(session: s)["x"]!.selected)
        XCTAssertTrue(s.decisions.isEmpty, "Reranking is not a manual decision")
    }
    func testContradictorySkippedAndStaleAnswersDoNotInventPreference() {
        let s = session([("a", 0.8, 0.75), ("b", 0.87, 0.54)])
        XCTAssertNil(PreferenceCalibration.fit(answers: [answer(s, winner: "a"), answer(s, winner: "b")], session: s))
        XCTAssertNil(PreferenceCalibration.fit(answers: [answer(s, winner: "a", sameSubject: false)], session: s))
        var invalid = answer(s, winner: "a"); invalid.fingerprints["a"] = "changed"
        XCTAssertNil(PreferenceCalibration.fit(answers: [invalid], session: s))
        invalid = answer(s, winner: "a"); invalid.groupID = "a different group"
        XCTAssertNil(PreferenceCalibration.fit(answers: [invalid], session: s))
        invalid = answer(s, winner: "a"); invalid.response = .skipped
        XCTAssertNil(PreferenceCalibration.fit(answers: [invalid], session: s))
        invalid.response = .indifferent
        XCTAssertNil(PreferenceCalibration.fit(answers: [invalid], session: s))
    }
    func testImportedPhotoJournalRecoversActualMembershipAndRejectsWrongTransaction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("output.json")
        let journal = AlbumOutputJournal(token: "one", importedIDs: ["photos:shared": "personal-copy"])
        try journal.save(to: url)
        let loaded = try AlbumOutputJournal.load(from: url, token: "one")
        XCTAssertEqual(loaded.expectedIDs(["photos:shared", "photos:existing"]), ["photos:personal-copy", "photos:existing"])
        XCTAssertThrowsError(try AlbumOutputJournal.load(from: url, token: "different"))
    }
    func testChangedPhotoVersionProducesANewAlbumTransaction() {
        var s = session([("a", 0.9, nil), ("b", 0.8, nil)])
        let original = SelectionPlan.make(session: s)
        let first = PhotoLibrarySource.outputToken(session: s, includeExcluded: false, plan: original)
        s.records[0].modified = Date(timeIntervalSince1970: 100)
        var changed = original; changed.entries[0].fingerprint = s.records[0].fingerprint
        XCTAssertNotEqual(first, PhotoLibrarySource.outputToken(session: s, includeExcluded: false, plan: changed))
    }
    func testMissingOrMultipleFacesNeverUseFaceWeight() {
        var s = session([("a", 0.8, 0.95), ("b", 0.9, nil)])
        s.preference = PreferenceProfile(strategy: .portrait); s.groups[0].samePersonConfirmed = true
        XCTAssertTrue(Grouping.recommend(session: s)["b"]!.selected)
        s.analyses["b"]?.faces = [FaceMeasure(x: 0, y: 0, width: 0.1, height: 0.1, quality: 0.1), FaceMeasure(x: 0.5, y: 0, width: 0.1, height: 0.1, quality: 0.2)]
        XCTAssertTrue(Grouping.recommend(session: s)["b"]!.selected)
    }
    func testScopeConfirmationDoesNotTransferToAnotherRange() {
        var s = session([("a", 0.8, 0.9), ("b", 0.9, 0.2)])
        s.preference = PreferenceProfile(strategy: .portrait); s.sameSubjectScopeKey = s.scopeKey
        XCTAssertTrue(s.scopeHasSameSubject); XCTAssertTrue(Grouping.recommend(session: s)["a"]!.selected)
        s.records.append(PhotoRecord(id: "new", source: .folder, locator: "/new", name: "new"))
        XCTAssertFalse(s.scopeHasSameSubject); XCTAssertTrue(Grouping.recommend(session: s)["b"]!.selected)
    }
    func testNearTieUsesTheActualSelectionBoundary() {
        var s = session([("a", 0.95, nil), ("b", 0.3, nil), ("c", 0.29, nil)])
        s.settings.recommendationCount = 2
        XCTAssertTrue(Grouping.recommend(session: s)["b"]!.needsJudgment)
        s.settings.recommendationCount = 1
        XCTAssertFalse(Grouping.recommend(session: s)["a"]!.needsJudgment)
    }
    func testCalibrationUsesDistinctCompleteUnreviewedGroups() {
        var s = session([("a", 0.8, 0.9), ("b", 0.85, 0.2), ("c", 0.5, nil), ("d", 0.51, nil), ("e", 0.6, nil), ("f", 0.61, nil)])
        s.groups = [["a", "b"], ["c", "d"], ["e", "f"]].map { PhotoGroup(members: $0, kind: .similar) }
        let first = PreferenceCalibration.candidates(session: s)
        XCTAssertEqual(first.count, 3); XCTAssertEqual(first.first?.id, s.groups[0].id)
        s.decide(["a"], choice: .keep); s.analyses["e"]?.qualityComplete = false
        XCTAssertEqual(PreferenceCalibration.candidates(session: s).map(\.id), [s.groups[1].id])
    }
    func testAutomaticPlanIncludesSinglesAndRespectsManualChoicesAndLocks() {
        var s = session([("a", 0.9, nil), ("b", 0.8, nil), ("c", 0.7, nil), ("single", 0.1, nil), ("cloud", 0.5, nil)])
        s.groups = [PhotoGroup(members: ["a", "b", "c"], kind: .similar)]
        s.analyses["cloud"] = AnalysisResult(status: .cloudUnavailable)
        var plan = SelectionPlan.make(session: s)
        XCTAssertEqual(Set(plan.keepIDs), ["a", "single"])
        XCTAssertEqual(Set(plan.unselectedIDs), ["b", "c"]); XCTAssertEqual(plan.unresolvedIDs, ["cloud"])
        s.decide(["a"], choice: .exclude); s.decide(["b"], choice: .keep); s.decide(["c"], choice: .keep, lock: true)
        plan = SelectionPlan.make(session: s)
        XCTAssertEqual(Set(plan.keepIDs), ["b", "c", "single"]); XCTAssertEqual(plan.unselectedIDs, ["a"])
        XCTAssertEqual(plan.entries.first { $0.id == "b" }?.origin, .manual)
        XCTAssertEqual(plan.entries.first { $0.id == "c" }?.origin, .protected)
        s.preference = PreferenceProfile(strategy: .portrait)
        XCTAssertEqual(SelectionPlan.make(session: s).keepIDs, plan.keepIDs)
    }
    func testIncompleteGroupAndCancelledRunNeverAutomaticallyRejectAnything() {
        var s = session([("a", 0.9, nil), ("b", 0.8, nil)])
        s.analyses["b"]?.qualityComplete = false
        XCTAssertEqual(SelectionPlan.make(session: s).unresolvedIDs.count, 2)
        XCTAssertTrue(SelectionPlan.make(session: s).unselectedIDs.isEmpty)
        s.analyses["b"]?.qualityComplete = true; s.groupingComplete = false
        XCTAssertEqual(SelectionPlan.make(session: s).unresolvedIDs.count, 2)
        s.groupingComplete = true; s.staleIDs.insert("a")
        XCTAssertEqual(SelectionPlan.make(session: s).unresolvedIDs.count, 2)
        s.staleIDs = []; s.groups[0].needsReview = true
        XCTAssertEqual(SelectionPlan.make(session: s).unresolvedIDs.count, 2)
    }
    func testLegacySessionAndPreferencesRoundTripWithoutDiscardingAnalysis() throws {
        var s = session([("a", 0.9, nil), ("b", 0.8, nil)])
        s.decide(["b"], choice: .keep)
        let original = try SessionStore.data(s)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.json")
        try original.write(to: file)
        var restored = try SessionStore.load(from: file)
        XCTAssertEqual(restored.decisions, s.decisions); XCTAssertEqual(restored.analyses["a"]?.feature, s.analyses["a"]?.feature)
        XCTAssertNil(restored.preference)
        restored.preference = PreferenceProfile(strategy: .balanced, answerCount: 1)
        restored.pendingOutputPlan = SelectionPlan.make(session: restored)
        try SessionStore.save(restored, to: file)
        XCTAssertEqual(try SessionStore.load(from: file).pendingOutputPlan, restored.pendingOutputPlan)
        XCTAssertEqual(try SessionStore.load(from: file).preference, restored.preference)
    }
    func testPhotosTokenReflectsFrozenAutomaticSelectionWithoutChangingDecisions() {
        var s = session([("a", 0.9, nil), ("b", 0.8, nil)])
        let plan = SelectionPlan.make(session: s)
        let keep = PhotoLibrarySource.outputToken(session: s, includeExcluded: false, plan: plan)
        let both = PhotoLibrarySource.outputToken(session: s, includeExcluded: true, plan: plan)
        XCTAssertNotEqual(keep, both); XCTAssertTrue(s.decisions.isEmpty)
        s.decide(["b"], choice: .keep)
        XCTAssertEqual(keep, PhotoLibrarySource.outputToken(session: s, includeExcluded: false, plan: plan))
        XCTAssertNotEqual(keep, PhotoLibrarySource.outputToken(session: s, includeExcluded: false, plan: SelectionPlan.make(session: s)))
    }
    func testBothFolderOutputsUseOriginalBytesAndRetainDecisionProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        for name in ["one.jpg", "two.jpg"] {
            let dest = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        var s = SelectionSession(); s.records = try FolderSource.scan([root]); s.groupingComplete = true
        for (i, record) in s.records.enumerated() {
            var a = AnalysisResult(cacheKey: VisionAnalyzer.cacheKey(record), status: .success, feature: Data([1]), aesthetics: Float(i) / 2)
            a.qualityComplete = true; s.analyses[record.id] = a
        }
        s.groups = [PhotoGroup(members: s.records.map(\.id), kind: .similar)]
        let originals = try s.records.map { try FolderSource.sha256(URL(fileURLWithPath: $0.locator)) }
        let plan = SelectionPlan.make(session: s), destination = root.appendingPathComponent("results")
        let report = SafeExport.copy(session: s, destination: destination, plan: plan, includeUnselected: true)
        XCTAssertEqual(report.copiedCount, 2); XCTAssertTrue(report.manifestSaved)
        XCTAssertEqual(report.items.filter { $0.destination?.hasPrefix("精选/") == true }.count, 1)
        XCTAssertEqual(report.items.filter { $0.destination?.hasPrefix("待整理/") == true }.count, 1)
        XCTAssertEqual(try s.records.map { try FolderSource.sha256(URL(fileURLWithPath: $0.locator)) }, originals)
        let manifest = try SessionStore.load(from: destination.appendingPathComponent("选择清单.json"))
        XCTAssertTrue(manifest.decisions.isEmpty)
        for item in report.items {
            let index = s.records.firstIndex { $0.id == item.id }!
            XCTAssertEqual(try FolderSource.sha256(destination.appendingPathComponent(item.destination!)), originals[index])
        }
    }
}
