import Foundation
#if SWIFT_PACKAGE
import PhotoCore
#endif

struct CalibrationDraft: Identifiable {
    let id = UUID()
    let session: SelectionSession
    let groups: [PhotoGroup]
}
struct OutputDraft: Identifiable {
    let id = UUID()
    let session: SelectionSession
    let plan: SelectionPlan
    let defaultName: String
    var copyRequiredIDs: Set<String> = []
    var resume: ImportResumeSummary?
    var defaultDestination: OutputDestination { session.source == .folder ? .folder : .photos }
}
struct ImportResumeSummary {
    var recreateAlbum = false
    var completed: Int
    var added: [String]
    var removed: [String]
}
struct OutputResult: Identifiable {
    let id = UUID()
    let title: String
    let summary: String
    let names: [String]
    let folder: URL?
    let isPhotos: Bool
    var isComplete = true
}
struct ComparisonSelection: Identifiable {
    let id = UUID()
    let records: [PhotoRecord]
}
