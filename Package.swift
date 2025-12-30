// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StageView",
    platforms: [.macOS(.v15), .iOS(.v18), .visionOS(.v2)],
    products: [
        .library(name: "StageViewCore", targets: ["StageViewCore"]),
        .library(name: "RealityKitStageView", targets: ["RealityKitStageView"]),
    ],
    dependencies: [
        // No TCA - keeping Core lightweight and framework-agnostic
    ],
    targets: [
        .target(
            name: "StageViewCore",
            dependencies: []  // Pure Swift + SwiftUI only
        ),
        .target(
            name: "RealityKitStageView",
            dependencies: ["StageViewCore"]
        ),
        .testTarget(
            name: "StageViewTests",
            dependencies: ["StageViewCore", "RealityKitStageView"]
        ),
    ]
)
