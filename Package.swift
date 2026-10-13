// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StageView",
    platforms: [.macOS(.v15), .iOS(.v18), .visionOS(.v2)],
    products: [
        .library(name: "StageViewOverlay", targets: ["StageViewOverlay"]),
        .library(name: "RealityKitStageView", targets: ["RealityKitStageView"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.25.3"),
        .package(url: "https://github.com/elkraneo/PostProcessOutline.git", from: "1.1.3"),
        .package(url: "https://github.com/elkraneo/SelectionEffects.git", from: "0.2.1"),
    ],
    targets: [
        .target(
            name: "StageViewOverlay",
            dependencies: []
        ),
        .target(
            name: "RealityKitStageView",
            dependencies: [
                "StageViewOverlay",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "PostProcessOutline", package: "PostProcessOutline"),
                .product(name: "SelectionEffects", package: "SelectionEffects"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "StageViewOverlayTests",
            dependencies: ["StageViewOverlay"]
        ),
        .testTarget(
            name: "StageViewTests",
            dependencies: ["RealityKitStageView", "StageViewOverlay"]
        ),
    ]
)
