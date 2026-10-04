import Foundation
import Vision

/// One fixed complete-link tree serves all four levels. Cutting the same tree
/// guarantees nested groups; changing a level never requests another image.
public struct SceneHierarchy: Sendable {
    struct Node: Sendable {
        var members: [String]
        var children: [Int]
        var distance: Float
        var first: Int
    }
    var nodes: [Node]
    var roots: [Int]
    public func groups(level: GroupingLevel) -> [PhotoGroup] {
        func cut(_ index: Int, threshold: Float) -> [Int] {
            let node = nodes[index]
            if node.children.isEmpty || node.distance <= threshold { return [index] }
            return node.children.flatMap { cut($0, threshold: threshold) }
        }
        return roots.flatMap { cut($0, threshold: level.distance) }.sorted { nodes[$0].first < nodes[$1].first }.map { index in
            let node = nodes[index]
            var group = PhotoGroup(members: node.members, kind: node.members.count > 1 ? .similar : .single)
            group.recommendationUnits = cut(index, threshold: GroupingLevel.precise.distance).map { nodes[$0].members }
            return group
        }
    }
    public static func build(records: [PhotoRecord], eligible: Set<String>, useTime: Bool = true,
                             cancelled: () -> Bool = { false },
                             distance: (String, String) throws -> Float) throws -> SceneHierarchy {
        let records = Grouping.ordered(records).filter { eligible.contains($0.id) }
        var partitions: [[Int]] = [], unknown: [Int] = []
        for index in records.indices {
            if cancelled() { throw CancellationError() }
            guard useTime, let date = records[index].captureDate else { unknown.append(index); continue }
            if let last = partitions.last?.last, let previous = records[last].captureDate,
               date.timeIntervalSince(previous) <= 60,
               (records[last].timeNote?.contains("未含时区") == true) == (records[index].timeNote?.contains("未含时区") == true) {
                partitions[partitions.count - 1].append(index)
            } else { partitions.append([index]) }
        }
        if !unknown.isEmpty { partitions.append(unknown) }
        var nodes = records.enumerated().map { Node(members: [$0.element.id], children: [], distance: 0, first: $0.offset) }
        var roots: [Int] = []
        for partition in partitions {
            var active = Set(partition), distances: [UInt64: Float] = [:], heap = MergeHeap()
            func key(_ a: Int, _ b: Int) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }
            for (offset, a) in partition.enumerated() {
                if cancelled() { throw CancellationError() }
                for b in partition.dropFirst(offset + 1) {
                    let d = try distance(records[a].id, records[b].id)
                    guard d.isFinite, d >= 0 else { throw PhotoError.message("视觉特征距离无效，请重新分析相关照片") }
                    distances[key(a, b)] = d
                    if d <= GroupingLevel.widest.distance { heap.push(MergeEdge(a: a, b: b, distance: d)) }
                }
            }
            while let edge = heap.pop() {
                if cancelled() { throw CancellationError() }
                guard active.contains(edge.a), active.contains(edge.b) else { continue }
                let a = edge.a, b = edge.b, merged = nodes.count
                let children = [a, b].sorted { nodes[$0].first < nodes[$1].first }
                nodes.append(Node(members: children.flatMap { nodes[$0].members }, children: children,
                                  distance: edge.distance, first: min(nodes[a].first, nodes[b].first)))
                active.remove(a); active.remove(b)
                for other in active.sorted() {
                    let value = max(distances[key(a, other)]!, distances[key(b, other)]!)
                    distances[key(merged, other)] = value
                    if value <= GroupingLevel.widest.distance { heap.push(MergeEdge(a: other, b: merged, distance: value)) }
                    distances[key(a, other)] = nil; distances[key(b, other)] = nil
                }
                distances[key(a, b)] = nil
                active.insert(merged)
            }
            roots += active.sorted { nodes[$0].first < nodes[$1].first }
        }
        return SceneHierarchy(nodes: nodes, roots: roots.sorted { nodes[$0].first < nodes[$1].first })
    }
    public static func make(session: SelectionSession, cancelled: () -> Bool = { false }) throws -> SceneHierarchy {
        var features: [String: VNFeaturePrintObservation] = [:]
        for record in session.activeRecords {
            if cancelled() { throw CancellationError() }
            guard session.hasFeature(record), let data = session.analyses[record.id]?.feature,
                  let feature = try? VisionAnalyzer.feature(data) else { continue }
            features[record.id] = feature
        }
        return try build(records: session.activeRecords, eligible: Set(features.keys), useTime: session.settings.mode != .visualOnly,
                         cancelled: cancelled) { try VisionAnalyzer.distance(features[$0]!, features[$1]!) }
    }
}

private struct MergeEdge: Comparable {
    var a: Int
    var b: Int
    var distance: Float
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
        if lhs.a != rhs.a { return lhs.a < rhs.a }
        return lhs.b < rhs.b
    }
}
private struct MergeHeap {
    var values: [MergeEdge] = []
    mutating func push(_ edge: MergeEdge) {
        values.append(edge)
        var i = values.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if !(values[i] < values[parent]) { break }
            values.swapAt(i, parent); i = parent
        }
    }
    mutating func pop() -> MergeEdge? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast() }
        let result = values[0]; values[0] = values.removeLast()
        var i = 0
        while i * 2 + 1 < values.count {
            var child = i * 2 + 1
            if child + 1 < values.count && values[child + 1] < values[child] { child += 1 }
            if !(values[child] < values[i]) { break }
            values.swapAt(i, child); i = child
        }
        return result
    }
}
