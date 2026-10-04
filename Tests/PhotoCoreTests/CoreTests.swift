import XCTest
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import PhotoCore

final class CoreTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TravelSelectTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func image(width: Int = 800, height: Int = 600) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            context.setFillColor(CGColor(red: CGFloat(y) / CGFloat(height), green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        context.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 100, y: 100, width: 220, height: 220))
        return context.makeImage()!
    }
    func writeImage(_ url: URL, orientation: Int = 1, dated: Bool = true) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.92]
        if dated {
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:10:01 12:30:00",
                kCGImagePropertyExifOffsetTimeOriginal: "+08:00", kCGImagePropertyExifSubsecTimeOriginal: "125"]
        }
        CGImageDestinationAddImage(destination, image(), props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    func record(_ id: String, time: Double? = 0) -> PhotoRecord {
        PhotoRecord(id: id, source: .folder, locator: "/synthetic/" + id, name: id, captureDate: time.map { Date(timeIntervalSince1970: $0) })
    }
    func testExactDuplicateAndSourceSafety() throws {
        let root = try temporary(), input = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
        let a = input.appendingPathComponent("a.jpg"), b = input.appendingPathComponent("b.jpg"), c = input.appendingPathComponent("c.jpg")
        try writeImage(a); try FileManager.default.copyItem(at: a, to: b)
        try writeImage(c, orientation: 6)
        let before = try [a,b,c].map { try FolderSource.sha256($0) }
        let records = try FolderSource.scan([input, input])
        XCTAssertEqual(records.count, 3)
        let exact = try FolderSource.exactGroups(records).filter { $0.kind == .exact }
        XCTAssertEqual(exact.count, 1); XCTAssertEqual(exact[0].members.count, 2)
        XCTAssertEqual(try [a,b,c].map { try FolderSource.sha256($0) }, before)
    }
    func testOrientationTimeAndCorruption() throws {
        let root = try temporary(), rotated = root.appendingPathComponent("rotated.jpg")
        try writeImage(rotated, orientation: 6)
        let r = try FolderSource.inspect(rotated), decoded = try FolderSource.decode(rotated)
        XCTAssertEqual(r.orientation, 6); XCTAssertEqual(decoded.width, 600); XCTAssertEqual(decoded.height, 800)
        XCTAssertNotNil(r.captureDate)
        XCTAssertEqual(r.captureDate!.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.125, accuracy: 0.001)
        let nodate = root.appendingPathComponent("nodate.jpg"); try writeImage(nodate, dated: false)
        XCTAssertNil(try FolderSource.inspect(nodate).captureDate)
        let corrupt = root.appendingPathComponent("corrupt.jpg"); try Data("not an image".utf8).write(to: corrupt)
        XCTAssertThrowsError(try FolderSource.decode(corrupt))
        XCTAssertNil(AnalysisResult(status: .failed).aesthetics)
        XCTAssertNil(FaceMeasure(x: 0, y: 0, width: 1, height: 1, quality: nil).quality)
    }
    func testCompleteLinkAndWholeSpan() throws {
        let records = [record("a", time: 0), record("b", time: 30), record("c", time: 59)]
        var settings = AnalysisSettings(); settings.mode = .travel; settings.distance = 0.5
        let groups = try Grouping.cluster(records: records, settings: settings, eligible: ["a","b","c"]) { a,b in Set([a,b]) == Set(["a","c"]) ? 0.9 : 0.2 }
        XCTAssertEqual(groups.map { $0.members.count }.sorted(), [1,2])
        let far = [record("a", time: 0), record("b", time: 50), record("c", time: 100)]
        XCTAssertEqual(try Grouping.cluster(records: far, settings: settings, eligible: ["a","b","c"]) { _,_ in 0.1 }.count, 2)
        XCTAssertEqual(try Grouping.cluster(records: [record("x", time: nil), record("y", time: nil)], settings: settings, eligible: ["x","y"]) { _,_ in 0 }.count, 2)
        settings.mode = .visualOnly
        XCTAssertEqual(try Grouping.cluster(records: (0...1000).map { record("\($0)") }, settings: settings, eligible: []) { _,_ in 0 }.count, 0)
    }
    func testDecisionPersistenceLockAndRecomputation() throws {
        let root = try temporary(); var session = SelectionSession()
        session.importRecords([record("a"), record("b"), record("c")])
        let g = PhotoGroup(members: ["a","b","c"], kind: .similar); session.groups = [g]
        session.analyses["a"] = AnalysisResult(status: .success, aesthetics: 0.7)
        session.analyses["b"] = AnalysisResult(status: .success, aesthetics: 0.5)
        session.analyses["c"] = AnalysisResult(status: .partial)
        session.decide(["b"], choice: .exclude)
        session.decide(["c"], choice: .keep, lock: true)
        session.recommendations = Grouping.recommend(session: session)
        session.accept(g); session.decide(["c"], choice: .exclude)
        XCTAssertEqual(session.decisions["b"]?.choice, .exclude)
        XCTAssertEqual(session.decisions["c"]?.choice, .keep)
        let decisions = session.decisions
        session.settings.distance = 0.15; session.settings.recommendationCount = 1
        session.recommendations = Grouping.recommend(session: session)
        session.replaceGroups([PhotoGroup(members: ["a","b"], kind: .similar), PhotoGroup(members: ["c"], kind: .single)])
        XCTAssertEqual(session.decisions, decisions); XCTAssertTrue(session.groups[0].needsReview)
        let file = root.appendingPathComponent("session.json"); try SessionStore.save(session, to: file)
        let restored = try SessionStore.load(from: file)
        XCTAssertEqual(restored.decisions, decisions); XCTAssertFalse(restored.outputIDs(.exclude).contains("c"))
    }
    func testSafeExportCollisionFailureCancelAndSourceHashes() throws {
        let root = try temporary()
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for folder in [a,b] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false); try writeImage(folder.appendingPathComponent("same.jpg")) }
        var session = SelectionSession(); session.importRecords(try FolderSource.scan([a,b]))
        let ids = session.records.map(\.id); session.decide(ids, choice: .keep)
        let before = try session.records.map { try FolderSource.sha256(URL(fileURLWithPath: $0.locator)) }
        let dest = root.appendingPathComponent("out")
        let report = SafeExport.copy(session: session, destination: dest)
        XCTAssertEqual(report.copiedCount, 2); XCTAssertTrue(report.manifestSaved); XCTAssertEqual(Set(report.items.compactMap(\.destination)).count, 2)
        XCTAssertEqual(try session.records.map { try FolderSource.sha256(URL(fileURLWithPath: $0.locator)) }, before)
        XCTAssertEqual(SafeExport.copy(session: session, destination: dest).copiedCount, 0)
        let cancelled = SafeExport.copy(session: session, destination: root.appendingPathComponent("cancelled"), cancelled: { true })
        XCTAssertTrue(cancelled.cancelled); XCTAssertEqual(cancelled.copiedCount, 0)
        XCTAssertTrue(cancelled.items.allSatisfy { $0.state == "cancelled" })
        session.decide([ids[0]], choice: .unreviewed)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: session.records[1].locator))
        let failed = SafeExport.copy(session: session, destination: root.appendingPathComponent("failed"))
        XCTAssertEqual(failed.items.count, 1); XCTAssertEqual(failed.items.first?.state, "failed")
    }
    func testSkipPackagesSymlinksAndExportFolders() throws {
        let root = try temporary(), library = root.appendingPathComponent("never.photoslibrary"), output = root.appendingPathComponent("output")
        for folder in [library, output] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false); try writeImage(folder.appendingPathComponent("a.jpg")) }
        try Data().write(to: output.appendingPathComponent(".travel-select-output"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        XCTAssertEqual(try FolderSource.scan([root]).count, 0)
        XCTAssertThrowsError(try FolderSource.scan([library]))
    }
    func testRejectedExportDestinationIsUntouched() throws {
        let root = try temporary(), existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let result = SafeExport.copy(session: SelectionSession(), destination: existing)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: existing.path).isEmpty)
        let forbidden = root.appendingPathComponent("untouched.photoslibrary/result")
        XCTAssertFalse(SafeExport.copy(session: SelectionSession(), destination: forbidden).errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbidden.deletingLastPathComponent().path))
    }
    func testRealVisionFolderEndToEnd() async throws {
        let root = try temporary(), input = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
        let a = input.appendingPathComponent("one.jpg"), b = input.appendingPathComponent("two.jpg")
        try writeImage(a); try FileManager.default.copyItem(at: a, to: b)
        var session = SelectionSession(); session.importRecords(try FolderSource.scan([input]))
        for record in session.records {
            let result = await VisionAnalyzer.analyze(try FolderSource.decode(URL(fileURLWithPath: record.locator)), record: record)
            XCTAssertNotNil(result.feature, result.issues.joined(separator: ";"))
            XCTAssertNotNil(result.aesthetics, result.issues.joined(separator: ";"))
            XCTAssertEqual(result.status, .success, result.issues.joined(separator: ";"))
            if let score = result.aesthetics { XCTAssertTrue((-1...1).contains(score)) }
            session.analyses[record.id] = result
        }
        session.groups = try Grouping.groups(session: session); session.groupingComplete = true
        XCTAssertEqual(session.groups.count, 1)
        session.recommendations = Grouping.recommend(session: session)
        session.accept(session.groups[0])
        let report = SafeExport.copy(session: session, destination: root.appendingPathComponent("selected"))
        XCTAssertEqual(report.copiedCount, 1); XCTAssertTrue(report.manifestSaved)
    }
    func testMissingScoresRemainUnreviewedAndFavoriteProtected() {
        var s = SelectionSession()
        var favorite = record("favorite"); favorite.favorite = true
        s.importRecords([record("failed"), record("good"), favorite])
        s.groups = [PhotoGroup(members: ["failed", "good", "favorite"], kind: .similar)]
        s.analyses["failed"] = AnalysisResult(status: .cloudUnavailable)
        s.analyses["good"] = AnalysisResult(status: .success, aesthetics: 0.3)
        s.recommendations = Grouping.recommend(session: s)
        s.accept(s.groups[0])
        XCTAssertNil(s.decisions["failed"])
        XCTAssertNil(s.decisions["good"], "An incomplete group must not automatically reject or select other members")
        s.decide(["favorite"], choice: .exclude)
        XCTAssertFalse(s.outputIDs(.exclude).contains("favorite"))
        s.decide(["favorite"], choice: .unreviewed, lock: false)
        s.importRecords([favorite])
        XCTAssertEqual(s.decisions["favorite"]?.locked, false)
    }
    func testSessionDatesPreserveCacheFingerprint() throws {
        var s = SelectionSession(); var r = record("fraction")
        r.modified = Date(timeIntervalSince1970: 1760000000.123456)
        s.records = [r]
        let url = try temporary().appendingPathComponent("session.json")
        try SessionStore.save(s, to: url)
        XCTAssertEqual(try SessionStore.load(from: url).records[0].fingerprint, r.fingerprint)
    }
    func testImageCallbackGateFinishesExactlyOnceAndEarlyCancellation() {
        let gate = ImageRequestGate(); var calls = 0
        gate.install { _ in calls += 1 }
        XCTAssertTrue(gate.finish(.failure(CancellationError())))
        XCTAssertFalse(gate.finish(.success(image())))
        XCTAssertEqual(calls, 1)
        let early = ImageRequestGate(); early.finish(.failure(CancellationError()))
        early.install { result in if case .failure = result { calls += 1 } }
        XCTAssertEqual(calls, 2)
    }
    func testPhotosModeDoesNotHashPreviewsAndStaleDecisionsExcluded() throws {
        var s = SelectionSession(); s.source = .photos; s.settings.mode = .exact
        XCTAssertThrowsError(try Grouping.groups(session: s))
        var r = record("one"); r.source = .photos; try s.applyPhotosScope(PhotosScope(), records: [r]); s.decide(["one"], choice: .keep)
        let first = PhotoLibrarySource.outputToken(session: s, includeExcluded: false)
        XCTAssertEqual(first, PhotoLibrarySource.outputToken(session: s, includeExcluded: false))
        r.modified = Date(); s.importRecords([r])
        XCTAssertEqual(s.decisions["one"]?.choice, .keep)
        XCTAssertTrue(s.outputIDs(.keep).isEmpty)
    }
}
