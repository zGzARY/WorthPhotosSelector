import XCTest
import PhotoCore
@testable import TravelSelect

@MainActor
final class RedesignWorkflowTests: XCTestCase {
    func model() throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AppModel(sessionFile: root.appendingPathComponent("session.json"))
    }
    func seed(_ model: AppModel) {
        var s = SelectionSession()
        for i in 0..<5 {
            let r = PhotoRecord(id: "r\(i)", source: .folder, locator: "/synthetic/\(i)", name: "\(i)", captureDate: Date(timeIntervalSince1970: Double(i)))
            s.records.append(r)
            var a = AnalysisResult(cacheKey: VisionAnalyzer.cacheKey(r), status: .success, feature: Data([1]), aesthetics: Float(i) / 5,
                                   faces: [FaceMeasure(x: 0, y: 0, width: 0.2, height: 0.2, quality: 1 - Float(i) / 5)])
            a.qualityComplete = true; s.analyses[r.id] = a
        }
        s.groups = [PhotoGroup(members: s.records.map(\.id), kind: .similar)]
        s.groupingComplete = true; model.session = s; model.refreshRecommendations()
    }
    func testAllSelectedPhotosCompareInStableOrderWithoutTruncation() throws {
        let m = try model(); seed(m)
        m.selectedIDs = Set(m.session.records.map(\.id))
        XCTAssertEqual(m.comparison.map(\.id), m.session.records.map(\.id))
        m.session.preference = PreferenceProfile(strategy: .portrait); m.setScopeSameSubject(true)
        XCTAssertEqual(m.comparison.map(\.id), m.session.records.map(\.id))
        for count in 2...5 {
            m.selectedIDs = Set(m.session.records.prefix(count).map(\.id))
            XCTAssertEqual(m.comparison.count, count)
        }
        XCTAssertEqual(ComparisonLayout.columnCount(count: 2, width: 1100), 2)
        XCTAssertEqual(ComparisonLayout.columnCount(count: 3, width: 1100), 3)
        XCTAssertEqual(ComparisonLayout.columnCount(count: 4, width: 1100), 2)
        XCTAssertEqual(ComparisonLayout.columnCount(count: 5, width: 1100), 3)
    }
    func testOutputDraftContainsAutomaticChoicesWithoutManualAcceptance() throws {
        let m = try model(); seed(m)
        XCTAssertTrue(m.session.decisions.isEmpty); XCTAssertTrue(m.canExport)
        m.prepareOutput()
        XCTAssertEqual(m.outputDraft?.plan.keepIDs, ["r4"])
        XCTAssertEqual(m.outputDraft?.plan.unselectedIDs.count, 4)
        XCTAssertTrue(m.outputDraft!.session.decisions.isEmpty)
        m.session.groupingComplete = false; m.refreshRecommendations()
        XCTAssertFalse(m.canExport)
    }
    func testCalibrationSavesLimitedPreferenceAndCanUndoManualChanges() throws {
        let m = try model(); seed(m)
        m.startCalibration()
        let draft = try XCTUnwrap(m.calibration)
        let answer = CalibrationAnswer(group: draft.groups[0], records: m.session.records, preferredID: "r0", response: .preferred, sameSubject: true)
        m.finishCalibration(draft, answers: [answer], sameSubjectScope: true, remember: true)
        XCTAssertEqual(m.session.preference?.strategy, .portrait)
        XCTAssertEqual(m.preferences.savedProfile?.strategy, .portrait)
        XCTAssertEqual(m.session.decisions["r0"]?.choice, .keep)
        XCTAssertEqual(m.session.outputIDs(.exclude).count, 4)
        XCTAssertNil(m.calibration)
        m.undo()
        XCTAssertTrue(m.session.decisions.isEmpty); XCTAssertNil(m.preferences.savedProfile)
        XCTAssertNil(m.session.preference)
    }
    func testSkippedCalibrationDoesNotPromptAgainForSameScope() throws {
        let m = try model(); seed(m)
        m.maybeOfferCalibration(); XCTAssertNotNil(m.calibration)
        m.skipCalibration(); m.maybeOfferCalibration()
        XCTAssertNil(m.calibration); XCTAssertTrue(m.session.decisions.isEmpty)
        XCTAssertNil(m.preferences.savedProfile)
    }
    func testUndoPreservesHistoricalChoicesOutsideCurrentScope() throws {
        let m = try model(); seed(m)
        m.session.decisions["historical-photo"] = Decision(choice: .keep, locked: true)
        m.selectedIDs = ["r0"]; m.decide(.keep)
        m.undo()
        XCTAssertNil(m.session.decisions["r0"])
        XCTAssertEqual(m.session.decisions["historical-photo"]?.choice, .keep)
        XCTAssertEqual(m.session.decisions["historical-photo"]?.locked, true)
    }
}
