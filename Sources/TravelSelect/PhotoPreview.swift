import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import PhotoCore
#endif

final class PreviewCache: @unchecked Sendable {
    static let shared = PreviewCache()
    let cache = NSCache<NSString, NSImage>()
    init() { cache.totalCostLimit = 96 * 1024 * 1024; cache.countLimit = 120 }
    func image(_ r: PhotoRecord, size: Int, allowNetwork: Bool = false) async throws -> NSImage {
        let key = "\(r.fingerprint)|\(size)|\(allowNetwork)" as NSString
        if let value = cache.object(forKey: key) { return value }
        let request = Task.detached {
            try await PhotoSource.image(r, maxPixel: size, allowNetwork: allowNetwork, allowOriginal: size > VisionAnalyzer.analysisSize).image
        }
        let cg = try await withTaskCancellationHandler { try await request.value } onCancel: { request.cancel() }
        try Task.checkCancellation()
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key, cost: cg.width * cg.height * 4)
        return image
    }
}
struct PhotoThumbnail: View {
    var record: PhotoRecord
    var allowNetwork = false
    @State private var image: NSImage?
    @State private var error: String?
    @ObservedObject private var camera = CameraSource.shared
    var body: some View {
        ZStack {
            Color.black.opacity(0.05)
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if error != nil { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
        }.task(id: record.fingerprint + String(allowNetwork) + (record.source == .camera ? String(camera.catalogComplete) : "")) {
            image = nil; error = nil
            do { image = try await PreviewCache.shared.image(record, size: 440, allowNetwork: allowNetwork) }
            catch { self.error = error.localizedDescription }
        }.onDisappear { image = nil }
    }
}
struct ZoomImage: View {
    let image: NSImage
    var zoom: Double
    @State private var offset = CGSize.zero
    @State private var origin = CGSize.zero
    @State private var pinch = 1.0
    @GestureState private var gestureScale = 1.0
    var body: some View {
        GeometryReader { geometry in
            Image(nsImage: image).resizable().scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(min(12, max(0.5, zoom * pinch * gestureScale)))
                .offset(offset)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(.black).clipped().contentShape(Rectangle())
                .gesture(DragGesture().onChanged { value in
                    offset = CGSize(width: origin.width + value.translation.width, height: origin.height + value.translation.height)
                }.onEnded { _ in origin = offset })
                .simultaneousGesture(MagnifyGesture().updating($gestureScale) { value, state, _ in state = value.magnification }
                    .onEnded { value in pinch = min(8, max(0.5, pinch * value.magnification)) })
        }
    }
}
struct ComparisonPane: View {
    var record: PhotoRecord
    var analysis: AnalysisResult?
    var recommendation: Recommendation?
    var allowNetwork: Bool
    var imageHeight: CGFloat
    var maxPixel: Int
    var allowDetails: Bool
    @State private var detailsExpanded: Bool
    @State private var image: NSImage?
    @State private var error: String?
    @State private var zoom = 1.0
    @State private var pixelSize = ""
    @State private var reset = UUID()
    @ObservedObject private var camera = CameraSource.shared
    init(record: PhotoRecord, analysis: AnalysisResult?, recommendation: Recommendation? = nil,
         allowNetwork: Bool = false, imageHeight: CGFloat = 300, maxPixel: Int = 1600,
         allowDetails: Bool = true, detailsInitiallyExpanded: Bool = false) {
        self.record = record; self.analysis = analysis; self.recommendation = recommendation
        self.allowNetwork = allowNetwork; self.imageHeight = imageHeight; self.maxPixel = maxPixel; self.allowDetails = allowDetails
        _detailsExpanded = State(initialValue: detailsInitiallyExpanded)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(record.name).font(.headline).lineLimit(1)
                Spacer()
                if recommendation?.selected == true && allowDetails { Image(systemName: "sparkles").foregroundStyle(.tint) }
            }.frame(height: 24)
            if let image { ZoomImage(image: image, zoom: zoom).id(reset).frame(height: imageHeight).clipShape(RoundedRectangle(cornerRadius: 10)) }
            else { ContentUnavailableView(error ?? "正在读取照片…", systemImage: "photo").frame(height: imageHeight) }
            HStack(spacing: 12) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $zoom, in: 0.5...8).accessibilityLabel("\(record.name) 缩放")
                Button("适合窗口") { zoom = 1; reset = UUID() }.controlSize(.small)
            }
            if allowDetails {
                if let reason = recommendation?.reason { Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                DisclosureGroup("拍摄与评分详情", isExpanded: $detailsExpanded) {
                    if detailsExpanded { details.padding(.top, 8) }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.task(id: record.fingerprint + String(allowNetwork) + String(maxPixel) + (record.source == .camera ? String(camera.catalogComplete) : "")) {
            image = nil; error = nil; zoom = 1; reset = UUID()
            do {
                let value = try await PreviewCache.shared.image(record, size: maxPixel, allowNetwork: allowNetwork)
                image = value; pixelSize = "\(Int(value.size.width)) × \(Int(value.size.height))"
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("来源 \(record.width) × \(record.height) · " + (record.captureDate?.formatted() ?? "拍摄时间未知"))
            Text("当前预览 \(pixelSize)；放大预览不等于原片 100% 细节")
            if let note = record.timeNote { Text(note) }
            if let a = analysis {
                Text("整体画面：" + (a.aesthetics.map { String(format: "%.3f（原始范围 −1…1）", $0) } ?? "尚不可用"))
                if !a.faces.isEmpty, let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(Array(a.faces.enumerated()), id: \.offset) { _, face in
                                let rect = CGRect(x: face.x * Double(cg.width), y: (1 - face.y - face.height) * Double(cg.height), width: face.width * Double(cg.width), height: face.height * Double(cg.height)).integral
                                if let crop = cg.cropping(to: rect) {
                                    VStack(spacing: 5) {
                                        Image(decorative: crop, scale: 1).resizable().scaledToFit().frame(width: 90, height: 90).clipShape(RoundedRectangle(cornerRadius: 6))
                                        Text(face.quality.map { String(format: "人脸拍摄质量 %.3f", $0) } ?? "指标不可用").font(.caption2)
                                    }
                                }
                            }
                        }
                    }
                }
                Text("人脸拍摄质量仅用于同一主体的相对比较；没有单独判断闭眼或笑容。")
                ForEach(a.issues, id: \.self) { Text($0).foregroundStyle(.orange) }
            }
            ForEach(record.notes, id: \.self) { Text($0) }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }
}

enum ComparisonLayout {
    static func columnCount(count: Int, width: CGFloat) -> Int {
        if count <= 1 { return 1 }
        if count == 2 || count == 4 { return 2 }
        return width >= 960 ? 3 : 2
    }
}
struct ComparisonView: View {
    let records: [PhotoRecord]
    let analyses: [String: AnalysisResult]
    let recommendations: [String: Recommendation]
    let allowNetwork: Bool
    var allowDetails = true
    @Environment(\.dismiss) private var dismiss
    @State private var focused: PhotoRecord?
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(focused == nil ? (records.count == 1 ? "查看照片" : "比较 \(records.count) 张照片") : "放大查看").font(.title2.weight(.semibold))
                    Text("拖动平移，捏合或滑动缩放 · 双击照片放大").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if focused != nil { Button("返回多图") { focused = nil } }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            GeometryReader { geometry in
                ScrollView {
                    let displayed = focused.map { [$0] } ?? records
                    let columns = ComparisonLayout.columnCount(count: displayed.count, width: geometry.size.width)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: columns), alignment: .leading, spacing: 26) {
                        ForEach(displayed) { record in
                            ComparisonPane(record: record, analysis: analyses[record.id], recommendation: recommendations[record.id],
                                           allowNetwork: allowNetwork, imageHeight: displayed.count <= 3 ? max(330, geometry.size.height - 145) : 290,
                                           maxPixel: displayed.count == 1 ? 3000 : 1600, allowDetails: allowDetails)
                                .simultaneousGesture(TapGesture(count: 2).onEnded { focused = focused == nil ? record : nil })
                        }
                    }.padding(2)
                }
            }
        }.padding(24).frame(minWidth: 1040, idealWidth: 1240, minHeight: 680, idealHeight: 800)
    }
}
