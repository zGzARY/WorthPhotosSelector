import XCTest
import Photos
@testable import PhotoCore

final class ScopeAndGroupingTests: XCTestCase {
    func photo(_ id: String, seconds: Double = 10) -> PhotoRecord {
        PhotoRecord(id: id, source: .photos, locator: id, name: id, captureDate: Date(timeIntervalSince1970: seconds))
    }
    func range(_ start: Double, _ end: Double, album: String? = nil) throws -> PhotosScope {
        try PhotosScope(albumID: album, startDate: Date(timeIntervalSince1970: start), endDateExclusive: Date(timeIntervalSince1970: end), timeZoneIdentifier: "Asia/Shanghai")
    }
    func testAlbumDateIntersectionAndExclusiveEndUseSamePredicate() throws {
        let scope = try range(10, 20, album: "album-a")
        let options = try PhotoLibrarySource.fetchOptions(scope: scope)
        XCTAssertTrue(options.includeAllBurstAssets); XCTAssertFalse(options.includeHiddenAssets)
        for (time, expected) in [(9.999,false),(10,true),(19.999,true),(20,false)] {
            let object: NSDictionary = ["mediaType": PHAssetMediaType.image.rawValue, "hidden": false, "creationDate": Date(timeIntervalSince1970: time)]
            XCTAssertEqual(options.predicate!.evaluate(with: object), expected)
            XCTAssertEqual(scope.contains(Date(timeIntervalSince1970: time)), expected)
        }
        XCTAssertFalse(options.predicate!.evaluate(with: ["mediaType": PHAssetMediaType.video.rawValue, "hidden": false, "creationDate": Date(timeIntervalSince1970: 15)]))
        XCTAssertFalse(options.predicate!.evaluate(with: ["mediaType": PHAssetMediaType.image.rawValue, "hidden": true, "creationDate": Date(timeIntervalSince1970: 15)]))
        XCTAssertFalse(scope.contains(nil))
        XCTAssertTrue(try PhotosScope().contains(nil))
        XCTAssertThrowsError(try PhotosScope(startDate: Date()))
        XCTAssertThrowsError(try range(20, 10))
    }
    func testInclusiveCalendarDaysAcrossDST() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let scope = try PhotosScope.days(from: date, through: date, timeZone: zone)
        XCTAssertEqual(scope.endDateExclusive!.timeIntervalSince(scope.startDate!), 23 * 3600)
        XCTAssertTrue(scope.contains(scope.endDateExclusive!.addingTimeInterval(-0.001)))
        XCTAssertFalse(scope.contains(scope.endDateExclusive))
    }
    func testScopeReplacementEmptyScopeAndHistoricalDecisions() throws {
        var session = SelectionSession()
        let a = photo("a", seconds: 10), b = photo("b", seconds: 20), c = photo("c", seconds: 30)
        try session.applyPhotosScope(range(0, 40, album: "a"), records: [a,b,c])
        session.decide(["a", "b"], choice: .keep, lock: true)
        session.analyses["a"] = AnalysisResult(cacheKey: VisionAnalyzer.cacheKey(a), status: .success, feature: Data([1]))
        session.groups = [PhotoGroup(members: ["a","b","c"], kind: .similar)]
        try session.applyPhotosScope(range(20, 30, album: "a"), records: [b])
        XCTAssertEqual(session.activeRecords.map(\.id), ["b"])
        XCTAssertEqual(session.outputIDs(.keep), ["b"])
        XCTAssertEqual(session.decisions["a"]?.choice, .keep)
        XCTAssertNotNil(session.analyses["a"]?.feature)
        XCTAssertTrue(session.reviewGroups.isEmpty)
        let manifest = session.exportSnapshot()
        XCTAssertEqual(manifest.records.map(\.id), ["b"])
        XCTAssertNil(manifest.decisions["a"]); XCTAssertNil(manifest.analyses["a"])
        session.decide(["a"], choice: .exclude, lock: false)
        XCTAssertEqual(session.decisions["a"]?.choice, .keep)
        XCTAssertThrowsError(try session.applyPhotosScope(range(20, 30), records: [a]))
        XCTAssertEqual(session.activeRecords.map(\.id), ["b"])
        try session.applyPhotosScope(range(40, 50), records: [])
        XCTAssertTrue(session.activeRecords.isEmpty); XCTAssertTrue(session.outputIDs(.keep).isEmpty)
        try session.applyPhotosScope(range(0, 40), records: [a,b,c])
        XCTAssertEqual(Set(session.outputIDs(.keep)), ["a","b"])
    }
    func testSceneCrossDayMissingDateAndPendingAreSeparate() throws {
        var a = photo("a"), b = photo("b", seconds: 86410), c = photo("c", seconds: 172810)
        a.captureDate = nil; b.captureDate = nil
        let pending = photo("pending")
        let settings = AnalysisSettings()
        XCTAssertEqual(settings.mode, .scene)
        let groups = try Grouping.cluster(records: [a,b,c,pending], settings: settings, eligible: ["a","b","c"]) { x,y in
            Set([x,y]) == ["a","b"] ? 0.1 : 0.9
        }
        XCTAssertEqual(groups.map { $0.members.count }.sorted(), [1,2])
        XCTAssertFalse(groups.flatMap(\.members).contains("pending"))
        let dated = try Grouping.cluster(records: [photo("one"), photo("two", seconds: 86410)], settings: settings, eligible: ["one","two"]) { _,_ in 0.1 }
        XCTAssertEqual(dated.first?.members.count, 2)
    }
    func testMoreThan1000WithoutTruncationAndCancellation() throws {
        let records = (0..<1201).map { photo(String($0)) }
        let ids = Set(records.map(\.id))
        let groups = try Grouping.cluster(records: records, settings: AnalysisSettings(), eligible: ids) { a,b in
            Int(a)! / 2 == Int(b)! / 2 ? 0.1 : 0.9
        }
        XCTAssertEqual(Set(groups.flatMap(\.members)), ids)
        XCTAssertEqual(groups.flatMap(\.members).count, records.count)
        XCTAssertEqual(groups.filter { $0.members.count == 2 }.count, 600)
        var calls = 0
        XCTAssertThrowsError(try Grouping.cluster(records: records, settings: AnalysisSettings(), eligible: ids, cancelled: { calls += 1; return calls > 50 }) { _,_ in 0.1 })
    }
    func testPartialResultNeedsFeatureAndCorruptCacheIsQuarantined() async {
        let record = photo("a")
        var partial = AnalysisResult(cacheKey: VisionAnalyzer.cacheKey(record), status: .partial, aesthetics: 0.5)
        partial.qualityComplete = true
        XCTAssertTrue(VisionAnalyzer.needsAnalysis(record, result: partial))
        partial.feature = Data([1,2,3])
        let engine = VisualGroupingEngine(settings: AnalysisSettings())
        let update = await engine.add(record, result: partial)
        XCTAssertTrue(update.groups.isEmpty); XCTAssertEqual(update.invalidFeatureIDs, [record.id])
        partial.feature = nil
        XCTAssertTrue(VisionAnalyzer.needsAnalysis(record, result: partial))
    }
    func testLegacyMigrationAndNewScopeRoundTrip() throws {
        var session = SelectionSession(); let record = photo("a")
        try session.applyPhotosScope(range(0, 30), records: [record]); session.decide(["a"], choice: .keep, lock: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("session.json")
        try SessionStore.save(session, to: file)
        let restored = try SessionStore.load(from: file)
        XCTAssertEqual(restored.photosScope, session.photosScope)
        XCTAssertEqual(restored.activeRecords.map(\.id), ["a"])
        var json = try JSONSerialization.jsonObject(with: SessionStore.data(session)) as! [String: Any]
        json["schema"] = 1
        for key in ["photosScope","activePhotoIDs","groupingComplete"] { json.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let migrated = try SessionStore.load(from: file)
        XCTAssertTrue(migrated.requiresPhotosScope); XCTAssertTrue(migrated.activeRecords.isEmpty)
        XCTAssertEqual(migrated.decisions["a"], session.decisions["a"])
        XCTAssertEqual(migrated.records.count, 1)
    }
}
