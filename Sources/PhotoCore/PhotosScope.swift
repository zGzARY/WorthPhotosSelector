import Foundation

/// Dates are absolute instants, with an exclusive upper bound. The timezone is
/// retained so reopening a range does not reinterpret its calendar days.
public struct PhotosScope: Codable, Equatable, Hashable {
    public var albumID: String?
    public var albumTitle: String?
    public var startDate: Date?
    public var endDateExclusive: Date?
    public var timeZoneIdentifier: String

    public init(albumID: String? = nil, albumTitle: String? = nil,
                startDate: Date? = nil, endDateExclusive: Date? = nil,
                timeZoneIdentifier: String = TimeZone.current.identifier) throws {
        self.albumID = albumID; self.albumTitle = albumTitle
        self.startDate = startDate; self.endDateExclusive = endDateExclusive
        self.timeZoneIdentifier = timeZoneIdentifier
        try validate()
    }
    public func validate() throws {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw PhotoError.message("日期时区无效") }
        guard albumID != "" else { throw PhotoError.message("请选择相册") }
        guard (startDate == nil) == (endDateExclusive == nil) else { throw PhotoError.message("请同时选择开始和结束日期") }
        if let startDate, let endDateExclusive, startDate >= endDateExclusive { throw PhotoError.message("结束日期不能早于开始日期") }
    }
    public static func days(albumID: String? = nil, albumTitle: String? = nil,
                            from: Date, through: Date, timeZone: TimeZone = .current) throws -> PhotosScope {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: from)
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: through)) else { throw PhotoError.message("日期范围无效") }
        return try PhotosScope(albumID: albumID, albumTitle: albumTitle, startDate: start,
                               endDateExclusive: end, timeZoneIdentifier: timeZone.identifier)
    }
    public func contains(_ date: Date?) -> Bool {
        guard let startDate, let endDateExclusive else { return true }
        guard let date else { return false }
        return date >= startDate && date < endDateExclusive
    }
    public var title: String {
        let source = albumID == nil ? "系统图库" : (albumTitle ?? "所选相册")
        guard let startDate, let endDateExclusive else { return source + " · 不限日期" }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        return source + " · " + formatter.string(from: startDate) + " – " + formatter.string(from: endDateExclusive.addingTimeInterval(-1))
    }
}
