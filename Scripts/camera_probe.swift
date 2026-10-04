// Read-only hardware acceptance probe. No Photos writes or camera mutations.
// --full-sample additionally stages one original asset, decodes it, then removes
// only that app-owned temporary copy. Source originals are never modified.
import Foundation
import AppKit
import PhotoCore

@main
struct CameraProbe {
    @MainActor static func main() {
        _ = NSApplication.shared
        let camera = CameraSource.shared
        var finished = false, succeeded = false
        camera.discover()
        let task = Task { @MainActor in
            do {
                var opened = false
                for tick in 0..<180 {
                    try await Task.sleep(for: .seconds(1))
                    if !opened, let device = camera.devices.first {
                        print("DEVICE \(device.name)")
                        try camera.open(device); opened = true
                    }
                    if tick % 10 == 0 { print("STATUS \(camera.status)") }
                    if camera.catalogComplete { break }
                }
                guard camera.catalogComplete else { throw PhotoError.message("目录未完成：" + camera.status) }
                let rawPairs = camera.records.filter { ($0.external?.resources.count ?? 0) > 1 }.count
                let rawSingles = camera.records.filter { $0.external?.resources.count == 1 && $0.external?.resources.first?.isRaw == true }.count
                print("CATALOG logical=\(camera.records.count) rawPairs=\(rawPairs) rawSingles=\(rawSingles)")
                guard let candidate = camera.records.last(where: { $0.external?.displayResource?.isRaw != true }) else { throw PhotoError.message("没有可检查的静态照片") }
                let record = try await camera.prepareForAnalysis(candidate)
                print("METADATA name=\(record.name) date=\(record.captureDate?.description ?? "missing") note=\(record.timeNote ?? "")")
                let image = try await camera.image(record, maxPixel: 1600, allowOriginal: false)
                print("PREVIEW \(image.image.width)x\(image.image.height) quality=\(image.permitsQuality) original=\(record.width)x\(record.height) resourceCount=\(record.external?.resources.count ?? 0)")
                if CommandLine.arguments.contains("--full-sample") {
                    let original = try await camera.materialize(record)
                    defer { original.cleanup() }
                    for (index, file) in original.files.enumerated() {
                        print("ORIGINAL raw=\(original.resources[index].isRaw) bytes=\(original.resources[index].byteSize) sha256=\(try FolderSource.sha256(file))")
                    }
                }
                print("PROBE PASSED")
                succeeded = true
            } catch { print("PROBE FAILED \(error.localizedDescription)") }
            finished = true
        }
        while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        task.cancel(); camera.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        if !succeeded { exit(1) }
    }
}
