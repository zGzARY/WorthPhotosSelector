import XCTest
import PhotoCore
@testable import TravelSelect

@MainActor
final class ReviewFlowTests: XCTestCase {
    func model() throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let m = AppModel(sessionFile: root.appendingPathComponent("session.json"))
        for i in 0..<6 {
            let r = PhotoRecord(id: "\(i)", source: .folder, locator: "/fixture/\(i)", name: "\(i)")
            m.session.records.append(r)
            var a = AnalysisResult(cacheKey: VisionAnalyzer.cacheKey(r), status: .success, feature: Data([1]), aesthetics: Float(i) / 6)
            a.qualityComplete = true; m.session.analyses[r.id] = a
        }
        m.session.groups = [["0","1"],["2","3"],["4","5"]].map { PhotoGroup(members: $0, kind: .similar) }
        m.session.groupingComplete = true; m.refreshRecommendations(); m.chooseGroup(m.session.groups[0].id)
        return m
    }
    func testAdoptAdvancesSkipDefersAndUndoRestoresNavigation() throws {
        let m = try model(), first = m.session.groups[0].id, second = m.session.groups[1].id
        XCTAssertEqual(m.session.settings.groupingLevel, .balanced)
        m.acceptGroup()
        XCTAssertEqual(m.selectedGroupID, second); XCTAssertEqual(m.session.decisions["1"]?.choice, .keep)
        m.nextGroup()
        XCTAssertEqual(m.session.deferredIDs, ["2","3"])
        XCTAssertEqual(Set(m.selectionPlan.unresolvedIDs), ["2","3"])
        m.undo()
        XCTAssertEqual(m.selectedGroupID, second); XCTAssertTrue(m.session.deferredIDs?.isEmpty != false)
        m.undo()
        XCTAssertEqual(m.selectedGroupID, first); XCTAssertTrue(m.session.decisions.isEmpty)
    }
    func testFinalGroupFinishesAndDeferredRoundCanBeResumed() throws {
        let m = try model()
        m.nextGroup(); m.acceptGroup(); m.acceptGroup()
        XCTAssertTrue(m.reviewFinished); XCTAssertEqual(m.queue, "complete")
        m.resumeDeferred()
        XCTAssertFalse(m.reviewFinished); XCTAssertEqual(m.currentGroup?.members, ["0","1"])
        XCTAssertTrue(m.canAcceptGroup); m.acceptGroup()
        XCTAssertTrue(m.reviewFinished); XCTAssertTrue(m.session.deferredIDs!.isEmpty)
        XCTAssertTrue(m.selectionPlan.unresolvedIDs.isEmpty)
        m.undo(); XCTAssertFalse(m.reviewFinished); XCTAssertEqual(m.session.deferredIDs, ["0","1"])
    }
    func testFilteredAdvanceRetainsManualChoicesAndLocks() throws {
        let m = try model()
        m.session.groups[0].needsReview = true; m.session.groups[2].needsReview = true
        m.groupFilter = "attention"
        m.session.decide(["0"], choice: .keep, lock: true); m.session.decide(["1"], choice: .exclude)
        m.refreshRecommendations(); m.acceptGroup()
        XCTAssertEqual(m.currentGroup?.members, ["4","5"])
        XCTAssertEqual(m.session.decisions["0"], Decision(choice: .keep, locked: true))
        XCTAssertEqual(m.session.decisions["1"]?.choice, .exclude)
        m.undo(); XCTAssertEqual(m.currentGroup?.members, ["0","1"]); XCTAssertEqual(m.groupFilter, "attention")
    }
    func testUndoRetainsRecommendationUnitsInWideScene() throws {
        let m = try model()
        var wide = PhotoGroup(members: ["0","1","2","3","4","5"], kind: .similar)
        wide.recommendationUnits = [["0","1"],["2","3"],["4","5"]]
        m.session.groups = [wide]; m.chooseGroup(wide.id); m.refreshRecommendations()
        XCTAssertEqual(Set(m.selectionPlan.keepIDs), ["1","3","5"])
        m.acceptGroup(); m.undo()
        XCTAssertEqual(m.session.groups.first?.recommendationUnits, wide.recommendationUnits)
        XCTAssertEqual(Set(m.selectionPlan.keepIDs), ["1","3","5"])
    }
    func testPausedScanOnlyOutputsExplicitlyConfirmedGroup() throws {
        let m = try model(); m.session.groupingComplete = false; m.refreshRecommendations()
        XCTAssertFalse(m.canExport); XCTAssertTrue(m.canAcceptGroup)
        m.acceptGroup()
        XCTAssertTrue(m.canExport); XCTAssertEqual(m.selectionPlan.keepIDs, ["1"])
        XCTAssertEqual(Set(m.selectionPlan.unresolvedIDs), ["2","3","4","5"])
        XCTAssertTrue(m.selectionPlan.entries.filter { $0.disposition == .keep }.allSatisfy { $0.origin == .manual })
        m.undo(); XCTAssertFalse(m.canExport)
    }
    func testCameraReconnectAndRestartRetainGroupsAndReviewPositionWithoutStartingAnalysis() throws {
        let m = try model()
        let device = CameraSourceDescriptor(id: "device", name: "Camera", transport: .ptp)
        for i in m.session.records.indices { m.session.records[i].source = .camera }
        m.session.source = .camera; m.session.cameraSource = device; m.session.activeCameraIDs = Set(m.session.records.map(\.id))
        let group = m.session.groups[1]; m.chooseGroup(group.id); m.selectedIDs = ["2"]
        let groups = m.session.groups.map(\.id)
        m.loadingCamera = true; m.busy = true
        m.completeCameraConnection(device, records: m.session.activeRecords, restoring: true)
        XCTAssertFalse(m.busy); XCTAssertFalse(m.loadingCamera); XCTAssertNil(m.task)
        XCTAssertEqual(m.session.groupingComplete, true); XCTAssertEqual(m.session.groups.map(\.id), groups)
        XCTAssertEqual(m.selectedGroupID, group.id); XCTAssertEqual(m.selectedIDs, ["2"])
        try m.saveImmediately()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.json"); try SessionStore.save(m.session, to: file)
        let restarted = AppModel(sessionFile: file)
        XCTAssertEqual(restarted.selectedGroupID, group.id); XCTAssertEqual(restarted.selectedIDs, ["2"])
        XCTAssertNil(restarted.task); XCTAssertEqual(restarted.session.groups.map(\.id), groups)
    }
}
