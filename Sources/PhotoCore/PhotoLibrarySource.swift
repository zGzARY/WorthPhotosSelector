import Foundation
import Photos
import AppKit
import UniformTypeIdentifiers

public struct PhotoAlbum: Identifiable, Equatable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}
public enum PhotoAccess {
    public static var status: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    public static var canRead: Bool { status == .authorized || status == .limited }
    public static var label: String {
        switch status {
        case .notDetermined: return "尚未请求照片权限"
        case .restricted: return "照片访问受系统限制"
        case .denied: return "照片访问被拒绝；可在系统设置的隐私与安全性中允许"
        case .authorized: return "已授权；仅读取您选择的范围"
        case .limited: return "仅可读取系统允许的照片范围"
        @unknown default: return "未知授权状态，请重新连接"
        }
    }
    public static func request() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }
}
public enum PhotoLoadError: LocalizedError {
    case cloud, missing, small, timeout
    public var errorDescription: String? {
        switch self {
        case .cloud: return "照片尚未下载到本机；可明确开启 iCloud 下载后重试"
        case .missing: return "照片不可访问，可能已删除、图库或授权范围已变化"
        case .small: return "仅取得降质预览，未用于质量分析"
        case .timeout: return "系统图像请求超时，请稍后重试"
        }
    }
}

/// Handles early callbacks, cancellation before installation, and duplicate completions.
final class ImageRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Result<CGImage, Error>) -> Void)?
    private var terminal: Result<CGImage, Error>?
    private var requestID: PHImageRequestID?
    private var manager: PHImageManager?
    func install(_ block: @escaping (Result<CGImage, Error>) -> Void) {
        lock.lock()
        if let terminal { lock.unlock(); block(terminal) }
        else { completion = block; lock.unlock() }
    }
    func bind(_ id: PHImageRequestID, manager: PHImageManager) {
        lock.lock(); let finished = terminal != nil
        if !finished { requestID = id; self.manager = manager }; lock.unlock()
        if finished { manager.cancelImageRequest(id) }
    }
    @discardableResult func finish(_ result: Result<CGImage, Error>, cancelRequest: Bool = false) -> Bool {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return false }
        terminal = result; let block = completion; completion = nil
        let id = requestID, owner = manager; requestID = nil; manager = nil
        lock.unlock()
        if cancelRequest, let id { owner?.cancelImageRequest(id) }
        block?(result); return true
    }
}

public final class PhotoLibrarySource: @unchecked Sendable {
    public static let shared = PhotoLibrarySource()
    private let manager = PHCachingImageManager()
    public init() { manager.allowsCachingHighQualityImages = false }
    public func albums() throws -> [PhotoAlbum] {
        guard PhotoAccess.canRead else { throw PhotoError.message(PhotoAccess.label) }
        var list: [PhotoAlbum] = []
        // Listing album metadata is separate from fetching the album's images.
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let result = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            result.enumerateObjects { collection, _, _ in
                guard collection.assetCollectionSubtype != .smartAlbumAllHidden,
                      collection.assetCollectionSubtype != .smartAlbumUserLibrary else { return }
                list.append(PhotoAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "未命名相册"))
            }
        }
        return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public static func fetchOptions(scope: PhotosScope) throws -> PHFetchOptions {
        try scope.validate()
        let options = PHFetchOptions(); options.includeHiddenAssets = false; options.includeAllBurstAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var predicates = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue), NSPredicate(format: "hidden == NO")]
        if let start = scope.startDate, let end = scope.endDateExclusive {
            predicates.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate))
        }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        return options
    }
    private func assets(scope: PhotosScope) throws -> PHFetchResult<PHAsset> {
        guard PhotoAccess.canRead else { throw PhotoError.message(PhotoAccess.label) }
        let options = try Self.fetchOptions(scope: scope)
        if let albumID = scope.albumID {
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { throw PhotoError.message("所选相册已不可访问") }
            return PHAsset.fetchAssets(in: album, options: options)
        }
        return PHAsset.fetchAssets(with: options)
    }
    public func count(scope: PhotosScope) throws -> Int { try assets(scope: scope).count }
    public func fetch(scope: PhotosScope, cancelled: () -> Bool = { false }) throws -> [PhotoRecord] {
        let assets = try assets(scope: scope)
        var list: [PhotoRecord] = []
        for index in 0..<assets.count {
            if cancelled() { throw CancellationError() }
            let asset = assets.object(at: index)
            if !asset.isHidden && scope.contains(asset.creationDate) { list.append(Self.record(asset, name: "照片 \(index + 1)")) }
        }
        if cancelled() { throw CancellationError() }
        return list
    }
    public static func record(_ asset: PHAsset, name: String) -> PhotoRecord {
        var notes: [String] = []
        if asset.mediaSubtypes.contains(.photoLive) { notes.append("Live Photo：仅评估当前静态代表图，未评估动态部分；输出引用完整资产") }
        if asset.mediaSubtypes.contains(.photoDepthEffect) { notes.append("人像模式：只评估当前显示图，未评估深度与可重编辑效果") }
        let raw = PHAssetResource.assetResources(for: asset).contains { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }
        if raw { notes.append("RAW／组合资产：仅比较系统当前呈现图，未完整分析原始资源") }
        return PhotoRecord(id: "photos:" + asset.localIdentifier, source: .photos, locator: asset.localIdentifier,
                           name: name, captureDate: asset.creationDate, modified: asset.modificationDate,
                           width: asset.pixelWidth, height: asset.pixelHeight, favorite: asset.isFavorite,
                           burstID: asset.burstIdentifier, mediaSubtypes: asset.mediaSubtypes.rawValue, notes: notes)
    }
    public func resolve(_ record: PhotoRecord) throws -> PHAsset {
        guard PhotoAccess.canRead else { throw PhotoError.message(PhotoAccess.label) }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [record.locator], options: nil).firstObject, !asset.isHidden else { throw PhotoLoadError.missing }
        return asset
    }
    public func refresh(_ records: [PhotoRecord]) -> (records: [PhotoRecord], missing: Set<String>) {
        guard PhotoAccess.canRead else { return ([], Set(records.map(\.id))) }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: records.map(\.locator), options: nil)
        var byID: [String: PHAsset] = [:]
        assets.enumerateObjects { asset, _, _ in if !asset.isHidden { byID[asset.localIdentifier] = asset } }
        var changed: [PhotoRecord] = [], missing = Set<String>()
        for record in records {
            if let asset = byID[record.locator] { changed.append(Self.record(asset, name: record.name)) }
            else { missing.insert(record.id) }
        }
        return (changed, missing)
    }
    public func image(_ record: PhotoRecord, maxPixel: Int, allowNetwork: Bool) async throws -> CGImage {
        let asset = try resolve(record)
        guard Self.record(asset, name: record.name).fingerprint == record.fingerprint else { throw PhotoError.message("Photos 资产已更新，请刷新范围并重新复核") }
        let gate = ImageRequestGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install { continuation.resume(with: $0) }
                if Task.isCancelled { gate.finish(.failure(CancellationError()), cancelRequest: true); return }
                let options = PHImageRequestOptions()
                options.version = .current; options.isNetworkAccessAllowed = allowNetwork
                options.deliveryMode = .highQualityFormat; options.resizeMode = .fast
                options.isSynchronous = false; options.allowSecondaryDegradedImage = false
                let id = manager.requestImage(for: asset, targetSize: CGSize(width: maxPixel, height: maxPixel), contentMode: .aspectFit, options: options) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true { gate.finish(.failure(CancellationError())); return }
                    if !allowNetwork && (info?[PHImageResultIsInCloudKey] as? Bool) == true && (image == nil || (info?[PHImageResultIsDegradedKey] as? Bool) == true) {
                        gate.finish(.failure(PhotoLoadError.cloud), cancelRequest: true); return
                    }
                    if let error = info?[PHImageErrorKey] as? Error { gate.finish(.failure(error)); return }
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                        if !allowNetwork && (info?[PHImageResultIsInCloudKey] as? Bool) == true { gate.finish(.failure(PhotoLoadError.cloud), cancelRequest: true) }
                        return
                    }
                    guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        gate.finish(.failure((info?[PHImageResultIsInCloudKey] as? Bool) == true ? PhotoLoadError.cloud : PhotoLoadError.missing)); return
                    }
                    gate.finish(.success(cg))
                }
                gate.bind(id, manager: manager)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (allowNetwork ? 120 : 25)) { [weak gate] in
                    gate?.finish(.failure(PhotoLoadError.timeout), cancelRequest: true)
                }
            }
        } onCancel: { gate.finish(.failure(CancellationError()), cancelRequest: true) }
    }
    public func availableAlbumNames(base: String, includeUnselected: Bool) throws -> [String] {
        guard PhotoAccess.canRead else { throw PhotoError.message(PhotoAccess.label) }
        var suffix = 1
        while true {
            let name = suffix == 1 ? base : "\(base)（\(suffix)）"
            let names = [name] + (includeUnselected ? [name + " · 待整理"] : [])
            if names.allSatisfy({ title in
                let options = PHFetchOptions(); options.predicate = NSPredicate(format: "title == %@", title)
                return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).count == 0
            }) { return names }
            suffix += 1
        }
    }
    /// Shared-album assets cannot be added as references to a personal album.
    public func copyRequiredIDs(session: SelectionSession, plan: SelectionPlan) throws -> Set<String> {
        guard PhotoAccess.canRead else { throw PhotoError.message("请先连接「照片」，再生成精选相册") }
        let ids = Set(plan.keepIDs + plan.unselectedIDs)
        let records = session.activeRecords.filter { ids.contains($0.id) }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: records.map(\.locator), options: nil)
        var result = Set<String>()
        fetched.enumerateObjects { asset, _, _ in
            if asset.sourceType.contains(.typeCloudShared) { result.insert("photos:" + asset.localIdentifier) }
        }
        return result
    }
    public static func outputToken(session: SelectionSession, includeExcluded: Bool, plan: SelectionPlan? = nil) -> String {
        let keep = (plan?.keepIDs ?? session.outputIDs(.keep)).sorted().joined(separator: "|")
        let exclude = includeExcluded ? (plan?.unselectedIDs ?? session.outputIDs(.exclude)).sorted().joined(separator: "|") : ""
        let fingerprints = plan.map { $0.entries.filter { $0.disposition == .keep || (includeExcluded && $0.disposition == .unselected) }.map { $0.id + ":" + $0.fingerprint }.sorted().joined(separator: "|") } ?? ""
        return stableID(session.id + "|keep:" + keep + "|exclude:" + exclude + (fingerprints.isEmpty ? "" : "|versions:" + fingerprints))
    }
    public func validateOutput(session: SelectionSession, includeExcluded: Bool, plan: SelectionPlan? = nil) throws -> Set<String> {
        guard PhotoAccess.canRead else { throw PhotoError.message(PhotoAccess.label) }
        if let plan {
            guard plan.permitsOutput, plan.scopeKey == session.scopeKey else { throw PhotoError.message("照片范围已改变，请重新查看精选清单") }
        }
        let ids = Set((plan?.keepIDs ?? session.outputIDs(.keep)) + (includeExcluded ? (plan?.unselectedIDs ?? session.outputIDs(.exclude)) : []))
        let selected = session.records.filter { ids.contains($0.id) }
        let fresh = refresh(selected); var stale = fresh.missing.union(ids.subtracting(Set(selected.map(\.id))))
        if let plan {
            let expected = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.id, $0.fingerprint) })
            stale.formUnion(selected.filter { expected[$0.id] != $0.fingerprint }.map(\.id))
        }
        let old = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
        for r in fresh.records where r.fingerprint != old[r.id]?.fingerprint || r.favorite != old[r.id]?.favorite { stale.insert(r.id) }
        return stale
    }
    public func recoverReceipt(token: String, names: [String], session: SelectionSession, includeExcluded: Bool, plan: SelectionPlan? = nil, journalURL: URL? = nil) throws -> AlbumReceipt? {
        guard !names.isEmpty else { return nil }
        guard PhotoAccess.canRead else { throw PhotoError.message(PhotoAccess.label) }
        let journal = try AlbumOutputJournal.load(from: journalURL, token: token)
        var albums: [PHAssetCollection] = []
        for name in names {
            let options = PHFetchOptions(); options.predicate = NSPredicate(format: "title == %@", name)
            let matches = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
            guard matches.count <= 1 else { throw PhotoError.message("发现多个同名结果相册，请先人工核对，避免重复创建。") }
            if let album = matches.firstObject { albums.append(album) }
        }
        guard !albums.isEmpty else { return nil }
        guard albums.count == names.count else { throw PhotoError.message("上次输出的结果相册不完整，请先在 Photos 中核对。") }
        for (i, album) in albums.enumerated() {
            let assets = PHAsset.fetchAssets(in: album, options: nil)
            var actual = Set<String>(); assets.enumerateObjects { asset, _, _ in actual.insert("photos:" + asset.localIdentifier) }
            let expected = journal.expectedIDs(plan.map { i == 0 ? $0.keepIDs : $0.unselectedIDs } ?? session.outputIDs(i == 0 ? .keep : .exclude))
            guard actual == expected else { throw PhotoError.message("上次结果相册内容已变化，请先人工核对，避免重复创建。") }
        }
        return AlbumReceipt(token: token, albumIDs: albums.map(\.localIdentifier), names: names, importedIDs: journal.importedIDs)
    }
    public func inspectPendingAlbums(names: [String]) throws -> [String] {
        guard PhotoAccess.status == .authorized else { throw PhotoError.message("需要完整照片授权才能核对未完成的相册输出。") }
        var ids: [String] = []
        for name in names {
            let options = PHFetchOptions(); options.predicate = NSPredicate(format: "title == %@", name)
            let matches = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
            guard matches.count <= 1 else { throw PhotoError.message("存在多个同名结果相册，请在 Photos 中核对后再继续。") }
            if let album = matches.firstObject { ids.append(album.localIdentifier) }
        }
        guard ids.isEmpty || ids.count == names.count else { throw PhotoError.message("上次输出相册只存在一部分，请在 Photos 中核对后再继续。") }
        return ids
    }
    public func createAlbums(session: SelectionSession, names: [String], includeExcluded: Bool, token: String, plan: SelectionPlan? = nil,
                             allowNetwork: Bool = false, approvedCopyIDs: Set<String> = [], journalURL: URL? = nil) async throws -> AlbumReceipt {
        guard try validateOutput(session: session, includeExcluded: includeExcluded, plan: plan).isEmpty else { throw PhotoError.message("部分照片已变化，请刷新来源并重新复核") }
        if let recovered = try recoverReceipt(token: token, names: names, session: session, includeExcluded: includeExcluded, plan: plan, journalURL: journalURL) { return recovered }
        let keep = plan?.keepIDs ?? session.outputIDs(.keep), exclude = includeExcluded ? (plan?.unselectedIDs ?? session.outputIDs(.exclude)) : []
        guard !keep.isEmpty, names.count == (includeExcluded && !exclude.isEmpty ? 2 : 1) else { throw PhotoError.message("输出数量或相册计划无效") }
        let byID = Dictionary(uniqueKeysWithValues: session.records.map { ($0.id, $0) })
        let keptAssets = try keep.map { try resolve(byID[$0]!) }
        let excludedAssets = try exclude.map { try resolve(byID[$0]!) }
        let allAssets = keptAssets + excludedAssets
        let shared = allAssets.filter { $0.sourceType.contains(.typeCloudShared) }
        guard shared.allSatisfy({ approvedCopyIDs.contains("photos:" + $0.localIdentifier) }) else {
            throw PhotoError.message("共享相册的照片需要先保存副本，请重新打开精选清单确认。")
        }
        guard shared.isEmpty || journalURL != nil else { throw PhotoError.message("无法保存共享照片的输出记录，本次未创建副本。") }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("TravelSelect-Output-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var resources: [String: [(PHAssetResource, URL)]] = [:]
        for asset in shared {
            try Task.checkCancellation()
            let originals = PHAssetResource.assetResources(for: asset)
            // Copy the supplied still/Live Photo resource bytes, never a resized preview.
            let supported = originals.filter { $0.type == .photo || $0.type == .pairedVideo }
            guard originals.count == supported.count, supported.contains(where: { $0.type == .photo }),
                  !asset.mediaSubtypes.contains(.photoLive) || supported.contains(where: { $0.type == .pairedVideo }),
                  PHAssetCreationRequest.supportsAssetResourceTypes(supported.map { NSNumber(value: $0.type.rawValue) }) else {
                throw PhotoError.message("这张共享照片的资源组合暂不能完整保存。请先在「照片」中保存至个人图库，再选择该副本。")
            }
            for resource in supported {
                let url = staging.appendingPathComponent(UUID().uuidString + "-" + URL(fileURLWithPath: resource.originalFilename).lastPathComponent)
                let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = allowNetwork
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                        if let error { continuation.resume(throwing: PhotoError.message("共享照片资源未能保存：\(error.localizedDescription)" + (allowNetwork ? "" : "。如照片尚未下载，可在设置中允许 iCloud 下载后重试。"))) }
                        else { continuation.resume() }
                    }
                }
                resources[asset.localIdentifier, default: []].append((resource, url))
            }
        }
        // Recheck after potentially slow downloads, before submitting the atomic transaction.
        try Task.checkCancellation()
        guard try validateOutput(session: session, includeExcluded: includeExcluded, plan: plan).isEmpty else { throw PhotoError.message("准备副本时来源照片发生变化，请刷新后重试。") }
        var journal = AlbumOutputJournal(token: token)
        if let journalURL { try journal.save(to: journalURL) }
        var identifiers: [String] = []
        var journalError: Error?
        try await PHPhotoLibrary.shared().performChanges {
            var added: [String: PHObjectPlaceholder] = [:]
            for asset in shared {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = asset.creationDate; request.location = asset.location; request.isFavorite = asset.isFavorite
                for (resource, url) in resources[asset.localIdentifier] ?? [] {
                    let options = PHAssetResourceCreationOptions(); options.originalFilename = resource.originalFilename
                    options.uniformTypeIdentifier = resource.uniformTypeIdentifier
                    request.addResource(with: resource.type, fileURL: url, options: options)
                }
                if let placeholder = request.placeholderForCreatedAsset {
                    added[asset.localIdentifier] = placeholder
                    journal.importedIDs["photos:" + asset.localIdentifier] = placeholder.localIdentifier
                }
            }
            // Save identifiers before submission so a restart can verify exact album membership.
            if let journalURL { do { try journal.save(to: journalURL) } catch { journalError = error } }
            func outputAssets(_ assets: [PHAsset]) -> NSArray { assets.map { added[$0.localIdentifier].map { $0 as PHObject } ?? $0 } as NSArray }
            let selected = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: names[0])
            selected.addAssets(outputAssets(keptAssets))
            if let id = selected.placeholderForCreatedAssetCollection.localIdentifier as String? { identifiers.append(id) }
            if names.count == 2 {
                let excluded = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: names[1])
                excluded.addAssets(outputAssets(excludedAssets))
                identifiers.append(excluded.placeholderForCreatedAssetCollection.localIdentifier)
            }
        }
        if let journalError { throw PhotoError.message("相册已经提交，但恢复记录未能保存：\(journalError.localizedDescription)。请先在「照片」中核对结果，不要重复创建。") }
        guard identifiers.count == names.count else { throw PhotoError.message("系统已处理创建相册的请求，但尚未返回完整结果；请重新尝试以核对已有结果。") }
        guard let receipt = try recoverReceipt(token: token, names: names, session: session, includeExcluded: includeExcluded, plan: plan, journalURL: journalURL) else {
            throw PhotoError.message("系统已处理创建请求，尚未读到结果；请核对上次相册。")
        }
        return receipt
    }
}

public final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: () -> Void
    public init(onChange: @escaping () -> Void) { self.onChange = onChange; super.init(); PHPhotoLibrary.shared().register(self) }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    public func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
}
