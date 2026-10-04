import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CameraTransport: String, Codable, Sendable { case ptp, storage }
public struct CameraSourceDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var transport: CameraTransport
    public var rootPath: String?
    public init(id: String, name: String, transport: CameraTransport, rootPath: String? = nil) {
        self.id = id; self.name = name; self.transport = transport; self.rootPath = rootPath
    }
}
public struct OriginalPhotoResource: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var locator: String
    public var name: String
    public var byteSize: Int64
    public var modified: Date?
    public var captureDate: Date?
    public var isRaw: Bool
    public var typeIdentifier: String?
    public init(id: String, locator: String, name: String, byteSize: Int64, modified: Date? = nil,
                captureDate: Date? = nil, isRaw: Bool = false, typeIdentifier: String? = nil) {
        self.id = id; self.locator = locator; self.name = name; self.byteSize = byteSize
        self.modified = modified; self.captureDate = captureDate; self.isRaw = isRaw; self.typeIdentifier = typeIdentifier
    }
    public var fingerprint: String {
        stableID([id, locator, name, String(byteSize), String(modified?.timeIntervalSince1970 ?? -1),
                  String(captureDate?.timeIntervalSince1970 ?? -1), String(isRaw)].joined(separator: "|"))
    }
}
public struct ExternalPhotoReference: Codable, Equatable, Sendable {
    public var deviceID: String
    public var transport: CameraTransport
    public var resources: [OriginalPhotoResource]
    public init(deviceID: String, transport: CameraTransport, resources: [OriginalPhotoResource]) {
        self.deviceID = deviceID; self.transport = transport; self.resources = resources
    }
    public var fingerprint: String { stableID(deviceID + "|" + resources.map(\.fingerprint).sorted().joined(separator: "|")) }
    public var displayResource: OriginalPhotoResource? { resources.first(where: { !$0.isRaw }) ?? resources.first }
}

public struct AnalysisImage: @unchecked Sendable {
    public var image: CGImage
    public var kind: String
    public var signature: String
    public var permitsQuality: Bool
    public init(image: CGImage, kind: String, fingerprint: String, permitsQuality: Bool = true) {
        self.image = image; self.kind = kind; self.permitsQuality = permitsQuality
        signature = stableID("\(fingerprint)|\(kind)|\(image.width)x\(image.height)")
    }
}

public struct MaterializedPhoto: Sendable {
    public var files: [URL]
    public var resources: [OriginalPhotoResource]
    public var temporaryDirectory: URL?
    public init(files: [URL], resources: [OriginalPhotoResource], temporaryDirectory: URL? = nil) {
        self.files = files; self.resources = resources; self.temporaryDirectory = temporaryDirectory
    }
    public func cleanup() { if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }
}

public enum ExternalAssets {
    public static func isPhoto(name: String, typeIdentifier: String? = nil) -> Bool {
        let declared = typeIdentifier.flatMap(UTType.init)
        let inferred = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension)
        return declared?.conforms(to: .image) == true || inferred?.conforms(to: .image) == true
    }
    public static func isRaw(name: String, typeIdentifier: String? = nil) -> Bool {
        let declared = typeIdentifier.flatMap(UTType.init)
        let inferred = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension)
        return declared?.conforms(to: .rawImage) == true || inferred?.conforms(to: .rawImage) == true
    }
    /// A matching stem only signals that the system catalog may still be pairing.
    /// It must never be used as proof that two originals are the same capture.
    static func unresolvedCameraPairs(_ resources: [OriginalPhotoResource], pairedRawIDs: Set<String>) -> Int {
        let buckets = Dictionary(grouping: resources) {
            URL(fileURLWithPath: $0.locator).deletingPathExtension().path.lowercased()
        }
        return buckets.values.filter { bucket in
            bucket.contains { !$0.isRaw } && bucket.contains { $0.isRaw && !pairedRawIDs.contains($0.id) }
        }.count
    }
    /// Filename is only a pairing candidate: both files must also agree on EXIF time and geometry.
    public static func pairStorageRecords(_ input: [PhotoRecord], descriptor: CameraSourceDescriptor) -> [PhotoRecord] {
        let buckets = Dictionary(grouping: input) { URL(fileURLWithPath: $0.locator).deletingPathExtension().path.lowercased() }
        var output: [PhotoRecord] = []
        for key in buckets.keys.sorted() {
            let entries = buckets[key]!.sorted { $0.locator < $1.locator }
            let raw = entries.filter { isRaw(name: $0.name) }
            let processed = entries.filter { !isRaw(name: $0.name) }
            let pair = raw.count == 1 && processed.count == 1 && raw[0].captureDate != nil &&
                raw[0].captureDate == processed[0].captureDate && raw[0].width == processed[0].width &&
                raw[0].height == processed[0].height && raw[0].width > 0
            for unit in pair ? [entries] : entries.map({ [$0] }) {
                var record = unit.first(where: { !isRaw(name: $0.name) }) ?? unit[0]
                let resources = unit.map { item in
                    OriginalPhotoResource(id: stableID(descriptor.id + "|" + item.locator), locator: item.locator,
                        name: item.name, byteSize: item.byteSize ?? 0, modified: item.modified, captureDate: item.captureDate,
                        isRaw: isRaw(name: item.name), typeIdentifier: UTType(filenameExtension: URL(fileURLWithPath: item.name).pathExtension)?.identifier)
                }
                record.source = .camera
                record.id = stableID(descriptor.id + "|" + resources.map(\.id).sorted().joined(separator: "|"))
                record.external = ExternalPhotoReference(deviceID: descriptor.id, transport: .storage, resources: resources)
                record.byteSize = resources.reduce(0) { $0 + $1.byteSize }
                record.name = pair ? URL(fileURLWithPath: record.name).deletingPathExtension().lastPathComponent + " · RAW＋JPEG" : record.name
                output.append(record)
            }
        }
        return Grouping.ordered(output)
    }
    public static func inspectStorage(_ url: URL) throws -> PhotoRecord {
        var record = try FolderSource.inspect(url)
        guard isPhoto(name: url.lastPathComponent), !record.supported else { return record }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return record }
        record.supported = true; record.notes = []
        record.width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        record.height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        record.orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        if let date = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
            record.captureDate = FolderSource.parseDate(date, offset: offset, subsecond: exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String)
            record.timeNote = offset == nil ? "EXIF 未含时区；按相机钟面比较" : "EXIF 含时区偏移 \(offset!)"
        }
        return record
    }
}
