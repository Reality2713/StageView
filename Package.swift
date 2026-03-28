// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StageView",
    platforms: [.macOS(.v15), .iOS(.v18), .visionOS(.v2)],
    products: [
        .library(name: "RealityKitStageView", targets: ["RealityKitStageView"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.25.3"),
    ],
    targets: [
        .target(
            name: "RealityKitStageView",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "StageViewTests",
            dependencies: ["RealityKitStageView"]
        ),
    ]
)
