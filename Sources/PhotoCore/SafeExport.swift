import Foundation

public struct ExportItem: Codable {
    public var id: String
    public var destination: String?
    public var state: String
    public var message: String?
}
public struct ExportReport: Codable {
    public var items: [ExportItem]
    public var cancelled: Bool
    public var manifestSaved: Bool
    public var errors: [String]
    public var copiedCount: Int { items.filter { $0.state == "copied" }.count }
}
public enum SafeExport {
    public static func copy(session: SelectionSession, destination: URL, plan: SelectionPlan? = nil, includeUnselected: Bool = false, cancelled: () -> Bool = { false }) -> ExportReport {
        var report = ExportReport(items: [], cancelled: false, manifestSaved: false, errors: [])
        var createdDestination = false
        let fm = FileManager.default
        do {
            guard !destination.resolvingSymlinksInPath().pathComponents.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) else {
                throw PhotoError.message("不能把结果写入 Photos 资料库包；请选择普通文件夹。")
            }
            if let plan {
                guard plan.permitsOutput, plan.scopeKey == session.scopeKey else { throw PhotoError.message("照片范围或分析结果已改变，请重新查看精选清单。") }
            }
            // A dedicated new directory gives clear ownership and makes retries non-destructive.
            guard !fm.fileExists(atPath: destination.path) else { throw PhotoError.message("输出目录已存在；请选择新的目录名称，避免覆盖。") }
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            createdDestination = true
            try Data("择影导出；扫描时跳过此目录".utf8).write(to: destination.appendingPathComponent(".travel-select-output"), options: .withoutOverwriting)
            let keep = Set(plan?.keepIDs ?? session.outputIDs(.keep))
            let unselected = includeUnselected ? Set(plan?.unselectedIDs ?? session.outputIDs(.exclude)) : []
            let ids = keep.union(unselected)
            let expected = Dictionary(uniqueKeysWithValues: (plan?.entries ?? []).map { ($0.id, $0.fingerprint) })
            if plan != nil {
                for name in ["精选"] + (unselected.isEmpty ? [] : ["待整理"]) {
                    try fm.createDirectory(at: destination.appendingPathComponent(name), withIntermediateDirectories: false)
                }
            }
            for record in session.records where ids.contains(record.id) && record.source == .folder {
                if cancelled() {
                    report.cancelled = true
                    report.items.append(ExportItem(id: record.id, state: "cancelled", message: "尚未复制")); continue
                }
                var staging: URL?
                do {
                    if let fingerprint = expected[record.id], fingerprint != record.fingerprint { throw PhotoError.message("照片信息已变化，请重新查看清单") }
                    let folder = plan == nil ? destination : destination.appendingPathComponent(keep.contains(record.id) ? "精选" : "待整理")
                    let source = URL(fileURLWithPath: record.locator)
                    guard try FolderSource.inspect(source).fingerprint == record.fingerprint else { throw PhotoError.message("来源已更改，请重新分析并复核") }
                    let ext = source.pathExtension, stem = source.deletingPathExtension().lastPathComponent
                    var target = folder.appendingPathComponent(record.name)
                    var suffix = 2
                    while fm.fileExists(atPath: target.path) {
                        target = folder.appendingPathComponent("\(stem)-\(suffix)" + (ext.isEmpty ? "" : ".\(ext)")); suffix += 1
                    }
                    let temp = folder.appendingPathComponent(".partial-" + UUID().uuidString)
                    staging = temp
                    let before = try FolderSource.sha256(source, cancelled: cancelled)
                    try fm.copyItem(at: source, to: temp)
                    if cancelled() { throw CancellationError() }
                    guard try FolderSource.sha256(temp, cancelled: cancelled) == before,
                          try FolderSource.sha256(source, cancelled: cancelled) == before else { throw PhotoError.message("来源在复制期间改变或副本校验失败") }
                    try fm.moveItem(at: temp, to: target); staging = nil
                    report.items.append(ExportItem(id: record.id, destination: String(target.path.dropFirst(destination.path.count + 1)), state: "copied"))
                } catch {
                    if let staging { try? fm.removeItem(at: staging) }
                    let stopped = error is CancellationError
                    report.cancelled = report.cancelled || stopped
                    report.items.append(ExportItem(id: record.id, state: stopped ? "cancelled" : "failed", message: stopped ? "已取消" : error.localizedDescription))
                }
            }
            // Keep unreviewed/failed records in the local manifest; never expose feature vectors there.
            var manifest = session.exportSnapshot()
            for id in manifest.analyses.keys { manifest.analyses[id]?.feature = nil }
            try SessionStore.save(manifest, to: destination.appendingPathComponent("选择清单.json"))
            if let plan {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(plan).write(to: destination.appendingPathComponent("精选与待整理.json"), options: .withoutOverwriting)
            }
            report.manifestSaved = true
        } catch { report.errors.append(error.localizedDescription) }
        guard createdDestination else { return report }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: destination.appendingPathComponent("复制结果.json"), options: .withoutOverwriting)
        } catch { report.errors.append("复制结果记录未能保存：\(error.localizedDescription)") }
        return report
    }
}
