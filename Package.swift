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
            ],
            resources: [
                .process("Resources"),
                .process("SelectionOutline/Shaders"),
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
