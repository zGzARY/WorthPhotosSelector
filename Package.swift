// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WorthPhotos",
    platforms: [.macOS("15.0")],
    products: [.library(name: "PhotoCore", targets: ["PhotoCore"]),
               .executable(name: "WorthPhotos", targets: ["TravelSelect"])],
    targets: [
        .target(name: "PhotoCore"),
        .executableTarget(name: "TravelSelect", dependencies: ["PhotoCore"]),
        .testTarget(name: "PhotoCoreTests", dependencies: ["PhotoCore"]),
        .testTarget(name: "TravelSelectTests", dependencies: ["TravelSelect", "PhotoCore"])
    ]
)
