// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StageView",
    platforms: [.macOS(.v26), .iOS(.v18), .visionOS(.v2)],
    products: [
        .library(name: "RealityKitStageView", targets: ["RealityKitStageView"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.23.1"),
    ],
    targets: [
        .target(
            name: "RealityKitStageView",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            exclude: ["SelectionOutline/Shaders/OutlineShaders.metal"]
        ),
        .testTarget(
            name: "StageViewTests",
            dependencies: ["RealityKitStageView"]
        ),
    ]
)
