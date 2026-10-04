import Foundation
import CryptoKit

public enum SourceKind: String, Codable { case folder, photos, camera }
public enum OutputDestination: String, Codable { case folder, photos }
public enum AnalysisStatus: String, Codable, CaseIterable {
    case pending, running, success, partial, failed, cancelled, cloudUnavailable, unsupported
    public var label: String {
        switch self {
        case .pending: return "未分析"
        case .running: return "分析中"
        case .success: return "分析成功"
        case .partial: return "未完整分析"
        case .failed: return "分析失败"
        case .cancelled: return "已取消"
        case .cloudUnavailable: return "未下载／本机不可用"
        case .unsupported: return "不支持的格式"
        }
    }
}
public enum UserChoice: String, Codable { case unreviewed, keep, exclude }
public struct Decision: Codable, Equatable {
    public var choice: UserChoice = .unreviewed
    public var locked = false
    public init(choice: UserChoice = .unreviewed, locked: Bool = false) { self.choice = choice; self.locked = locked }
}
public struct PhotoRecord: Codable, Identifiable, Equatable {
    public var id: String
    public var source: SourceKind
    public var locator: String
    public var name: String
    public var captureDate: Date?
    public var timeNote: String?
    public var modified: Date?
    public var byteSize: Int64?
    public var width: Int
    public var height: Int
    public var orientation: UInt32
    public var favorite: Bool
    public var burstID: String?
    public var mediaSubtypes: UInt
    public var notes: [String]
    public var supported: Bool
    public var external: ExternalPhotoReference?
    public init(id: String, source: SourceKind, locator: String, name: String,
                captureDate: Date? = nil, timeNote: String? = nil, modified: Date? = nil,
                byteSize: Int64? = nil, width: Int = 0, height: Int = 0,
                orientation: UInt32 = 1, favorite: Bool = false, burstID: String? = nil,
                mediaSubtypes: UInt = 0, notes: [String] = [], supported: Bool = true) {
        self.id = id; self.source = source; self.locator = locator; self.name = name
        self.captureDate = captureDate; self.timeNote = timeNote; self.modified = modified
        self.byteSize = byteSize; self.width = width; self.height = height; self.orientation = orientation
        self.favorite = favorite; self.burstID = burstID; self.mediaSubtypes = mediaSubtypes
        self.notes = notes; self.supported = supported
    }
    public var fingerprint: String {
        let base = [source.rawValue, locator, String(modified?.timeIntervalSince1970 ?? -1),
                    String(byteSize ?? -1), "\(width)x\(height)", "\(mediaSubtypes)"].joined(separator: "|")
        return stableID(base + (external.map { "|resources:" + $0.fingerprint } ?? ""))
    }
}
public struct FaceMeasure: Codable, Equatable {
    public var x, y, width, height: Double
    public var quality: Float?
    public init(x: Double, y: Double, width: Double, height: Double, quality: Float?) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.quality = quality
    }
}
public struct AnalysisResult: Codable {
    public var cacheKey: String
    public var status: AnalysisStatus
    public var feature: Data?
    public var aesthetics: Float?
    public var utility: Bool?
    public var faces: [FaceMeasure]
    public var issues: [String]
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var qualityComplete: Bool?
    public var inputSignature: String?
    public var inputKind: String?
    public init(cacheKey: String = "", status: AnalysisStatus = .pending, feature: Data? = nil,
                aesthetics: Float? = nil, utility: Bool? = nil, faces: [FaceMeasure] = [],
                issues: [String] = [], pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.cacheKey = cacheKey; self.status = status; self.feature = feature
        self.aesthetics = aesthetics; self.utility = utility; self.faces = faces; self.issues = issues
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
}
public enum GroupKind: String, Codable, Sendable { case similar, exact, single, manual }
public struct PhotoGroup: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var members: [String]
    public var kind: GroupKind
    public var needsReview: Bool
    public var samePersonConfirmed: Bool
    /// Fine visual groups remain the units of recommendation when scenes are widened.
    public var recommendationUnits: [[String]]?
    public init(members: [String], kind: GroupKind, needsReview: Bool = false, samePersonConfirmed: Bool = false) {
        self.members = members; self.kind = kind; self.needsReview = needsReview
        self.samePersonConfirmed = samePersonConfirmed
        self.id = stableID(members.sorted().joined(separator: "|"))
    }
    public var selectionGroups: [PhotoGroup] {
        guard let units = recommendationUnits, !units.isEmpty,
              units.allSatisfy({ !$0.isEmpty }), units.flatMap({ $0 }).count == members.count,
              Set(units.flatMap({ $0 })) == Set(members) else { return [self] }
        return units.map { PhotoGroup(members: $0, kind: kind, needsReview: needsReview, samePersonConfirmed: samePersonConfirmed) }
    }
}
public struct Recommendation: Codable, Equatable {
    public var selected: Bool
    public var reason: String
    public var needsJudgment: Bool
}
public enum GroupMode: String, Codable { case scene, travel, exact, visualOnly }
public enum GroupingLevel: String, Codable, CaseIterable, Sendable {
    case precise, balanced, broad, widest
    public var label: String {
        switch self { case .precise: return "精细"; case .balanced: return "适中"; case .broad: return "宽松"; case .widest: return "最宽" }
    }
    public var distance: Float {
        switch self { case .precise: return 0.35; case .balanced: return 0.55; case .broad: return 0.75; case .widest: return 1 }
    }
}
public struct AnalysisSettings: Codable, Equatable {
    public var timeSpan: Double = 60
    public var distance: Float = 0.35
    public var recommendationCount: Int = 1
    public var mode: GroupMode = .scene
    /// nil preserves legacy grouping until the user selects a scene level.
    public var groupingLevel: GroupingLevel?
    public init() {}
}
public struct FolderAccess: Codable {
    public var path: String
    public var bookmark: Data
    public init(path: String, bookmark: Data) { self.path = path; self.bookmark = bookmark }
}
public struct AlbumReceipt: Codable {
    public var token: String
    public var albumIDs: [String]
    public var names: [String]
    public var importedIDs: [String: String]?
    public init(token: String, albumIDs: [String], names: [String], importedIDs: [String: String]? = nil) {
        self.token = token; self.albumIDs = albumIDs; self.names = names; self.importedIDs = importedIDs
    }
}
public struct AlbumOutputJournal: Codable {
    public var token: String
    public var importedIDs: [String: String]
    public init(token: String, importedIDs: [String: String] = [:]) { self.token = token; self.importedIDs = importedIDs }
    public func expectedIDs(_ sourceIDs: [String]) -> Set<String> {
        Set(sourceIDs.map { importedIDs[$0].map { "photos:" + $0 } ?? $0 })
    }
    public static func load(from url: URL?, token: String) throws -> AlbumOutputJournal {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return AlbumOutputJournal(token: token) }
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard result.token == token else { throw PhotoError.message("相册记录与本次选择不同，请先核对上次相册") }
        return result
    }
    public func save(to url: URL) throws { try JSONEncoder().encode(self).write(to: url, options: .atomic) }
}
public func stableID(_ value: String) -> String {
    let digits = Array("0123456789abcdef".utf8)
    return String(decoding: SHA256.hash(data: Data(value.utf8)).flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
}
public enum PhotoError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
