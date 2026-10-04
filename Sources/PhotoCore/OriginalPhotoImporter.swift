import Foundation
import Photos
import CryptoKit
import ImageIO

public struct ImportResourceDigest: Codable, Equatable, Sendable {
    public var name: String
    public var sha256: String
    public var isRaw: Bool
}
public struct OriginalImportEntry: Codable, Sendable {
    public var fingerprint: String
    public var resources: [ImportResourceDigest]
    public var assetID: String?
    public var complete: Bool
    public var stagingDirectory: String? = nil
    public var submissionStarted: Bool? = nil
}
public struct OriginalImportJournal: Codable, Sendable {
    public var token: String
    public var albumName: String
    public var albumID: String?
    public var entries: [String: OriginalImportEntry] = [:]
    public init(token: String, albumName: String) { self.token = token; self.albumName = albumName }
}
final class ImportJournalStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OriginalImportJournal
    let url: URL
    init(url: URL, token: String, name: String) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            value = try JSONDecoder().decode(OriginalImportJournal.self, from: Data(contentsOf: url))
            guard value.token == token, value.albumName == name else { throw PhotoError.message("导入记录与本次选择不同，请先核对上次结果") }
        } else {
            value = OriginalImportJournal(token: token, albumName: name)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        }
    }
    var snapshot: OriginalImportJournal { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ block: (inout OriginalImportJournal) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var next = value; block(&next)
        try JSONEncoder().encode(next).write(to: url, options: .atomic); value = next
    }
}

/// The importer can be exercised with a fake library without touching personal Photos.
public protocol OriginalImportLibrary: Sendable {
    func album(name: String, existingID: String?, prepared: @escaping @Sendable (String?) throws -> Void) async throws -> String
    func contains(assetID: String, albumID: String) async throws -> Bool
    func restore(assetID: String, resources: [ImportResourceDigest], albumID: String) async throws -> Bool
    func recover(resources: [ImportResourceDigest], albumID: String) async throws -> String?
    func insert(_ photo: MaterializedPhoto, record: PhotoRecord, albumID: String,
                prepared: @escaping @Sendable (String) throws -> Void) async throws -> String
    func submissionStatus(assetID: String) -> ImportSubmissionStatus
    var hasActiveSubmission: Bool { get }
}
public enum ImportSubmissionStatus: Sendable { case unknown, inFlight, settled, rejected }
public extension OriginalImportLibrary {
    func submissionStatus(assetID: String) -> ImportSubmissionStatus { .unknown }
    var hasActiveSubmission: Bool { false }
    func restore(assetID: String, resources: [ImportResourceDigest], albumID: String) async throws -> Bool {
        try await contains(assetID: assetID, albumID: albumID)
    }
}
public enum OriginalImportFailure: LocalizedError {
    case rejected(String)
    case pending(String)
    public var errorDescription: String? {
        switch self { case .rejected(let text), .pending(let text): return text }
    }
}
public enum OriginalPhotoImporter {
    public static func journal(at url: URL) throws -> OriginalImportJournal {
        try JSONDecoder().decode(OriginalImportJournal.self, from: Data(contentsOf: url))
    }
    /// Write the replacement journal before the caller switches its pending plan.
    /// Prior transactions are reconciled even when their photo was deselected.
    public static func rebase(session: SelectionSession, plan: SelectionPlan, oldToken: String,
                              newToken: String, sourceURL: URL, targetURL: URL, replacementAlbumName: String? = nil,
                              library: any OriginalImportLibrary = SystemOriginalImportLibrary()) async throws -> OriginalImportJournal {
        guard plan.scopeKey == session.scopeKey, plan.permitsOutput else { throw PhotoError.message("精选清单已变化，请重新确认") }
        let prior = try journal(at: sourceURL)
        guard !library.hasActiveSubmission else { throw OriginalImportFailure.pending("系统仍在处理上次提交，请稍后核对；未重复导入") }
        guard prior.token == oldToken, let previousAlbumID = prior.albumID else { throw PhotoError.message("上次相册尚未确认，请先核对上次导入") }
        let name = replacementAlbumName ?? prior.albumName
        let albumID: String
        if replacementAlbumName != nil {
            guard sourceURL != targetURL else { throw PhotoError.message("重新导出需要独立记录，旧记录已保留") }
            let target = try ImportJournalStore(url: targetURL, token: newToken, name: name)
            albumID = try await library.album(name: name, existingID: target.snapshot.albumID) { id in
                try target.update { $0.albumID = id }
            }
            try target.update { $0.albumID = albumID }
        } else {
            albumID = try await library.album(name: name, existingID: previousAlbumID, prepared: { _ in })
        }
        let records = Dictionary(uniqueKeysWithValues: session.activeRecords.map { ($0.id, $0) })
        let keep = Set(plan.keepIDs)
        var replacement = OriginalImportJournal(token: newToken, albumName: name)
        replacement.albumID = albumID
        var entries = prior.entries
        if FileManager.default.fileExists(atPath: targetURL.path) {
            let existing = try journal(at: targetURL)
            guard existing.token == newToken, existing.albumID == albumID, existing.albumName == name else {
                throw PhotoError.message("已有续传记录与本次相册不同，未覆盖记录")
            }
            for (id, entry) in existing.entries {
                if let oldID = entries[id]?.assetID, let nextID = entry.assetID, oldID != nextID,
                   !(replacementAlbumName != nil && entries[id]?.complete == true) {
                    throw PhotoError.message("同一照片有不同提交记录，请先核对；未覆盖或重复导入")
                }
                entries[id] = entry
            }
        }
        for (id, var entry) in entries {
            try Task.checkCancellation()
            if let assetID = entry.assetID, library.submissionStatus(assetID: assetID) == .inFlight {
                throw OriginalImportFailure.pending("系统仍在处理上次提交，请稍后核对；未重复导入")
            }
            if let assetID = entry.assetID, library.submissionStatus(assetID: assetID) == .rejected {
                entry.assetID = nil; entry.submissionStarted = false; cleanupStaging(entry)
            } else if let assetID = entry.assetID, try await library.contains(assetID: assetID, albumID: albumID) {
                entry.complete = true; cleanupStaging(entry); entry.stagingDirectory = nil
            } else if entry.complete, replacementAlbumName != nil {
                guard keep.contains(id) else { continue }
                guard records[id]?.fingerprint == entry.fingerprint else { throw PhotoError.message("已导入照片的来源版本变化，请先核对") }
                if let assetID = entry.assetID, try await library.restore(assetID: assetID, resources: entry.resources, albumID: albumID) {
                    cleanupStaging(entry); entry.stagingDirectory = nil
                } else {
                    // Explicitly confirmed re-export: missing library assets are
                    // read again from the camera, never undeleted or purged.
                    entry.complete = false; entry.assetID = nil; entry.submissionStarted = false
                }
            } else if entry.complete {
                throw PhotoError.message("已完成照片已被移出相册或删除，请先核对；未重复导入")
            } else if !entry.resources.isEmpty, let assetID = try await library.recover(resources: entry.resources, albumID: albumID) {
                entry.assetID = assetID; entry.complete = true; cleanupStaging(entry); entry.stagingDirectory = nil
            } else if entry.assetID != nil || entry.submissionStarted == true {
                throw OriginalImportFailure.pending("上次提交结果仍待核对，暂不能更新清单；未重复导入")
            }
            guard keep.contains(id) else { continue }
            guard records[id]?.fingerprint == entry.fingerprint else { throw PhotoError.message("已导入照片的来源版本变化，请先核对") }
            replacement.entries[id] = entry
        }
        try JSONEncoder().encode(replacement).write(to: targetURL, options: .atomic)
        return replacement
    }
    private static func cleanupStaging(_ entry: OriginalImportEntry) {
        guard let path = entry.stagingDirectory else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".travel-select-import-stage").path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
    public static func run(session: SelectionSession, plan: SelectionPlan, name: String, token: String, journalURL: URL,
                           library: any OriginalImportLibrary = SystemOriginalImportLibrary(),
                           materialize: @escaping @Sendable (PhotoRecord) async throws -> MaterializedPhoto = { try await PhotoSource.materialize($0) },
                           cancelled: @escaping @Sendable () -> Bool = { false },
                           progress: @escaping @Sendable (Int, Int, String) async -> Void = { _, _, _ in }) async throws -> AlbumReceipt {
        guard session.source != .photos, plan.scopeKey == session.scopeKey, plan.permitsOutput else {
            throw PhotoError.message("照片范围或选择已变化，请重新查看精选清单")
        }
        let records = Dictionary(uniqueKeysWithValues: session.activeRecords.map { ($0.id, $0) })
        let fingerprints = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.id, $0.fingerprint) })
        guard plan.keepIDs.allSatisfy({ records[$0]?.fingerprint == fingerprints[$0] }) else { throw PhotoError.message("照片版本已变化，请重新确认") }
        let store = try ImportJournalStore(url: journalURL, token: token, name: name)
        guard !library.hasActiveSubmission else { throw OriginalImportFailure.pending("系统仍在处理上次提交，请稍后核对；未重复导入") }
        if cancelled() || Task.isCancelled { throw CancellationError() }
        let albumID = try await library.album(name: name, existingID: store.snapshot.albumID) { id in
            try store.update { $0.albumID = id }
        }
        try store.update { $0.albumID = albumID }
        var finished = 0
        await progress(0, plan.keepIDs.count, "正在核对已导入照片")
        for id in plan.keepIDs {
            if cancelled() || Task.isCancelled { throw CancellationError() }
            let record = records[id]!
            if let entry = store.snapshot.entries[id] {
                guard entry.fingerprint == record.fingerprint else { throw PhotoError.message("原文件版本与上次导入记录不同") }
                if let assetID = entry.assetID, try await library.contains(assetID: assetID, albumID: albumID) {
                    cleanupStaging(entry)
                    try store.update { $0.entries[id]?.complete = true }; finished += 1
                    await progress(finished, plan.keepIDs.count, "已核对导入结果")
                    continue
                }
                if entry.complete { throw PhotoError.message("已导入照片被移出相册或删除，请先在「照片」中核对；未重复导入") }
                if let assetID = entry.assetID, library.submissionStatus(assetID: assetID) == .inFlight {
                    throw OriginalImportFailure.pending("系统仍在处理上次提交，请稍后核对；未重复导入")
                }
                if let assetID = entry.assetID, library.submissionStatus(assetID: assetID) == .rejected {
                    cleanupStaging(entry); try store.update { $0.entries[id]?.assetID = nil; $0.entries[id]?.submissionStarted = false }
                } else {
                if !entry.resources.isEmpty, let recovered = try await library.recover(resources: entry.resources, albumID: albumID) {
                    cleanupStaging(entry)
                    try store.update { $0.entries[id]?.assetID = recovered; $0.entries[id]?.complete = true }
                    finished += 1; await progress(finished, plan.keepIDs.count, "已恢复上次导入结果"); continue
                }
                if entry.assetID != nil || entry.submissionStarted == true { throw PhotoError.message("上次提交的照片暂未出现在相册中，结果仍需核对；未重复传输，请稍后重试") }
                }
            }
            await progress(finished, plan.keepIDs.count, "正在读取精选原片：" + record.name)
            let original = try await materialize(record)
            var preserveStaging = false
            defer { if !preserveStaging { original.cleanup() } }
            guard original.files.count == original.resources.count, !original.files.isEmpty else { throw PhotoError.message("原片资源不完整，尚未提交图库") }
            var digests: [ImportResourceDigest] = []
            for (index, file) in original.files.enumerated() {
                let digest = try await Task.detached { try FolderSource.sha256(file, cancelled: cancelled) }.value
                digests.append(ImportResourceDigest(name: original.resources[index].name, sha256: digest, isRaw: original.resources[index].isRaw))
            }
            if cancelled() || Task.isCancelled { throw CancellationError() }
            if let root = original.temporaryDirectory {
                try Data(token.utf8).write(to: root.appendingPathComponent(".travel-select-import-stage"), options: .atomic)
            }
            try store.update { $0.entries[id] = OriginalImportEntry(fingerprint: record.fingerprint, resources: digests,
                assetID: nil, complete: false, stagingDirectory: original.temporaryDirectory?.path, submissionStarted: true) }
            await progress(finished, plan.keepIDs.count, "正在写入「照片」；停止会在当前照片完成后生效")
            let assetID: String
            do {
                assetID = try await library.insert(original, record: record, albumID: albumID) { targetID in
                    try store.update { $0.entries[id]?.assetID = targetID }
                }
            } catch OriginalImportFailure.rejected(let text) {
                // A rejected atomic PhotoKit transaction has no committed asset.
                try store.update { $0.entries[id]?.assetID = nil; $0.entries[id]?.submissionStarted = false }; throw OriginalImportFailure.rejected(text)
            } catch {
                preserveStaging = true; throw error
            }
            guard try await library.contains(assetID: assetID, albumID: albumID) else {
                throw PhotoError.message("系统已提交照片，但结果尚未可见；重试时会先核对，不会直接重复导入")
            }
            try store.update { $0.entries[id]?.assetID = assetID; $0.entries[id]?.complete = true; $0.entries[id]?.stagingDirectory = nil }
            finished += 1; await progress(finished, plan.keepIDs.count, "已导入 \(finished) 张精选")
        }
        let ids = store.snapshot.entries.compactMapValues { $0.complete ? $0.assetID : nil }
        return AlbumReceipt(token: token, albumIDs: [albumID], names: [name], importedIDs: ids)
    }
}

public final class SystemOriginalImportLibrary: OriginalImportLibrary, @unchecked Sendable {
    private static let commits = ImportCommitRegistry()
    public func submissionStatus(assetID: String) -> ImportSubmissionStatus { Self.commits.status(assetID) }
    public var hasActiveSubmission: Bool { Self.commits.hasActive }
    public init() {}
    static func resourceContentType(_ file: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) else {
            throw PhotoError.message("无法识别原片格式，未提交图库：" + file.lastPathComponent)
        }
        return type as String
    }
    private func collection(_ id: String) throws -> PHAssetCollection {
        guard PhotoAccess.canRead else { throw PhotoError.message("请允许访问「照片」，选片进度已保存") }
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw PhotoError.message("结果相册不存在或已被删除，请先在「照片」中核对")
        }
        return album
    }
    public func album(name: String, existingID: String?, prepared: @escaping @Sendable (String?) throws -> Void) async throws -> String {
        if let existingID { _ = try collection(existingID); return existingID }
        guard PhotoAccess.canRead else { throw PhotoError.message("请先允许访问「照片」") }
        let options = PHFetchOptions(); options.predicate = NSPredicate(format: "title == %@", name)
        let matches = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        guard matches.count <= 1 else { throw PhotoError.message("存在多个同名相册，请先核对上次结果") }
        if let found = matches.firstObject {
            // The name was reserved and journaled before creation. Recovery does
            // not overwrite membership; each asset is independently reconciled.
            try prepared(found.localIdentifier); return found.localIdentifier
        }
        let state = PhotoTransactionState()
        do { _ = try await ImportDeadline.wait(timeout: .seconds(120), message: "相册提交超过等待时间，系统结果待核对；请稍后重试") { done in
            Self.commits.begin()
            PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            let id = request.placeholderForCreatedAssetCollection.localIdentifier
            state.set(id: id)
            do { try prepared(id) } catch { state.set(error: error) }
            }, completionHandler: { success, error in
                Self.commits.end()
                if success { done(.success(true)) }
                else { done(.failure(OriginalImportFailure.rejected(error?.localizedDescription ?? "相册创建被系统拒绝"))) }
            })
            return nil
        } } catch OriginalImportFailure.rejected(let text) { try prepared(nil); throw OriginalImportFailure.rejected(text) }
        if let error = state.error { throw PhotoError.message("相册已提交，但导入记录保存失败：" + error.localizedDescription) }
        guard let id = state.id else { throw PhotoError.message("未取得结果相册标识，请核对上次结果") }
        return id
    }
    public static func albumExists(_ id: String) -> Bool {
        PhotoAccess.canRead && PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject != nil
    }
    public func restore(assetID: String, resources expected: [ImportResourceDigest], albumID: String) async throws -> Bool {
        let album = try collection(albumID)
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return false }
        let resources = PHAssetResource.assetResources(for: asset).filter { $0.type == .photo || $0.type == .alternatePhoto }
        guard !expected.isEmpty, resources.map({ $0.originalFilename.lowercased() }).sorted() == expected.map({ $0.name.lowercased() }).sorted() else {
            throw PhotoError.message("原导入照片的 JPEG／RAW 资源与记录不同，未重复创建")
        }
        var actual: [String: String] = [:]
        for resource in resources { actual[resource.originalFilename.lowercased()] = try await digest(resource) }
        guard expected.allSatisfy({ actual[$0.name.lowercased()] == $0.sha256 }) else {
            throw PhotoError.message("原导入照片的内容校验不一致，未重复创建")
        }
        let _: Bool = try await ImportDeadline.wait(timeout: .seconds(120), message: "加入新相册超过等待时间，系统结果待核对") { done in
            Self.commits.begin()
            PHPhotoLibrary.shared().performChanges({
                PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
            }, completionHandler: { success, error in
                Self.commits.end()
                if success { done(.success(true)) }
                else { done(.failure(OriginalImportFailure.rejected(error?.localizedDescription ?? "加入相册被系统拒绝"))) }
            })
            return nil
        }
        return try await contains(assetID: assetID, albumID: albumID)
    }
    public func contains(assetID: String, albumID: String) async throws -> Bool {
        let album = try collection(albumID)
        var found = false
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, stop in
            if asset.localIdentifier == assetID { found = true; stop.pointee = true }
        }
        return found
    }
    public func recover(resources expected: [ImportResourceDigest], albumID: String) async throws -> String? {
        let album = try collection(albumID)
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        var candidates: [PHAsset] = []
        let names = expected.map { $0.name.lowercased() }.sorted()
        assets.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset).filter { $0.type == .photo || $0.type == .alternatePhoto }
            if resources.map({ $0.originalFilename.lowercased() }).sorted() == names { candidates.append(asset) }
        }
        var matches: [String] = []
        for asset in candidates {
            let resources = PHAssetResource.assetResources(for: asset).filter { $0.type == .photo || $0.type == .alternatePhoto }
            var actual: [String: String] = [:]
            for resource in resources { actual[resource.originalFilename.lowercased()] = try await digest(resource) }
            if expected.allSatisfy({ actual[$0.name.lowercased()] == $0.sha256 }) { matches.append(asset.localIdentifier) }
        }
        guard matches.count <= 1 else { throw PhotoError.message("找到多个相同的导入结果，请人工核对；未重复导入") }
        return matches.first
    }
    private func digest(_ resource: PHAssetResource) async throws -> String {
        let state = ResourceDigestState()
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = false
        return try await ImportDeadline.wait(timeout: .seconds(45), message: "上次导入资源核对超时，请稍后重试；未重复创建") { done in
            let request = PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { state.append($0) }) { error in
                if let error { done(.failure(PhotoError.message("上次导入资源暂不可读取，未重复创建：" + error.localizedDescription))) }
                else { done(.success(state.finish())) }
            }
            return { PHAssetResourceManager.default().cancelDataRequest(request) }
        }
    }
    public func insert(_ photo: MaterializedPhoto, record: PhotoRecord, albumID: String,
                       prepared: @escaping @Sendable (String) throws -> Void) async throws -> String {
        let album = try collection(albumID)
        let primary = photo.resources.firstIndex(where: { !$0.isRaw }) ?? 0
        let types = photo.resources.indices.map { $0 == primary ? PHAssetResourceType.photo : .alternatePhoto }
        // PTP cameras may report only public.image for both JPEG and RAW.
        // Passing that abstract UTI makes Photos retain bytes but misclassify
        // the asset. Identify each staged original from its actual header.
        let contentTypes = try photo.files.map(Self.resourceContentType)
        guard photo.resources.count <= 2, PHAssetCreationRequest.supportsAssetResourceTypes(types.map { NSNumber(value: $0.rawValue) }) else {
            throw PhotoError.message("「照片」不支持这组原片资源，未丢弃或转换其中任何文件")
        }
        let state = PhotoTransactionState()
        do { _ = try await ImportDeadline.wait(timeout: .seconds(120), message: "图库提交超过等待时间，系统结果待核对；未重复导入") { done in
            state.markStarted(); Self.commits.begin()
            PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = record.captureDate
            for index in photo.files.indices {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = photo.resources[index].name
                options.uniformTypeIdentifier = contentTypes[index]
                // Storage cards are always copied. Only app-owned staging files may move.
                options.shouldMoveFile = photo.temporaryDirectory != nil
                request.addResource(with: types[index], fileURL: photo.files[index], options: options)
            }
            if let asset = request.placeholderForCreatedAsset {
                state.set(id: asset.localIdentifier)
                Self.commits.set(asset.localIdentifier, .inFlight)
                do { try prepared(asset.localIdentifier) } catch { state.set(error: error) }
                PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
            }
            }, completionHandler: { success, error in
                if let id = state.id { Self.commits.set(id, success ? .settled : .rejected) }
                Self.commits.end()
                // The system has finished reading staging files. A timeout alone
                // never runs this cleanup or cancels a PhotoKit transaction.
                photo.cleanup()
                if success { done(.success(true)) }
                else { done(.failure(OriginalImportFailure.rejected(error?.localizedDescription ?? "照片写入被系统拒绝"))) }
            })
            return nil
        } } catch {
            if !state.started { throw OriginalImportFailure.rejected("操作已取消，尚未提交图库") }
            throw error
        }
        if let error = state.error { throw PhotoError.message("照片已提交，但记录保存失败；重试前会核对资源：" + error.localizedDescription) }
        guard let id = state.id else { throw PhotoError.message("照片提交结果尚不明确，请核对上次结果") }
        return id
    }
}

/// Race a callback against a deadline without losing late transaction outcomes.
enum ImportDeadline {
    static func wait<Value>(timeout: Duration, message: String,
                           start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> (@Sendable () -> Void)? ) async throws -> Value {
        let gate = CameraCallback<Value>()
        let timer = Task {
            do { try await Task.sleep(for: timeout); gate.finish(.failure(OriginalImportFailure.pending(message))) } catch {}
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard !Task.isCancelled else { gate.finish(.failure(CancellationError())); return }
                let cancel = start { gate.finish($0) }
                if let cancel { gate.onCancellation(cancel) }
            }
        } onCancel: { gate.finish(.failure(OriginalImportFailure.pending("等待已停止，系统提交结果仍需核对；未重复导入"))) }
    }
}
private final class ImportCommitRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ImportSubmissionStatus] = [:]
    private var active = 0
    var hasActive: Bool { lock.lock(); defer { lock.unlock() }; return active > 0 }
    func begin() { lock.lock(); active += 1; lock.unlock() }
    func end() { lock.lock(); active -= 1; lock.unlock() }
    func set(_ id: String, _ status: ImportSubmissionStatus) { lock.lock(); values[id] = status; lock.unlock() }
    func status(_ id: String) -> ImportSubmissionStatus { lock.lock(); defer { lock.unlock() }; return values[id] ?? .unknown }
}

private final class PhotoTransactionState: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: String?
    private var failure: Error?
    private var began = false
    func markStarted() { lock.lock(); began = true; lock.unlock() }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return began }
    func set(id: String) { lock.lock(); identifier = id; lock.unlock() }
    func set(error: Error) { lock.lock(); failure = error; lock.unlock() }
    var id: String? { lock.lock(); defer { lock.unlock() }; return identifier }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
}
private final class ResourceDigestState: @unchecked Sendable {
    private let lock = NSLock()
    private var hash = SHA256()
    func append(_ data: Data) { lock.lock(); hash.update(data: data); lock.unlock() }
    func finish() -> String { lock.lock(); defer { lock.unlock() }; return hash.finalize().map { String(format: "%02x", $0) }.joined() }
}
