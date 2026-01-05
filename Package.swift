// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StageView",
    platforms: [.macOS(.v15), .iOS(.v18), .visionOS(.v2)],
    products: [
        .library(name: "RealityKitStageView", targets: ["RealityKitStageView"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "RealityKitStageView",
            dependencies: []
        ),
    ]
)
