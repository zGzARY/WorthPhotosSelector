import Foundation
import ImageIO
import CryptoKit

public enum FolderSource {
    public static let extensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png"]
    public static func scan(_ roots: [URL], excluding: [String] = [], cancelled: () -> Bool = { false }) throws -> [PhotoRecord] {
        var found: [String: PhotoRecord] = [:]
        let fm = FileManager.default
        for root in roots {
            guard !root.pathComponents.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) else { throw PhotoError.message("不能读取 Photos 资料库包；请使用 Apple Photos 入口。") }
            if try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw PhotoError.message("请选择实际文件夹，不能扫描符号链接。") }
            if fm.fileExists(atPath: root.appendingPathComponent(".travel-select-output").path) { throw PhotoError.message("这是本应用的输出目录，请选择来源文件夹。") }
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isPackageKey]
            var enumerationError: Error?
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in enumerationError = error; return false }) else {
                throw PhotoError.message("无法读取所选文件夹，请重新授权。")
            }
            for case let url as URL in iterator {
                if cancelled() { throw CancellationError() }
                let p = url.standardizedFileURL.path
                if excluding.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { iterator.skipDescendants(); continue }
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true || values.isPackage == true || url.pathExtension.lowercased() == "photoslibrary" {
                    iterator.skipDescendants(); continue
                }
                if values.isDirectory == true {
                    if fm.fileExists(atPath: url.appendingPathComponent(".travel-select-output").path) { iterator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let record = try inspect(url)
                found[record.id] = record
            }
            if let enumerationError { throw enumerationError }
        }
        return found.values.sorted { $0.locator < $1.locator }
    }
    public static func inspect(_ url: URL) throws -> PhotoRecord {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let supported = extensions.contains(url.pathExtension.lowercased())
        var r = PhotoRecord(id: stableID(url.standardizedFileURL.path), source: .folder,
                            locator: url.standardizedFileURL.path, name: url.lastPathComponent,
                            modified: values.contentModificationDate, byteSize: values.fileSize.map(Int64.init), supported: supported)
        guard supported else { r.notes = ["首版仅分析 JPEG、HEIC、PNG"]; return r }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            r.notes = ["无法读取图像元数据，解码时将报告错误"]; return r
        }
        r.width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        r.height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        r.orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        if let original = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
            let sub = exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String
            r.captureDate = parseDate(original, offset: offset, subsecond: sub)
            r.timeNote = offset == nil ? "EXIF 未含时区；仅按相机钟面比较，跨设备时差未校正" : "EXIF 含时区偏移 \(offset!)"
        }
        if r.captureDate == nil { r.timeNote = "缺少可信拍摄时间；未使用文件修改时间替代" }
        return r
    }
    public static func parseDate(_ text: String, offset: String?, subsecond: String?) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        // Unknown zones use a fixed reference, never the machine's mutable local zone.
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = offset == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssXXXXX"
        guard let d = f.date(from: text + (offset ?? "")) else { return nil }
        let digits = (subsecond ?? "").prefix(9)
        let fraction = digits.allSatisfy(\.isNumber) ? (Double("0." + digits) ?? 0) : 0
        return d.addingTimeInterval(fraction)
    }
    public static func decode(_ url: URL, maxPixel: Int = VisionAnalyzer.analysisSize) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw PhotoError.message("图片损坏或系统无法解码") }
        return image
    }
    public static func sha256(_ url: URL, cancelled: () -> Bool = { false }) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while true {
            if cancelled() { throw CancellationError() }
            let chunk = try file.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }; hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func byteEqual(_ a: URL, _ b: URL, cancelled: () -> Bool = { false }) throws -> Bool {
        let x = try FileHandle(forReadingFrom: a), y = try FileHandle(forReadingFrom: b)
        defer { try? x.close(); try? y.close() }
        while true {
            if cancelled() { throw CancellationError() }
            let p = try x.read(upToCount: 1024 * 1024) ?? Data(), q = try y.read(upToCount: 1024 * 1024) ?? Data()
            if p != q { return false }; if p.isEmpty { return true }
        }
    }
    public static func exactGroups(_ records: [PhotoRecord], cancelled: () -> Bool = { false }) throws -> [PhotoGroup] {
        var groups: [PhotoGroup] = [], used = Set<String>()
        let buckets = Dictionary(grouping: records.filter { $0.source == .folder && $0.supported && $0.byteSize != nil }, by: { $0.byteSize! })
        for size in buckets.keys.sorted() {
            let bucket = buckets[size]!.sorted { $0.id < $1.id }
            guard bucket.count > 1 else { continue }
            var hashes: [String: [PhotoRecord]] = [:]
            for r in bucket {
                let hash = try sha256(URL(fileURLWithPath: r.locator), cancelled: cancelled)
                hashes[hash, default: []].append(r)
            }
            for key in hashes.keys.sorted() {
                var partitions: [[PhotoRecord]] = []
                for record in hashes[key]! {
                    var matching: Int?
                    for i in partitions.indices {
                        if try byteEqual(URL(fileURLWithPath: partitions[i][0].locator), URL(fileURLWithPath: record.locator), cancelled: cancelled) { matching = i; break }
                    }
                    if let matching { partitions[matching].append(record) } else { partitions.append([record]) }
                }
                for p in partitions where p.count > 1 {
                    groups.append(PhotoGroup(members: p.map(\.id), kind: .exact)); used.formUnion(p.map(\.id))
                }
            }
        }
        groups += records.filter { !used.contains($0.id) }.map { PhotoGroup(members: [$0.id], kind: .single) }
        return groups.sorted { $0.id < $1.id }
    }
}
