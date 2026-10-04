import XCTest
@testable import PhotoCore

private actor ImportTestLibrary: OriginalImportLibrary {
    enum Failure { case none, reject, ambiguous, committedThenThrow }
    var failure: Failure = .none
    var failAttempt = 0
    var attempts = 0
    var albumCalls = 0
    var assets: Set<String> = []
    var payloads: [[Data]] = []
    var resourceKinds: [[Bool]] = []
    func configure(_ failure: Failure, at attempt: Int) { self.failure = failure; failAttempt = attempt }
    func counts() -> (Int, Int) { (attempts, assets.count) }
    func allPayloads() -> [[Data]] { payloads }
    func kinds() -> [[Bool]] { resourceKinds }
    func removeAll() { assets = [] }
    func album(name: String, existingID: String?, prepared: @escaping @Sendable (String?) throws -> Void) async throws -> String {
        albumCalls += 1; try prepared("test-album"); return "test-album"
    }
    func contains(assetID: String, albumID: String) async throws -> Bool { assets.contains(assetID) }
    func recover(resources: [ImportResourceDigest], albumID: String) async throws -> String? { nil }
    func insert(_ photo: MaterializedPhoto, record: PhotoRecord, albumID: String, prepared: @escaping @Sendable (String) throws -> Void) async throws -> String {
        attempts += 1
        let id = "asset-\(attempts)"; try prepared(id)
        if attempts == failAttempt {
            if failure == .reject { throw OriginalImportFailure.rejected("Fixture rejected transaction") }
            if failure == .ambiguous { throw PhotoError.message("Fixture unknown transaction outcome") }
        }
        payloads.append(try photo.files.map { try Data(contentsOf: $0) })
        resourceKinds.append(photo.resources.map(\.isRaw)); assets.insert(id)
        if attempts == failAttempt && failure == .committedThenThrow { throw PhotoError.message("Fixture response lost after commit") }
        return id
    }
}
private actor ImportTestStager {
    var calls = 0
    var temporary: [URL] = []
    func load(_ record: PhotoRecord) async throws -> MaterializedPhoto {
        calls += 1
        let original = try await PhotoSource.materialize(record)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImportFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); temporary.append(root)
        var files: [URL] = []
        for (i, file) in original.files.enumerated() {
            let copy = root.appendingPathComponent("\(i)-" + file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: copy); files.append(copy)
        }
        return MaterializedPhoto(files: files, resources: original.resources, temporaryDirectory: root)
    }
    func count() -> Int { calls }
    func cleaned() -> Bool { temporary.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
}
private final class ImportTestStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
final class OriginalImportTests: XCTestCase {
    func fixture(count: Int = 2) throws -> (SelectionSession, URL, [[Data]]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var records: [PhotoRecord] = [], bytes: [[Data]] = []
        for i in 0..<count {
            let pair = [Data("original JPEG \(i)".utf8), Data("original RAW \(i)".utf8)]; bytes.append(pair)
            var resources: [OriginalPhotoResource] = []
            for j in 0..<2 {
                let file = root.appendingPathComponent("DSCF\(i)." + (j == 0 ? "JPG" : "RAF"))
                try pair[j].write(to: file)
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                resources.append(OriginalPhotoResource(id: "\(i)-\(j)", locator: file.path, name: file.lastPathComponent,
                    byteSize: Int64(values.fileSize!), modified: values.contentModificationDate, isRaw: j == 1))
            }
            var record = PhotoRecord(id: "\(i)", source: .camera, locator: "\(i)", name: "DSCF\(i)")
            record.external = ExternalPhotoReference(deviceID: "fixture", transport: .storage, resources: resources)
            records.append(record)
        }
        var session = SelectionSession()
        session.applyCameraRecords(records, descriptor: CameraSourceDescriptor(id: "fixture", name: "Test card", transport: .storage), complete: true)
        session.groupingComplete = true; session.decide(records.map(\.id), choice: .keep)
        return (session, root.appendingPathComponent("journal.json"), bytes)
    }
    private func run(_ session: SelectionSession, _ journal: URL, _ library: ImportTestLibrary, _ stager: ImportTestStager) async throws -> AlbumReceipt {
        try await OriginalPhotoImporter.run(session: session, plan: SelectionPlan.make(session: session), name: "Test result", token: "test-token", journalURL: journal,
            library: library, materialize: { try await stager.load($0) })
    }
    func testPairBytesPreservedAndRepeatedImportNeverDownloadsOrCreatesAgain() async throws {
        let (session, journal, expected) = try fixture(), library = ImportTestLibrary(), stager = ImportTestStager()
        let first = try await run(session, journal, library, stager)
        XCTAssertEqual(first.importedIDs?.count, 2)
        let second = try await run(session, journal, library, stager)
        XCTAssertEqual(second.importedIDs, first.importedIDs)
        let counts = await library.counts(), downloads = await stager.count(), cleaned = await stager.cleaned()
        let bytes = await library.allPayloads(), kinds = await library.kinds()
        XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 2); XCTAssertEqual(downloads, 2); XCTAssertTrue(cleaned)
        XCTAssertEqual(bytes, expected); XCTAssertEqual(kinds, [[false,true],[false,true]])
        for (i, record) in session.records.enumerated() {
            let original = try await PhotoSource.materialize(record); original.cleanup()
            XCTAssertEqual(try original.files.map { try Data(contentsOf: $0) }, expected[i])
        }
    }
    func testPartialFailureRetriesOnlyTheRejectedItemAndCleansStaging() async throws {
        let (session, journal, _) = try fixture(), library = ImportTestLibrary(), stager = ImportTestStager()
        await library.configure(.reject, at: 2)
        do { _ = try await run(session, journal, library, stager); XCTFail("Expected rejected second transaction") } catch {}
        let saved = try JSONDecoder().decode(OriginalImportJournal.self, from: Data(contentsOf: journal))
        XCTAssertEqual(saved.entries["0"]?.complete, true); XCTAssertNil(saved.entries["1"]?.assetID)
        let clean = await stager.cleaned(); XCTAssertTrue(clean)
        let result = try await run(session, journal, library, stager), counts = await library.counts()
        XCTAssertEqual(result.importedIDs?.count, 2); XCTAssertEqual(counts.0, 3); XCTAssertEqual(counts.1, 2)
    }
    func testAmbiguousSubmissionStopsWithoutDuplicating() async throws {
        let (session, journal, _) = try fixture(count: 1), library = ImportTestLibrary(), stager = ImportTestStager()
        await library.configure(.ambiguous, at: 1)
        for _ in 0..<2 {
            do { _ = try await run(session, journal, library, stager); XCTFail("Expected unresolved transaction") } catch {}
        }
        let attempts = await library.counts(), downloads = await stager.count(), clean = await stager.cleaned()
        XCTAssertEqual(attempts.0, 1); XCTAssertEqual(downloads, 1); XCTAssertFalse(clean, "Ambiguous submissions retain staging until reconciliation")
    }
    func testLostResponseRecoversCommittedAssetAndMissingConfirmedAssetIsNotRecreated() async throws {
        let (session, journal, _) = try fixture(count: 1), library = ImportTestLibrary(), stager = ImportTestStager()
        await library.configure(.committedThenThrow, at: 1)
        do { _ = try await run(session, journal, library, stager); XCTFail("Expected lost response") } catch {}
        let recovered = try await run(session, journal, library, stager)
        XCTAssertEqual(recovered.importedIDs?.count, 1)
        await library.removeAll()
        do { _ = try await run(session, journal, library, stager); XCTFail("Must not recreate a user-removed asset") } catch {}
        let calls = await stager.count(); XCTAssertEqual(calls, 1)
    }
    func testCancellationKeepsCompletedImportAndResumesRemainder() async throws {
        let (session, journal, _) = try fixture(), library = ImportTestLibrary(), stager = ImportTestStager(), flag = ImportTestStop()
        do {
            _ = try await OriginalPhotoImporter.run(session: session, plan: SelectionPlan.make(session: session), name: "Test result", token: "test-token", journalURL: journal,
                library: library, materialize: { try await stager.load($0) }, cancelled: { flag.value },
                progress: { done,_,_ in if done == 1 { flag.stop() } })
            XCTFail("Expected cancellation between assets")
        } catch is CancellationError {} catch { XCTFail(error.localizedDescription) }
        let before = await stager.count(); XCTAssertEqual(before, 1)
        let receipt = try await run(session, journal, library, stager), after = await stager.count()
        XCTAssertEqual(after, 2); XCTAssertEqual(receipt.importedIDs?.count, 2)
    }
    func testChangedSourceFailsBeforePhotosInsertion() async throws {
        let (session, journal, _) = try fixture(count: 1), library = ImportTestLibrary(), stager = ImportTestStager()
        let raw = session.records[0].external!.resources[1]
        try Data("changed resource bytes".utf8).write(to: URL(fileURLWithPath: raw.locator))
        do { _ = try await run(session, journal, library, stager); XCTFail("Expected changed original") } catch {}
        let counts = await library.counts(); XCTAssertEqual(counts.0, 0)
    }
    func testBrokenRawTransferNeverCommitsJPEGOnlyAndRetryKeepsBothResources() async throws {
        let (s, journal, expected) = try fixture(count: 1), library = ImportTestLibrary(), stager = ImportTestStager()
        do {
            _ = try await OriginalPhotoImporter.run(session: s, plan: SelectionPlan.make(session: s), name: "Test result", token: "test-token", journalURL: journal,
                library: library, materialize: { record in
                    let original = try await PhotoSource.materialize(record)
                    _ = try Data(contentsOf: original.files[0])
                    throw PhotoError.message("相机在 RAW 传输时断开")
                })
            XCTFail("Expected failed pair transfer")
        } catch {}
        let before = await library.counts(); XCTAssertEqual(before.0, 0)
        XCTAssertTrue(try OriginalPhotoImporter.journal(at: journal).entries.isEmpty)
        _ = try await run(s, journal, library, stager)
        let kinds = await library.kinds(), bytes = await library.allPayloads()
        XCTAssertEqual(kinds, [[false,true]]); XCTAssertEqual(bytes, expected)
    }
    func testRebaseSelectionReusesCompletedAssetsAndKeepsThePriorJournal() async throws {
        var (s, journal, _) = try fixture(count: 4)
        s.decide(["3"], choice: .exclude)
        let library = ImportTestLibrary(), stager = ImportTestStager(), stop = ImportTestStop()
        do {
            _ = try await OriginalPhotoImporter.run(session: s, plan: SelectionPlan.make(session: s), name: "Test result", token: "old", journalURL: journal,
                library: library, materialize: { try await stager.load($0) }, cancelled: { stop.value },
                progress: { n,_,_ in if n == 1 { stop.stop() } })
            XCTFail("Expected interrupted import")
        } catch is CancellationError {}
        let priorBytes = try Data(contentsOf: journal)
        s.decide(["2"], choice: .exclude); s.decide(["3"], choice: .keep)
        let replacement = journal.deletingLastPathComponent().appendingPathComponent("new-journal.json")
        let rebased = try await OriginalPhotoImporter.rebase(session: s, plan: SelectionPlan.make(session: s), oldToken: "old", newToken: "new",
            sourceURL: journal, targetURL: replacement, library: library)
        XCTAssertEqual(rebased.albumID, "test-album"); XCTAssertEqual(rebased.entries["0"]?.complete, true)
        XCTAssertEqual(try Data(contentsOf: journal), priorBytes)
        let receipt = try await OriginalPhotoImporter.run(session: s, plan: SelectionPlan.make(session: s), name: "Test result", token: "new", journalURL: replacement,
            library: library, materialize: { try await stager.load($0) })
        XCTAssertEqual(Set(receipt.importedIDs!.keys), ["0","1","3"])
        let downloads = await stager.count(); XCTAssertEqual(downloads, 3)
        // Simulate a crash before the session pointer switches to the new journal.
        let recovered = try await OriginalPhotoImporter.rebase(session: s, plan: SelectionPlan.make(session: s), oldToken: "old", newToken: "new",
            sourceURL: journal, targetURL: replacement, library: library)
        XCTAssertEqual(recovered.entries.filter { $0.value.complete }.count, 3)
        _ = try await OriginalPhotoImporter.run(session: s, plan: SelectionPlan.make(session: s), name: "Test result", token: "new", journalURL: replacement,
            library: library, materialize: { try await stager.load($0) })
        let afterRecovery = await stager.count(); XCTAssertEqual(afterRecovery, 3)
    }
    func testRemovedAlbumReusesSurvivingAssetAndReimportsOnlyDeletedAsset() async throws {
        let (s, source, _) = try fixture(), stager = ImportTestStager(), library = RemovedAlbumLibrary()
        var prior = OriginalImportJournal(token: "old", albumName: "Removed album"); prior.albumID = "deleted-album"
        for record in s.records {
            prior.entries[record.id] = OriginalImportEntry(fingerprint: record.fingerprint, resources: [], assetID: "old-" + record.id, complete: true)
        }
        try JSONEncoder().encode(prior).write(to: source)
        let bytes = try Data(contentsOf: source), target = source.deletingLastPathComponent().appendingPathComponent("reexport.json")
        let replacement = try await OriginalPhotoImporter.rebase(session: s, plan: SelectionPlan.make(session: s), oldToken: "old", newToken: "new", sourceURL: source, targetURL: target, replacementAlbumName: "New album", library: library)
        XCTAssertEqual(replacement.entries["0"]?.assetID, "old-0"); XCTAssertEqual(replacement.entries["0"]?.complete, true)
        XCTAssertNil(replacement.entries["1"]?.assetID); XCTAssertEqual(replacement.entries["1"]?.complete, false)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        _ = try await OriginalPhotoImporter.run(session: s, plan: SelectionPlan.make(session: s), name: "New album", token: "new", journalURL: target, library: library, materialize: { try await stager.load($0) })
        // Crash before switching the session pointer: retain new progress and
        // restore membership without a second creation or camera download.
        let recovered = try await OriginalPhotoImporter.rebase(session: s, plan: SelectionPlan.make(session: s), oldToken: "old", newToken: "new", sourceURL: source, targetURL: target, replacementAlbumName: "New album", library: library)
        XCTAssertEqual(recovered.entries.filter { $0.value.complete }.count, 2)
        let count = await stager.count(); XCTAssertEqual(count, 1)
        let albumCreations = await library.creations; XCTAssertEqual(albumCreations, 1)
    }
    func testRebaseRefusesUnknownSubmissionEvenIfItWasDeselected() async throws {
        var (s, journal, _) = try fixture(), library = ImportTestLibrary(), stager = ImportTestStager()
        await library.configure(.ambiguous, at: 1)
        do { _ = try await run(s, journal, library, stager); XCTFail("Expected unknown submission") } catch {}
        s.decide(["0"], choice: .exclude)
        let target = journal.deletingLastPathComponent().appendingPathComponent("replacement.json")
        do {
            _ = try await OriginalPhotoImporter.rebase(session: s, plan: SelectionPlan.make(session: s), oldToken: "test-token", newToken: "replacement", sourceURL: journal, targetURL: target, library: library)
            XCTFail("Cannot abandon an unknown transaction")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let counts = await library.counts(); XCTAssertEqual(counts.0, 1)
    }
    func testLatePhotoCommitAfterDeadlineIsRecoveredWithoutAnotherDownload() async throws {
        let (s, journal, _) = try fixture(count: 1)
        let library = LateImportLibrary(), stager = ImportTestStager()
        do {
            _ = try await OriginalPhotoImporter.run(session: s, plan: SelectionPlan.make(session: s), name: "Test result", token: "test-token", journalURL: journal,
                library: library, materialize: { try await stager.load($0) })
            XCTFail("Expected deadline")
        } catch {}
        let staged = await stager.cleaned(); XCTAssertFalse(staged)
        await library.finishCommit()
        let receipt = try await OriginalPhotoImporter.run(session: s, plan: SelectionPlan.make(session: s), name: "Test result", token: "test-token", journalURL: journal,
            library: library, materialize: { try await stager.load($0) })
        XCTAssertEqual(receipt.importedIDs?.count, 1)
        let downloads = await stager.count(), clean = await stager.cleaned()
        XCTAssertEqual(downloads, 1); XCTAssertTrue(clean)
    }
    func testDeadlineCancellationCancelsResourceReadAndIgnoresLateCallback() async throws {
        let box = DeadlineTestBox()
        let task = Task { () -> Int in
            try await ImportDeadline.wait(timeout: .seconds(10), message: "timeout") { done in
                box.install(done); return { box.cancel() }
            }
        }
        while !box.started { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        box.finish(9); box.finish(10)
        XCTAssertEqual(box.cancellations, 1)
    }
    func testPartialAnalysisImportsOnlyManualSelection() async throws {
        var (session, journal, _) = try fixture()
        session.groupingComplete = false; session.decide(["1"], choice: .unreviewed)
        let library = ImportTestLibrary(), stager = ImportTestStager()
        let receipt = try await run(session, journal, library, stager)
        XCTAssertEqual(Set(receipt.importedIDs!.keys), ["0"])
        let counts = await library.counts(); XCTAssertEqual(counts.0, 1)
    }
}

private actor LateImportLibrary: OriginalImportLibrary {
    var committed = false
    func finishCommit() { committed = true }
    func album(name: String, existingID: String?, prepared: @escaping @Sendable (String?) throws -> Void) async throws -> String { try prepared("album"); return "album" }
    func contains(assetID: String, albumID: String) async throws -> Bool { committed }
    func recover(resources: [ImportResourceDigest], albumID: String) async throws -> String? { nil }
    func insert(_ photo: MaterializedPhoto, record: PhotoRecord, albumID: String, prepared: @escaping @Sendable (String) throws -> Void) async throws -> String {
        try prepared("asset")
        let _: Bool = try await ImportDeadline.wait(timeout: .milliseconds(1), message: "pending") { _ in nil }
        return "asset"
    }
}
private final class DeadlineTestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Result<Int, Error>) -> Void)?
    private var count = 0
    var started: Bool { lock.lock(); defer { lock.unlock() }; return callback != nil }
    var cancellations: Int { lock.lock(); defer { lock.unlock() }; return count }
    func install(_ callback: @escaping @Sendable (Result<Int, Error>) -> Void) { lock.lock(); self.callback = callback; lock.unlock() }
    func finish(_ value: Int) { lock.lock(); let done = callback; lock.unlock(); done?(.success(value)) }
    func cancel() { lock.lock(); count += 1; lock.unlock() }
}

private actor RemovedAlbumLibrary: OriginalImportLibrary {
    var creations = 0
    var members: Set<String> = []
    func album(name: String, existingID: String?, prepared: @escaping @Sendable (String?) throws -> Void) async throws -> String {
        if existingID == "deleted-album" { throw PhotoError.message("Missing album") }
        if existingID == nil { creations += 1 }
        try prepared("new-album"); return "new-album"
    }
    func contains(assetID: String, albumID: String) async throws -> Bool { members.contains(assetID) }
    func restore(assetID: String, resources: [ImportResourceDigest], albumID: String) async throws -> Bool {
        guard assetID == "old-0" else { return false }
        members.insert(assetID); return true
    }
    func recover(resources: [ImportResourceDigest], albumID: String) async throws -> String? { nil }
    func insert(_ photo: MaterializedPhoto, record: PhotoRecord, albumID: String, prepared: @escaping @Sendable (String) throws -> Void) async throws -> String {
        let id = "new-" + record.id; try prepared(id); members.insert(id); return id
    }
}
