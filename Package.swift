// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "EdgeeWidget",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "EdgeeWidget", targets: ["EdgeeWidget"]), .library(name: "EdgeeCore", targets: ["EdgeeCore"])],
    targets: [
        .target(name: "EdgeeCore"),
        .executableTarget(name: "EdgeeWidget", dependencies: ["EdgeeCore"], resources: [.process("Resources")]),
        .testTarget(name: "EdgeeCoreTests", dependencies: ["EdgeeCore"]),
        .testTarget(name: "EdgeeWidgetTests", dependencies: ["EdgeeWidget", "EdgeeCore"])
    ],
    swiftLanguageModes: [.v5]
)
