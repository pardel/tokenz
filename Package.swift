// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tokenz",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tokenz", targets: ["Tokenz"]),
        // For Tokenz.xcodeproj (project.yml), whose app target links it.
        .library(name: "UsageCore", targets: ["UsageCore"])
    ],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "Tokenz", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"])
    ],
    swiftLanguageModes: [.v5]
)
