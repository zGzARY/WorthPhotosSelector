import XCTest
import CoreGraphics
import ImageIO
@testable import PhotoCore

final class CameraAndSceneTests: XCTestCase {
    func record(_ id: String, time: Double? = 0, path: String? = nil) -> PhotoRecord {
        PhotoRecord(id: id, source: .folder, locator: path ?? "/fixture/\(id).jpg", name: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? id,
                    captureDate: time.map(Date.init(timeIntervalSince1970:)), width: 6000, height: 4000)
    }
    func scored(_ records: [PhotoRecord]) -> SelectionSession {
        var s = SelectionSession(); s.records = records; s.groupingComplete = true
        for (i, r) in records.enumerated() {
            var a = AnalysisResult(cacheKey: VisionAnalyzer.cacheKey(r), status: .success, feature: Data([1]), aesthetics: Float(i) / Float(records.count))
            a.qualityComplete = true; s.analyses[r.id] = a
        }
        return s
    }
    func testFourCutsAreNestedAndRecommendationsRetainDistinctCompositions() throws {
        let records = (0..<8).map { record(String($0), time: Double($0)) }
        let tree = try SceneHierarchy.build(records: records, eligible: Set(records.map(\.id))) { a,b in
            let a = Int(a)!, b = Int(b)!
            if a / 2 == b / 2 { return 0.2 }
            if max(a,b) < 4 { return 0.5 }
            return max(a,b) < 6 ? 0.7 : 0.9
        }
        XCTAssertEqual(GroupingLevel.allCases.count, 4)
        var previous: [PhotoGroup] = []
        for (level, count) in zip(GroupingLevel.allCases, [4,3,2,1]) {
            let groups = tree.groups(level: level)
            XCTAssertEqual(groups.count, count)
            XCTAssertEqual(Set(groups.flatMap(\.members)), Set(records.map(\.id)))
            for fine in previous { XCTAssertTrue(groups.contains { Set(fine.members).isSubset(of: Set($0.members)) }) }
            var session = scored(records); session.groups = groups
            XCTAssertEqual(Set(SelectionPlan.make(session: session).keepIDs), ["1", "3", "5", "7"])
            previous = groups
        }
    }
    func testTimeContinuityDoesNotUseTotalSceneSpanOrMixUnknownDates() throws {
        let records = [record("a", time: 0), record("b", time: 50), record("c", time: 100), record("d", time: 161), record("unknown1", time: nil), record("unknown2", time: nil)]
        let tree = try SceneHierarchy.build(records: records, eligible: Set(records.map(\.id))) { _,_ in 0.1 }
        XCTAssertEqual(Set(tree.groups(level: .widest).map { $0.members.sorted().joined(separator: ",") }), ["a,b,c", "d", "unknown1,unknown2"])
        var a = record("a"), b = record("b")
        a.timeNote = "EXIF 未含时区；按相机钟面比较"; b.timeNote = "EXIF 含时区偏移 +08:00"
        let mixed = try SceneHierarchy.build(records: [a,b], eligible: ["a","b"]) { _,_ in 0 }
        XCTAssertEqual(mixed.groups(level: .widest).count, 2)
        let visual = try SceneHierarchy.build(records: records, eligible: ["a","d"], useTime: false) { _,_ in 0 }
        XCTAssertEqual(visual.groups(level: .widest).first?.members, ["a","d"])
    }
    func testCompleteLinkPreventsChainsAndCancellationDoesNotReturnPartialTree() throws {
        let records = [record("a"), record("b"), record("c")]
        let tree = try SceneHierarchy.build(records: records, eligible: ["a","b","c"]) { a,b in Set([a,b]) == ["a","c"] ? 1.2 : 0.3 }
        XCTAssertEqual(tree.groups(level: .widest).map { $0.members.count }.sorted(), [1,2])
        XCTAssertThrowsError(try SceneHierarchy.build(records: records, eligible: ["a","b","c"], cancelled: { true }) { _,_ in 0 })
    }
    func testDeferredPhotosStayUnresolvedAfterRegroupAndCanBeExplicitlyAccepted() {
        var s = scored([record("a"), record("b"), record("c"), record("d")])
        s.groups = [PhotoGroup(members: ["a","b"], kind: .similar), PhotoGroup(members: ["c","d"], kind: .similar)]
        s.decide(["a"], choice: .keep, lock: true); s.deferReview(["a","b"])
        XCTAssertEqual(s.deferredIDs, ["b"])
        var wide = PhotoGroup(members: ["a","b","c","d"], kind: .similar)
        wide.recommendationUnits = [["a","b"],["c","d"]]; s.groups = [wide]
        XCTAssertEqual(SelectionPlan.make(session: s).unresolvedIDs, ["b"])
        XCTAssertEqual(Set(SelectionPlan.make(session: s).keepIDs), ["a","d"])
        s.groups = []
        XCTAssertEqual(SelectionPlan.make(session: s).unresolvedIDs, ["b"], "A skipped photo must not become an automatic single")
        s.groups = [wide]; s.accept(wide)
        XCTAssertEqual(s.decisions["a"], Decision(choice: .keep, locked: true))
        XCTAssertEqual(s.decisions["b"]?.choice, .exclude); XCTAssertEqual(s.decisions["d"]?.choice, .keep)
        XCTAssertTrue(s.deferredIDs!.isEmpty)
    }
    func testStoragePairsRequireMetadataAgreementAndKeepAllResourceBytes() {
        let source = CameraSourceDescriptor(id: "card", name: "Card", transport: .storage)
        var jpg = record("jpg", path: "/DCIM/100/DSCF1.JPG"), raw = record("raw", path: "/DCIM/100/DSCF1.RAF")
        jpg.byteSize = 10; raw.byteSize = 30
        let paired = ExternalAssets.pairStorageRecords([raw,jpg], descriptor: source)
        XCTAssertEqual(paired.count, 1); XCTAssertEqual(paired.first?.byteSize, 40)
        XCTAssertEqual(paired.first?.external?.resources.count, 2)
        XCTAssertEqual(paired.first?.external?.displayResource?.name, "DSCF1.JPG")
        raw.captureDate = Date(timeIntervalSince1970: 1)
        XCTAssertEqual(ExternalAssets.pairStorageRecords([jpg,raw], descriptor: source).count, 2)
        raw.captureDate = nil; jpg.captureDate = nil
        XCTAssertEqual(ExternalAssets.pairStorageRecords([jpg,raw], descriptor: source).count, 2)
        XCTAssertTrue(ExternalAssets.isRaw(name: "DSCF1.RAF", typeIdentifier: "public.data"))
        XCTAssertTrue(ExternalAssets.isPhoto(name: "DSCF1.JPG", typeIdentifier: "public.data"))
        XCTAssertFalse(ExternalAssets.isPhoto(name: "DSCF1.MOV"))
    }
    func testCameraMetadataUsesEXIFAndRejectsSentinelDates() {
        let original = record("metadata", time: nil)
        let prepared = CameraSource.addingMetadata(["{Exif}": ["DateTimeOriginal": "2026:10:02 09:46:00", "OffsetTimeOriginal": "+08:00"]], to: original)
        XCTAssertEqual(prepared.captureDate, FolderSource.parseDate("2026:10:02 09:46:00", offset: "+08:00", subsecond: nil))
        XCTAssertEqual(prepared.fingerprint, original.fingerprint, "Learning EXIF is not a changed original")
        XCTAssertNil(CameraSource.validDate(Date(timeIntervalSince1970: Double(UInt64.max))))
        XCTAssertNil(CameraSource.addingMetadata(["FileCreationDate": Date()], to: original).captureDate)
    }
    func testCameraDoesNotPublishUnconfirmedRawCompanionsAsIndependentSelections() {
        let jpg = OriginalPhotoResource(id: "jpg", locator: "DCIM/100/DSCF1.JPG", name: "DSCF1.JPG", byteSize: 10)
        let raw = OriginalPhotoResource(id: "raw", locator: "DCIM/100/DSCF1.RAF", name: "DSCF1.RAF", byteSize: 30, isRaw: true)
        let otherFolder = OriginalPhotoResource(id: "other", locator: "DCIM/101/DSCF1.RAF", name: "DSCF1.RAF", byteSize: 30, isRaw: true)
        XCTAssertEqual(ExternalAssets.unresolvedCameraPairs([jpg, raw], pairedRawIDs: []), 1)
        XCTAssertEqual(ExternalAssets.unresolvedCameraPairs([jpg, raw], pairedRawIDs: [raw.id]), 0)
        XCTAssertEqual(ExternalAssets.unresolvedCameraPairs([jpg, otherFolder], pairedRawIDs: []), 0)
        XCTAssertEqual(ExternalAssets.unresolvedCameraPairs([raw, otherFolder], pairedRawIDs: []), 0)
    }
    func testOriginalImportIdentifiesImageBytesEvenWithGenericOrMisleadingNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("camera-public-image.bin")
        let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let writer = CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        XCTAssertEqual(try SystemOriginalImportLibrary.resourceContentType(file), "public.jpeg")
        let broken = root.appendingPathComponent("not-a-photo.JPG")
        try Data("invalid image".utf8).write(to: broken)
        XCTAssertThrowsError(try SystemOriginalImportLibrary.resourceContentType(broken))
    }
    func testReconnectPreservesLearnedEXIFAndManualChoiceForUnchangedOriginal() {
        var r = record("camera", time: nil); r.source = .camera
        var s = SelectionSession()
        let device = CameraSourceDescriptor(id: "camera", name: "Camera", transport: .ptp)
        s.applyCameraRecords([r], descriptor: device, complete: true)
        s.records[0].captureDate = Date(timeIntervalSince1970: 100)
        s.records[0].timeNote = "EXIF 未含时区；按相机钟面比较"
        s.decide([r.id], choice: .keep, lock: true)
        s.applyCameraRecords([r], descriptor: device, complete: true)
        XCTAssertEqual(s.records[0].captureDate, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(s.decisions[r.id], Decision(choice: .keep, locked: true))
        XCTAssertTrue(s.staleIDs.isEmpty)
    }
    func testReconnectKeepsCompletedGroupsAndScopeAndFlagsOnlyChangedOrMissingFiles() {
        let device = CameraSourceDescriptor(id: "device", name: "Camera", transport: .ptp)
        var originals = (0..<4).map { record(String($0)) }
        for i in originals.indices { originals[i].source = .camera }
        var s = scored(originals); s.source = .camera; s.cameraSource = device; s.activeCameraIDs = Set(originals.map(\.id))
        s.groups = [PhotoGroup(members: ["0","1"], kind: .similar), PhotoGroup(members: ["2","3"], kind: .similar)]
        s.decide(["0"], choice: .keep, lock: true)
        let groupIDs = s.groups.map(\.id), key = s.scopeKey, feature = s.analyses["0"]?.feature
        let same = s.reconnectCameraRecords(originals, descriptor: device)
        XCTAssertTrue(same.changedIDs.isEmpty); XCTAssertEqual(s.scopeKey, key)
        XCTAssertEqual(s.groupingComplete, true); XCTAssertEqual(s.groups.map(\.id), groupIDs)
        XCTAssertEqual(s.analyses["0"]?.feature, feature); XCTAssertEqual(s.decisions["0"]?.locked, true)
        var changed = originals[1]; changed.byteSize = 900
        var fresh = record("new"); fresh.source = .camera
        let update = s.reconnectCameraRecords([originals[0], changed, originals[2], fresh], descriptor: device)
        XCTAssertEqual(update.changedIDs, ["1"]); XCTAssertEqual(update.missingIDs, ["3"]); XCTAssertEqual(update.newCount, 1)
        XCTAssertEqual(s.activeIDs, ["0","1","2","3"]); XCTAssertEqual(s.groups.map(\.id), groupIDs)
        XCTAssertNil(s.analyses["1"]); XCTAssertNotNil(s.analyses["2"]); XCTAssertEqual(s.groupingComplete, true)
        _ = s.reconnectCameraRecords(originals, descriptor: device)
        XCTAssertTrue(s.unavailableCameraIDs!.isEmpty); XCTAssertNotNil(s.analyses["3"])
    }
    @MainActor
    func testCameraQueuePrioritizesOriginalsAndRejectsCancelledOrOldConnectionWaiters() async throws {
        let queue = CameraReadQueue(); queue.importing = true
        let preview = Task { try await queue.acquire(preview: true) { true }; queue.release() }
        try await queue.acquire(preview: false) { true }
        preview.cancel(); queue.release()
        do { try await preview.value; XCTFail("Cancelled preview acquired the camera") } catch is CancellationError {}
        queue.importing = false
        try await queue.acquire(preview: false) { true }
        var connected = true
        let old = Task { try await queue.acquire(preview: false) { connected }; queue.release() }
        await Task.yield(); connected = false; queue.release()
        do { try await old.value; XCTFail("Old connection acquired the camera") } catch {}
        try await queue.acquire(preview: false) { true }; queue.release()
    }
    @MainActor
    func testCameraQueueTimeoutDoesNotLeaveTheQueueLocked() async throws {
        let queue = CameraReadQueue()
        try await queue.acquire(preview: false) { true }
        do { try await queue.acquire(preview: false, timeout: .milliseconds(1)) { true }; XCTFail("Expected timeout") } catch {}
        queue.release(); try await queue.acquire(preview: false) { true }; queue.release()
    }
    func testLateCameraCallbacksCompleteOnlyOnceIncludingBeforeInstallation() async throws {
        let gate = CameraCallback<Int>()
        XCTAssertTrue(gate.finish(.success(7)))
        let result: Int = try await withCheckedThrowingContinuation { gate.install($0) }
        XCTAssertEqual(result, 7); XCTAssertFalse(gate.finish(.success(9)))
        let disconnected = CameraCallback<Int>()
        do {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                disconnected.install(continuation)
                XCTAssertTrue(disconnected.finish(.failure(PhotoError.message("disconnected"))))
                XCTAssertFalse(disconnected.finish(.success(1)))
            }
            XCTFail("Expected disconnected error")
        } catch { XCTAssertEqual(error.localizedDescription, "disconnected") }
    }
    func testOldSessionMigrationAndSeparateArchivesPreserveChoicesAndCaches() throws {
        XCTAssertEqual(stableID(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var old = scored([record("a"), record("b")]); old.schema = 2; old.settings.groupingLevel = nil
        old.decide(["a"], choice: .keep, lock: true)
        let file = root.appendingPathComponent("legacy.json"); try SessionStore.save(old, to: file)
        let loaded = try SessionStore.load(from: file)
        XCTAssertEqual(loaded.schema, 3); XCTAssertNil(loaded.settings.groupingLevel)
        XCTAssertEqual(loaded.decisions, old.decisions); XCTAssertEqual(loaded.analyses["a"]?.feature, old.analyses["a"]?.feature)
        _ = try SessionStore.archive(loaded, in: root)
        var camera = SelectionSession()
        var r = record("camera"); r.source = .camera
        camera.applyCameraRecords([r], descriptor: CameraSourceDescriptor(id: "device", name: "Camera", transport: .ptp), complete: true)
        camera.deferReview([r.id]); _ = try SessionStore.archive(camera, in: root)
        XCTAssertEqual(try SessionStore.savedSessions(in: root).count, 2)
        let restored = try SessionStore.load(from: SessionStore.archiveURL(loaded.id, in: root))
        XCTAssertEqual(restored.decisions, old.decisions); XCTAssertEqual(restored.activeRecords.map(\.id), ["a","b"])
        let restoredCamera = try SessionStore.load(from: SessionStore.archiveURL(camera.id, in: root))
        XCTAssertEqual(restoredCamera.deferredIDs, ["camera"]); XCTAssertEqual(restoredCamera.activeRecords.map(\.id), ["camera"])
        XCTAssertThrowsError(try SessionStore.archiveURL("../../session", in: root))
    }
    func testBroadScenesAreNotUsedAsOneWinnerCalibrationSamples() {
        var s = scored([record("a"),record("b"),record("c"),record("d")])
        var g = PhotoGroup(members: s.records.map(\.id), kind: .similar)
        g.recommendationUnits = [["a","b"],["c","d"]]; s.groups = [g]
        XCTAssertTrue(PreferenceCalibration.candidates(session: s).isEmpty)
    }
    func testSmallPreviewCannotReuseFullQualityAndLargerInputRecomputesFeature() async throws {
        let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let image = context.makeImage()!, r = record("preview")
        var cached = AnalysisResult(cacheKey: VisionAnalyzer.cacheKey(r), status: .success, feature: Data([1,2,3]), aesthetics: 0.9)
        cached.qualityComplete = true; cached.inputSignature = "old"
        let low = await VisionAnalyzer.analyze(image, record: r, cached: cached, inputSignature: "small", inputKind: "cameraPreview", permitsQuality: false)
        XCTAssertNotNil(low.feature); XCTAssertNotEqual(low.feature, cached.feature)
        XCTAssertNil(low.aesthetics); XCTAssertTrue(low.faces.isEmpty); XCTAssertEqual(low.qualityComplete, false)
        let upgraded = await VisionAnalyzer.analyze(image, record: r, cached: low, inputSignature: "large", inputKind: "cameraOriginal")
        XCTAssertEqual(upgraded.inputSignature, "large"); XCTAssertNotNil(upgraded.aesthetics)
        XCTAssertEqual(upgraded.qualityComplete, true)
    }
}
