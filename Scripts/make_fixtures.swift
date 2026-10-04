// Synthetic fixtures for local UI verification; never used by the app at runtime.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
func write(_ name: String, dated: Bool, variation: Bool = false) throws {
    let width = 1200, height = 800
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(red: 0.35, green: 0.6, blue: 0.85, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
    c.setFillColor(CGColor(red: 0.95, green: 0.8, blue: 0.25, alpha: 1)); c.fillEllipse(in: CGRect(x: variation ? 820 : 800, y: 500, width: 150, height: 150))
    c.setFillColor(CGColor(red: 0.2, green: 0.35, blue: 0.25, alpha: 1)); c.move(to: CGPoint(x: 0, y: 0)); c.addLine(to: CGPoint(x: 380, y: 480)); c.addLine(to: CGPoint(x: 750, y: 0)); c.fillPath()
    c.setFillColor(CGColor(red: 0.25, green: 0.45, blue: 0.32, alpha: 1)); c.move(to: CGPoint(x: 480, y: 0)); c.addLine(to: CGPoint(x: 850, y: 400)); c.addLine(to: CGPoint(x: 1200, y: 0)); c.fillPath()
    let dest = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    if dated { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:10:01 12:00:00", kCGImagePropertyExifOffsetTimeOriginal: "+08:00"] }
    CGImageDestinationAddImage(dest, c.makeImage()!, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("fixture write failed") }
}
try write("01-synthetic.jpg", dated: true)
let copy = root.appendingPathComponent("02-byte-copy.jpg")
if !FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.copyItem(at: root.appendingPathComponent("01-synthetic.jpg"), to: copy) }
try write("03-variation.jpg", dated: true, variation: true)
try write("04-no-time.jpg", dated: false)
try Data("Deliberately invalid image for error-state verification.".utf8).write(to: root.appendingPathComponent("05-corrupt.jpg"))
try Data("Unsupported non-image file; must remain visible.".utf8).write(to: root.appendingPathComponent("06-unsupported.txt"))
print("Created 6 synthetic fixtures; no personal photos used.")
