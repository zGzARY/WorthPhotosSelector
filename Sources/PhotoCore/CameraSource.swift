import Foundation
import Combine
import ImageCaptureCore
import ImageIO

/// A camera handle is never persisted. Records contain device/resource identity,
/// and each read resolves that identity against the currently connected catalog.
@MainActor
public final class CameraSource: NSObject, ObservableObject, @preconcurrency ICDeviceBrowserDelegate, @preconcurrency ICCameraDeviceDelegate {
    public static let shared = CameraSource()
    @Published public private(set) var devices: [CameraSourceDescriptor] = []
    @Published public private(set) var selected: CameraSourceDescriptor?
    @Published public private(set) var records: [PhotoRecord] = []
    @Published public private(set) var catalogComplete = false
    @Published public private(set) var connected = false
    @Published public private(set) var status = "连接相机后，点击刷新设备"
    @Published public private(set) var importingOriginals = false
    public func setImportingOriginals(_ active: Bool) { importingOriginals = active; readQueue.importing = active }
    public var onCatalog: ((CameraSourceDescriptor, [PhotoRecord], Bool) -> Void)?
    public var onDisconnect: ((String) -> Void)?
    private var browser = ICDeviceBrowser()
    private var discoveryTask: Task<Void, Never>?
    private var cameras: [String: ICCameraDevice] = [:]
    private var files: [String: ICCameraFile] = [:]
    private let readQueue = CameraReadQueue()
    private var finishOperation: ((Error) -> Void)?
    private var catalogTask: Task<Void, Never>?
    private var catalogRefreshTask: Task<Void, Never>?
    private var revision = UUID()
    private var pendingOpenID: String?
    private var intentionalClose = false
    private var pairingRefreshAttempted = false
    private var finalizingCatalog = false

    public override init() { super.init() }
    public func discover() {
        if !browser.isBrowsing {
            browser.delegate = self
            browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
            browser.start()
            let currentBrowser = browser
            discoveryTask?.cancel()
            discoveryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.browser === currentBrowser, self.devices.isEmpty else { return }
                self.status = "尚未收到相机响应。请检查系统的可移动宗卷访问提示，或重新连接后刷新设备。"
            }
        }
        if devices.isEmpty { status = "正在查找相机；请保持相机开机并连接 USB" }
    }
    public func refreshDevices() {
        guard !connected else { return }
        discoveryTask?.cancel()
        browser.stop(); browser.delegate = nil
        browser = ICDeviceBrowser(); cameras = [:]; devices = []
        discover()
    }
    public func open(_ descriptor: CameraSourceDescriptor) throws {
        guard let camera = cameras[descriptor.id] else { throw PhotoError.message("相机已断开，请重新连接并刷新设备") }
        if selected?.id == descriptor.id, connected, camera.hasOpenSession {
            refreshCatalog(camera, complete: catalogComplete)
            onCatalog?(descriptor, records, catalogComplete)
            return
        }
        let closingSameCamera = selected?.id == descriptor.id && camera.hasOpenSession
        close()
        intentionalClose = false
        selected = descriptor; catalogComplete = false; records = []; files = [:]
        pairingRefreshAttempted = false; finalizingCatalog = false
        camera.delegate = self; status = "正在连接 \(descriptor.name)…"
        if closingSameCamera { pendingOpenID = descriptor.id }
        else { camera.requestOpenSession() }
        let token = revision
        catalogTask = Task { [weak self] in
            // Cataloging large memory cards can take minutes. Report progress,
            // but do not mislabel a partially enumerated card as complete.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, token == self.revision else { return }
                if camera.hasOpenSession && !self.finalizingCatalog {
                    self.refreshCatalog(camera, complete: self.catalogComplete)
                }
                if self.catalogComplete { return }
            }
        }
    }
    public func close() {
        intentionalClose = true
        pendingOpenID = nil
        revision = UUID(); catalogTask?.cancel(); catalogTask = nil
        catalogRefreshTask?.cancel(); catalogRefreshTask = nil
        finishOperation?(PhotoError.message("相机连接已关闭")); finishOperation = nil
        if let id = selected?.id, let camera = cameras[id], camera.hasOpenSession { camera.requestCloseSession() }
        connected = false; catalogComplete = false
    }
    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        let identity = camera.serialNumberString.flatMap { $0.isEmpty ? nil : $0 } ?? camera.uuidString ?? UUID().uuidString
        let id = stableID("camera|\(camera.usbVendorID)|\(camera.usbProductID)|\(identity)")
        cameras[id] = camera
        discoveryTask?.cancel()
        let descriptor = CameraSourceDescriptor(id: id, name: camera.name ?? "相机", transport: .ptp)
        devices.removeAll { $0.id == id }; devices.append(descriptor); devices.sort { $0.name < $1.name }
        if !connected { status = "发现 \(devices.count) 台相机" }
    }
    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let ids = cameras.filter { $0.value === device }.map(\.key)
        for id in ids { cameras[id] = nil; devices.removeAll { $0.id == id } }
        if ids.contains(selected?.id ?? "") { disconnected("相机已断开；选择已保存，重新连接后可以继续") }
        else if !connected { status = devices.isEmpty ? "相机已断开，请保持开机并重新连接 USB" : "发现 \(devices.count) 台相机" }
    }
    public func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        if devices.isEmpty { status = "尚未发现相机。请检查电源、USB 连接及相机的读卡／传输模式" }
    }
    public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard let id = selected?.id, cameras[id] === device else { return }
        if let error { disconnected("连接失败：\(error.localizedDescription)"); return }
        connected = true; status = "正在读取相机目录…"
        if let camera = device as? ICCameraDevice { scheduleCatalogRefresh(camera) }
    }
    public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        guard let id = selected?.id, cameras[id] === device else { return }
        if pendingOpenID == id { pendingOpenID = nil; device.requestOpenSession(); return }
        if intentionalClose { intentionalClose = false; return }
        disconnected(error.map { "相机连接中断：" + $0.localizedDescription } ?? "相机读取会话已关闭；可以重新连接")
    }
    public func didRemove(_ device: ICDevice) { deviceBrowser(browser, didRemove: device, moreGoing: false) }
    private func disconnected(_ message: String) {
        connected = false; catalogComplete = false; status = message
        revision = UUID(); catalogTask?.cancel()
        catalogRefreshTask?.cancel(); catalogRefreshTask = nil
        finishOperation?(PhotoError.message(message)); finishOperation = nil
        onDisconnect?(message)
    }
    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) { scheduleCatalogRefresh(camera) }
    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { scheduleCatalogRefresh(camera) }
    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) { scheduleCatalogRefresh(camera) }
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { disconnected("相机访问受限，请在设备上允许连接后重试") }
    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard connected, let id = selected?.id, cameras[id] === device else { return }
        catalogRefreshTask?.cancel(); catalogRefreshTask = nil
        finalizingCatalog = true
        let token = revision
        catalogRefreshTask = Task { [weak self] in
            // Some PTP drivers publish the file list before RAW companion links.
            // Let queued catalog updates settle, then reopen once if links are missing.
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, token == self.revision, self.connected else { return }
            self.catalogRefreshTask = nil
            let photos = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }.filter {
                ExternalAssets.isPhoto(name: $0.name ?? "", typeIdentifier: $0.uti)
            }
            guard let descriptor = self.selected else { return }
            let pairedIDs = Set(photos.compactMap(\.pairedRawImage).map { self.resource($0, deviceID: descriptor.id).id })
            let unresolved = ExternalAssets.unresolvedCameraPairs(photos.map { self.resource($0, deviceID: descriptor.id) }, pairedRawIDs: pairedIDs)
            if unresolved > 0 {
                if !self.pairingRefreshAttempted {
                    self.pairingRefreshAttempted = true
                    self.status = "正在补读 RAW＋JPEG 配对信息…"
                    self.pendingOpenID = descriptor.id
                    self.reopenCatalog(device)
                } else {
                    self.close()
                    self.disconnected("有 \(unresolved) 组 RAW＋JPEG 配对尚未得到相机确认；请重新连接后继续")
                }
                return
            }
            self.finalizingCatalog = false
            self.refreshCatalog(device, complete: true)
        }
    }

    private func reopenCatalog(_ device: ICCameraDevice) { device.requestCloseSession() }

    private func scheduleCatalogRefresh(_ camera: ICCameraDevice) {
        guard catalogRefreshTask == nil, !finalizingCatalog else { return }
        let token = revision
        catalogRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, token == self.revision else { return }
            self.catalogRefreshTask = nil
            self.refreshCatalog(camera, complete: self.catalogComplete)
        }
    }

    private func path(_ item: ICCameraItem) -> String {
        var components = [item.name ?? "未命名"], parent = item.parentFolder
        while let folder = parent { components.insert(folder.name ?? "", at: 0); parent = folder.parentFolder }
        return components.joined(separator: "/")
    }
    private func resource(_ file: ICCameraFile, deviceID: String) -> OriginalPhotoResource {
        let locator = path(file)
        return OriginalPhotoResource(id: stableID(deviceID + "|" + locator), locator: locator,
            name: file.originalFilename ?? file.name ?? "未命名", byteSize: Int64(file.fileSize),
            modified: Self.validDate(file.fileModificationDate), captureDate: nil,
            isRaw: file.isRaw || ExternalAssets.isRaw(name: file.name ?? "", typeIdentifier: file.uti), typeIdentifier: file.uti)
    }
    private func refreshCatalog(_ camera: ICCameraDevice, complete: Bool) {
        guard connected, !intentionalClose, let descriptor = selected, cameras[descriptor.id] === camera else { return }
        let photos = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }.filter {
            ExternalAssets.isPhoto(name: $0.name ?? "", typeIdentifier: $0.uti)
        }
        var nextFiles: [String: ICCameraFile] = [:]
        for file in photos {
            nextFiles[resource(file, deviceID: descriptor.id).id] = file
            if let raw = file.pairedRawImage { nextFiles[resource(raw, deviceID: descriptor.id).id] = raw }
        }
        let pairedRawIDs = Set(photos.compactMap { $0.pairedRawImage }.map { resource($0, deviceID: descriptor.id).id })
        var next: [PhotoRecord] = []
        for file in photos {
            let primary = resource(file, deviceID: descriptor.id)
            if pairedRawIDs.contains(primary.id) { continue }
            var resources = [primary]
            if let raw = file.pairedRawImage { resources.append(resource(raw, deviceID: descriptor.id)) }
            let ref = ExternalPhotoReference(deviceID: descriptor.id, transport: .ptp, resources: resources)
            var record = PhotoRecord(id: "camera:" + primary.id, source: .camera, locator: primary.id,
                name: primary.name + (resources.count > 1 ? " · RAW＋JPEG" : ""), captureDate: Self.validDate(file.exifCreationDate),
                timeNote: "EXIF 未含时区；按相机钟面比较", modified: Self.validDate(file.fileModificationDate),
                byteSize: resources.reduce(0) { $0 + $1.byteSize }, width: file.width, height: file.height,
                orientation: UInt32(file.orientation.rawValue))
            if record.captureDate == nil { record.timeNote = "相机尚未提供可信拍摄时间" }
            record.external = ref; next.append(record)
        }
        files = nextFiles
        let ordered = Grouping.ordered(next)
        let changed = records != ordered || (complete && !catalogComplete)
        records = ordered; catalogComplete = catalogComplete || complete
        status = catalogComplete ? "\(descriptor.name) · \(records.count) 张照片" : "正在读取 \(descriptor.name) · 已发现 \(records.count) 张照片"
        if changed { onCatalog?(descriptor, records, catalogComplete) }
    }
    nonisolated public static func validDate(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970.isFinite,
              (-2208988800...7258118400).contains(date.timeIntervalSince1970) else { return nil }
        return date
    }
    nonisolated public static func addingMetadata(_ metadata: [AnyHashable: Any], to record: PhotoRecord) -> PhotoRecord {
        var result = record
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        if let value = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
            result.captureDate = validDate(FolderSource.parseDate(value, offset: offset, subsecond: exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String))
            result.timeNote = offset == nil ? "EXIF 未含时区；按相机钟面比较" : "EXIF 含时区偏移 \(offset!)"
        }
        if result.captureDate == nil { result.timeNote = "相机照片缺少可用的 EXIF 拍摄时间" }
        return result
    }
    public func prepareForAnalysis(_ record: PhotoRecord) async throws -> PhotoRecord {
        guard record.captureDate == nil, record.timeNote == "相机尚未提供可信拍摄时间",
              let resource = record.external?.displayResource else { return record }
        let file = try resolve(record, resource: resource)
        let metadata: [AnyHashable: Any]
        do {
            metadata = try await perform { gate in
                let current = try self.resolve(record, resource: resource)
                current.requestMetadataDictionary(options: nil) { metadata, error in
                    if let error { gate.finish(.failure(error)) }
                    else { gate.finish(.success(metadata ?? [:])) }
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard connected else { throw error }
            var prepared = record
            prepared.timeNote = "未能读取 EXIF 拍摄时间；仅按视觉分组"
            return prepared
        }
        var prepared = Self.addingMetadata(metadata, to: record)
        if prepared.captureDate == nil, let date = Self.validDate(file.exifCreationDate) {
            prepared.captureDate = date; prepared.timeNote = "EXIF 未含时区；按相机钟面比较"
        }
        return prepared
    }
    private func resolve(_ record: PhotoRecord, resource: OriginalPhotoResource) throws -> ICCameraFile {
        guard connected, selected?.id == record.external?.deviceID else { throw PhotoError.message("请连接照片所属的相机，当前选择已保存") }
        guard catalogComplete else { throw PhotoError.message("相机目录仍在读取，完成后即可查看照片") }
        guard let file = files[resource.id], let deviceID = selected?.id,
              self.resource(file, deviceID: deviceID).fingerprint == resource.fingerprint else {
            throw PhotoError.message("相机文件已变化或不再存在，请刷新相机目录并重新确认")
        }
        return file
    }
    private func perform<T>(timeout: Duration = .seconds(45), preview: Bool = false,
                            _ operation: (CameraCallback<T>) throws -> Void) async throws -> T {
        let epoch = revision
        try await readQueue.acquire(preview: preview) { epoch == self.revision && self.connected }
        defer { readQueue.release(); finishOperation = nil }
        let gate = CameraCallback<T>()
        finishOperation = { gate.finish(.failure($0)) }
        let timer = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                if gate.finish(.failure(PhotoError.message("相机读取超时，请重新连接相机后继续"))) {
                    self?.close()
                    self?.disconnected("相机读取超时，请重新连接相机后继续")
                }
            } catch {}
        }
        defer { timer.cancel() }
        let result: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                do { try Task.checkCancellation(); try operation(gate) }
                catch { gate.finish(.failure(error)) }
            }
        } onCancel: { gate.finish(.failure(CancellationError())) }
        try Task.checkCancellation()
        return result
    }
    public func image(_ record: PhotoRecord, maxPixel: Int, allowOriginal: Bool) async throws -> AnalysisImage {
        guard let ref = record.external, let source = ref.displayResource else { throw PhotoError.message("缺少相机资源信息") }
        _ = try resolve(record, resource: source)
        let data: Data = try await perform(preview: true) { gate in
            let current = try self.resolve(record, resource: source)
            current.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: maxPixel]) { data, error in
                if let error { gate.finish(.failure(error)) }
                else if let data { gate.finish(.success(data)) }
                else { gate.finish(.failure(PhotoError.message("相机没有返回预览"))) }
            }
        }
        let image = try await Task.detached { try Self.decodePreview(data, maxPixel: maxPixel) }.value
        let required = min(1000, max(record.width, record.height) > 0 ? max(record.width, record.height) : 1000)
        let sufficient = max(image.width, image.height) >= required
        if allowOriginal && max(image.width, image.height) < min(maxPixel, max(record.width, record.height) > 0 ? max(record.width, record.height) : maxPixel) {
            let original = try await materialize(record, forPreview: true)
            defer { original.cleanup() }
            let index = original.resources.firstIndex(where: { !$0.isRaw }) ?? 0
            let full = try await Task.detached { try FolderSource.decode(original.files[index], maxPixel: maxPixel) }.value
            return AnalysisImage(image: full, kind: "cameraOriginal", fingerprint: record.fingerprint)
        }
        return AnalysisImage(image: image, kind: "cameraPreview", fingerprint: record.fingerprint, permitsQuality: sufficient)
    }
    nonisolated public static func decodePreview(_ data: Data, maxPixel: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw PhotoError.message("相机预览无法解码") }
        return image
    }
    public func materialize(_ record: PhotoRecord, forPreview: Bool = false) async throws -> MaterializedPhoto {
        guard let ref = record.external, !ref.resources.isEmpty else { throw PhotoError.message("缺少相机原文件") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TravelSelect-Camera-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            let required = ref.resources.reduce(Int64(0)) { $0 + $1.byteSize }
            if let available, available < required + 64 * 1024 * 1024 { throw PhotoError.message("本机空间不足以暂存这张原片，请释放空间后继续") }
            var urls: [URL] = []
            for (index, resource) in ref.resources.enumerated() {
                try Task.checkCancellation()
                _ = try resolve(record, resource: resource)
                let filename = "\(index)-" + URL(fileURLWithPath: resource.name).lastPathComponent
                let target = root.appendingPathComponent(filename)
                let _: String = try await perform(timeout: .seconds(180), preview: forPreview) { gate in
                    let current = try self.resolve(record, resource: resource)
                    let download = current.requestDownload(options: [.downloadsDirectoryURL: root, .saveAsFilename: filename,
                        .overwrite: false, .deleteAfterSuccessfulDownload: false]) { name, error in
                        let accepted: Bool
                        if let error { accepted = gate.finish(.failure(error)) }
                        else { accepted = gate.finish(.success(name ?? filename)) }
                        if !accepted { try? FileManager.default.removeItem(at: root) }
                    }
                    gate.onCancellation { download?.cancel() }
                }
                let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard size.map(Int64.init) == resource.byteSize else { throw PhotoError.message("原片传输不完整，尚未导入图库，请重试") }
                _ = try resolve(record, resource: resource)
                urls.append(target)
            }
            return MaterializedPhoto(files: urls, resources: ref.resources, temporaryDirectory: root)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
}

@MainActor
final class CameraReadQueue {
    var importing = false
    private var busy = false
    func acquire(preview: Bool, timeout: Duration = .seconds(45), current: () -> Bool) async throws {
        var waitStart = ContinuousClock.now
        while busy || (preview && importing) {
            try Task.checkCancellation()
            guard current() else { throw PhotoError.message("相机连接已变化，请重新连接后继续") }
            if preview && importing { waitStart = .now }
            else if ContinuousClock.now - waitStart > timeout { throw PhotoError.message("相机读取队列等待超时，请重试") }
            try await Task.sleep(for: .milliseconds(30))
        }
        try Task.checkCancellation()
        guard current() else { throw PhotoError.message("相机连接已变化，请重新连接后继续") }
        busy = true
    }
    func release() { busy = false }
}

/// System APIs can deliver late callbacks after timeout or disconnect.
final class CameraCallback<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var cancelAction: (@Sendable () -> Void)?
    func onCancellation(_ action: @escaping @Sendable () -> Void) {
        lock.lock(); cancelAction = action
        let failed: Bool
        if case .failure? = result { failed = true } else { failed = false }
        lock.unlock(); if failed { action() }
    }
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    @discardableResult func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result; let continuation = self.continuation; self.continuation = nil
        let cancel = cancelAction; cancelAction = nil; lock.unlock()
        if case .failure = result { cancel?() }
        continuation?.resume(with: result); return true
    }
}
