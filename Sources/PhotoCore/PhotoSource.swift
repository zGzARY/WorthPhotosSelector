import Foundation
import ImageIO

/// All UI previews and analysis inputs pass through the same source resolver.
public enum PhotoSource {
    public static func prepareForAnalysis(_ record: PhotoRecord) async throws -> PhotoRecord {
        if record.source == .camera, record.external?.transport == .ptp {
            return try await CameraSource.shared.prepareForAnalysis(record)
        }
        return record
    }
    public static func image(_ record: PhotoRecord, maxPixel: Int = VisionAnalyzer.analysisSize,
                             allowNetwork: Bool = false, allowOriginal: Bool = false) async throws -> AnalysisImage {
        switch record.source {
        case .photos:
            let image = try await PhotoLibrarySource.shared.image(record, maxPixel: maxPixel, allowNetwork: allowNetwork)
            return AnalysisImage(image: image, kind: "photosCurrent", fingerprint: record.fingerprint)
        case .folder:
            let current = try FolderSource.inspect(URL(fileURLWithPath: record.locator))
            guard current.fingerprint == record.fingerprint else { throw PhotoError.message("来源已更改，请刷新后重新确认") }
            return AnalysisImage(image: try FolderSource.decode(URL(fileURLWithPath: record.locator), maxPixel: maxPixel), kind: "file", fingerprint: record.fingerprint)
        case .camera:
            if record.external?.transport == .storage {
                let originals = try await materialize(record)
                let index = originals.resources.firstIndex(where: { !$0.isRaw }) ?? 0
                return AnalysisImage(image: try FolderSource.decode(originals.files[index], maxPixel: maxPixel), kind: "cameraOriginal", fingerprint: record.fingerprint)
            }
            return try await CameraSource.shared.image(record, maxPixel: maxPixel, allowOriginal: allowOriginal)
        }
    }
    public static func materialize(_ record: PhotoRecord) async throws -> MaterializedPhoto {
        if record.source == .camera, record.external?.transport == .ptp { return try await CameraSource.shared.materialize(record) }
        let resources: [OriginalPhotoResource]
        if let external = record.external { resources = external.resources }
        else {
            guard record.source == .folder else { throw PhotoError.message("此来源不支持文件导入") }
            let current = try FolderSource.inspect(URL(fileURLWithPath: record.locator))
            guard current.fingerprint == record.fingerprint else { throw PhotoError.message("来源文件已变化，请重新确认") }
            resources = [OriginalPhotoResource(id: record.id, locator: record.locator, name: record.name, byteSize: record.byteSize ?? 0,
                modified: record.modified, captureDate: record.captureDate, isRaw: ExternalAssets.isRaw(name: record.name))]
        }
        guard !resources.isEmpty else { throw PhotoError.message("缺少原始照片资源") }
        let urls = try resources.map { resource -> URL in
            let url = URL(fileURLWithPath: resource.locator)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard values.fileSize.map(Int64.init) == resource.byteSize, values.contentModificationDate == resource.modified else {
                throw PhotoError.message("原文件已变化，请重新读取来源并确认")
            }
            return url
        }
        return MaterializedPhoto(files: urls, resources: resources)
    }
}
