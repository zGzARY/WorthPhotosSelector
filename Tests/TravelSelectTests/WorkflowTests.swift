import XCTest
import CoreGraphics
import PhotoCore
@testable import TravelSelect

@MainActor
final class WorkflowTests: XCTestCase {
    func model() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TravelSelectWorkflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AppModel(sessionFile: directory.appendingPathComponent("session.json"))
    }
    func testUnreadableSessionIsNotOverwrittenOnSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TravelSelectRecovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let original = Data("broken JSON preserved for recovery".utf8)
        try original.write(to: file)
        let model = AppModel(sessionFile: file)
        XCTAssertNotNil(model.message)
        try model.saveImmediately()
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func records() -> [PhotoRecord] {
        [0,1].map { PhotoRecord(id: "synthetic-\($0)", source: .photos, locator: "synthetic-\($0)", name: "synthetic", captureDate: Date(timeIntervalSince1970: Double($0) * 30 + 100), width: 256, height: 256) }
    }
    func seed(_ model: AppModel, records: [PhotoRecord]) async throws {
        let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        context.setFillColor(CGColor(red: 1, green: 0.7, blue: 0.1, alpha: 1)); context.fillEllipse(in: CGRect(x: 80, y: 40, width: 100, height: 100))
        let result = await VisionAnalyzer.analyze(context.makeImage()!, record: records[0])
        XCTAssertNotNil(result.feature, result.issues.joined(separator: "; "))
        guard result.feature != nil else { throw PhotoError.message("Synthetic Vision fixture failed") }
        for record in records {
            var cached = result; cached.cacheKey = VisionAnalyzer.cacheKey(record); cached.qualityComplete = true
            model.session.analyses[record.id] = cached
        }
    }
    func testRangeCommitAutomaticallyGroupsAndScopeSwitchRemovesOldItems() async throws {
        let model = try model(), records = records()
        try await seed(model, records: records)
        try model.applyLoadedPhotos(records, scope: PhotosScope(albumID: "synthetic-album"))
        XCTAssertTrue(model.busy)
        await model.task?.value
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.session.reviewGroups.count, 1)
        XCTAssertEqual(model.session.reviewGroups.first?.members.count, 2)
        model.session.decide([records[0].id], choice: .keep, lock: true)
        model.selectedIDs = Set(records.map(\.id)); model.mergeIDs = Set(model.session.reviewGroups.map(\.id)); model.snapshot()
        let narrow = try PhotosScope(startDate: Date(timeIntervalSince1970: 120), endDateExclusive: Date(timeIntervalSince1970: 160))
        try model.applyLoadedPhotos([records[1]], scope: narrow)
        await model.task?.value
        XCTAssertEqual(model.session.activeRecords.map(\.id), [records[1].id])
        XCTAssertTrue(model.selectedIDs.isEmpty); XCTAssertTrue(model.mergeIDs.isEmpty); XCTAssertTrue(model.undoStack.isEmpty)
        XCTAssertTrue(model.session.reviewGroups.isEmpty)
        XCTAssertEqual(model.session.unmatchedRecords.count, 1)
        XCTAssertTrue(model.session.outputIDs(.keep).isEmpty)
        XCTAssertEqual(model.session.decisions[records[0].id]?.choice, .keep)
        try model.saveImmediately()
        let saved = model.session.photosScope
        XCTAssertEqual(saved, narrow)
    }
    func testCancellationPreservesFeatureGroupsAndCanResume() async throws {
        let model = try model(), records = records()
        try await seed(model, records: records)
        try model.applyLoadedPhotos(records, scope: PhotosScope())
        model.cancel()
        await model.task?.value
        XCTAssertFalse(model.busy); XCTAssertEqual(model.session.groupingComplete, false)
        XCTAssertEqual(model.session.reviewGroups.count, 1)
        XCTAssertTrue(records.allSatisfy(model.session.hasFeature))
        model.analyze()
        await model.task?.value
        XCTAssertEqual(model.session.groupingComplete, true)
        XCTAssertEqual(model.session.reviewGroups.count, 1)
        try model.saveImmediately()
    }
    func testLatePreviousPipelineCannotOverwriteNewEmptyRange() async throws {
        let model = try model(), records = records()
        try await seed(model, records: records)
        try model.applyLoadedPhotos(records, scope: PhotosScope())
        let previous = model.task
        let empty = try PhotosScope(albumID: "empty-album")
        try model.applyLoadedPhotos([], scope: empty)
        await previous?.value
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.session.photosScope, empty)
        XCTAssertTrue(model.session.reviewGroups.isEmpty)
        XCTAssertTrue(model.visibleRecords.isEmpty)
        try model.saveImmediately()
    }
}
