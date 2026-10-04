import Foundation
import Vision
import CoreGraphics

public enum VisionAnalyzer {
    public static let analysisSize = 1600
    public static let version = "vision-fp2-aesthetics1-face3-srgb-fit1600-v1-current"
    public static func cacheKey(_ record: PhotoRecord) -> String { record.fingerprint + "|" + version }

    public static func normalized(_ image: CGImage) throws -> CGImage {
        let ratio = min(1, Double(analysisSize) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * ratio)), height = max(1, Int(Double(image.height) * ratio))
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PhotoError.message("无法建立分析图像")
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw PhotoError.message("无法转换图像颜色") }
        return result
    }
    public static func needsAnalysis(_ record: PhotoRecord, result: AnalysisResult?) -> Bool {
        guard let result, result.cacheKey == cacheKey(record), result.feature != nil else { return record.supported }
        let qualityDone = result.qualityComplete ?? (result.aesthetics != nil && [.success, .partial].contains(result.status) && !result.issues.contains { $0.contains("人脸拍摄质量不可用") })
        return !qualityDone
    }
    public static func analyze(_ image: CGImage, record: PhotoRecord, cached: AnalysisResult? = nil,
                               inputSignature: String? = nil, inputKind: String? = nil, permitsQuality: Bool = true,
                               onFeature: @Sendable (AnalysisResult) async -> Void = { _ in }) async -> AnalysisResult {
        let sameInput = inputSignature == nil || cached?.inputSignature == inputSignature
        var result = cached?.cacheKey == cacheKey(record) && sameInput ? cached! : AnalysisResult(cacheKey: cacheKey(record))
        result.inputSignature = inputSignature; result.inputKind = inputKind
        result.status = .running
        result.issues = []
        do {
            try Task.checkCancellation()
            let image = try normalized(image)
            result.pixelWidth = image.width; result.pixelHeight = image.height
            if max(image.width, image.height) < min(1000, max(record.width, record.height)) {
                result.issues.append("取得的预览小于所需尺寸，不足以判断精细细节")
            }
            if result.feature == nil { do {
                let request = VNGenerateImageFeaturePrintRequest()
                request.revision = VNGenerateImageFeaturePrintRequestRevision2
                request.imageCropAndScaleOption = .scaleFit
                try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
                guard let feature = request.results?.first else { throw PhotoError.message("未返回特征") }
                result.feature = try NSKeyedArchiver.archivedData(withRootObject: feature, requiringSecureCoding: true)
            } catch { result.issues.append("视觉特征不可用：\(error.localizedDescription)") } }
            await onFeature(result)
            try Task.checkCancellation()
            if !permitsQuality {
                result.aesthetics = nil; result.faces = []; result.qualityComplete = false
                result.status = result.feature == nil ? .failed : .partial
                result.issues = ["相机预览较小；查看本组时按需读取原片，补充细节评分"]
                return result
            }
            if result.aesthetics == nil { do {
                let observation = try await CalculateImageAestheticsScoresRequest(.revision1).perform(on: image, orientation: .up)
                result.aesthetics = observation.overallScore
                result.utility = observation.isUtility
            } catch { result.issues.append("整体美学不可用：\(error.localizedDescription)") } }
            try Task.checkCancellation()
            var faceCompleted = result.qualityComplete == true
            if !faceCompleted { do {
                let request = VNDetectFaceCaptureQualityRequest()
                request.revision = VNDetectFaceCaptureQualityRequestRevision3
                try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
                result.faces = (request.results ?? []).map { face in
                    FaceMeasure(x: face.boundingBox.minX, y: face.boundingBox.minY,
                                width: face.boundingBox.width, height: face.boundingBox.height,
                                quality: face.faceCaptureQuality)
                }
                faceCompleted = true
                if result.faces.contains(where: { $0.quality == nil }) { result.issues.append("部分人脸拍摄质量不可用") }
            } catch { result.issues.append("人脸拍摄质量不可用：\(error.localizedDescription)") } }
            result.qualityComplete = result.aesthetics != nil && faceCompleted
            result.issues += record.notes
            result.status = result.issues.isEmpty ? .success : .partial
            if result.feature == nil && result.aesthetics == nil { result.status = .failed }
        } catch is CancellationError { result.status = .cancelled; result.issues.append("分析已取消") }
        catch { result.status = .failed; result.issues.append(error.localizedDescription) }
        return result
    }
    public static func feature(_ data: Data) throws -> VNFeaturePrintObservation {
        guard let result = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data) else {
            throw PhotoError.message("特征缓存不能读取，请重新分析")
        }
        return result
    }
    public static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) throws -> Float {
        guard a.requestRevision == b.requestRevision, a.elementCount == b.elementCount else { throw PhotoError.message("特征版本不兼容，请重新分析") }
        var value: Float = 0; try a.computeDistance(&value, to: b); return value
    }
}
