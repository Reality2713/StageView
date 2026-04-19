# StageView

![StageView Preview](resources/Screenshot%202026-01-07%20at%2019.41.29.jpg)

A Swift package providing shared viewport abstractions for 3D rendering with **RealityKit**.

## Overview

**What is RealityKit?**

RealityKit is Apple's high-performance 3D rendering framework designed for AR and spatial computing experiences. It runs natively across iOS, iPadOS, macOS, and visionOS, providing:
- Real-time physically-based rendering (PBR)
- AR-specific features (anchoring, occlusion, plane detection)
- Entity-Component-System (ECS) architecture
- Tight integration with SwiftUI and Reality Composer Pro

**About This Package**

StageView provides a unified protocol and shared viewport components that RealityKit-based renderers can use for consistent 3D scene presentation. It abstracts common viewport features like grids, IBL lighting, and scale indicators into reusable components.

## Features

- **Unified Protocol**: `StageViewport` protocol for consistent viewport interface
- **Dynamic Grid**: Scale-aware grid that extends based on scene size (1 meter = 1 meter always)
- **IBL Support**: Environment lighting with EV-style exposure control
- **Scale Indicator**: Auto-switching scale reference (cm/m/km) based on scene size
- **Colored Axes**: Visual axis indicators (X=red, Y=green, Z=blue)
- **Selection Remapping Hooks**: Upgrade coarse imported pick results to semantic scene paths

## Modules

### StageViewCore

Core types and protocols with no heavy dependencies:

- `StageViewProtocol` - Common viewport interface
- `GridConfiguration` - Grid settings with scale unit support
- `IBLConfiguration` - Environment lighting with EV-style exposure
- `SceneBounds` - Scene bounds representation
- `ScaleIndicatorView` - SwiftUI view for scale reference

### RealityKitStageView

RealityKit implementation:

- `RealityKitGrid` - Dynamic grid with metersPerUnit support
- `RealityKitIBL` - IBL handling with proper exposure conversion
- `RealityKitStageView` - Full viewport view

## Why RealityKit?

**When to Use This Package:**
- Building AR experiences on Apple platforms
- Need tight SwiftUI integration
- Want Apple-native performance and features
- Working with Reality Composer Pro content

**When to Consider Hydra Instead:**
- Need high-fidelity OpenUSD rendering
- Require viewport features like Storm/HdRpr renderers
- Working with complex USD pipelines from DCC tools
- Need pixel-accurate USD preview

## Hydra Rendering (Alternative)

For **OpenUSD rendering with Hydra**, see the companion package: [**StageViewHydra**](https://github.com/reality2713/StageViewHydra)

Hydra is Pixar's rendering architecture from OpenUSD that provides production-quality viewport rendering. StageViewHydra implements the same viewport protocols using Hydra instead of RealityKit, enabling pixel-accurate USD preview but with a heavier dependency stack (SwiftUsd + OpenUSD).

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/reality2713/StageView.git", branch: "main"),
]
```

Then add the products to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "StageViewCore", package: "StageView"),
        .product(name: "RealityKitStageView", package: "StageView"),
    ]
),
```

## Usage

### Using the Grid

```swift
import RealityKitStageView

let grid = RealityKitGrid.createGridEntity(
    metersPerUnit: 0.01,  // Scene in centimeters
    worldExtent: 10.0,    // Scene size
    isZUp: false          // Y-up coordinate system
)
```

### Using the Scale Indicator

```swift
import StageViewCore

ScaleIndicatorView(
    sceneBounds: myBounds,
    metersPerUnit: 0.01
)
```

### IBL Configuration

```swift
import StageViewCore

var config = IBLConfiguration()
config.exposure = 0.0  // EV-style: 0 = neutral, +1 = 2x brighter, -1 = 2x darker
config.showBackground = true

// For RealityKit, convert to intensityExponent
let exponent = config.realityKitIntensityExponent
```

### Upgrading Picked Paths

If RealityKit collapses imported geometry into generic entities such as
`merged_1`, consumers can provide stronger scene-aware remapping:

```swift
import RealityKitStageView

let provider = RealityKitProvider()

provider.setPickPathOverrides([
    "/RootNode/merged_1": "/RootNode/Forklift"
])

provider.setPickPathResolver { directPath, entity, provider in
    guard directPath == "/RootNode/merged_1" else { return nil }
    return "/RootNode/Forklift/Body"
}
```

`StageView` applies consumer overrides first, then its built-in generic merged
node fallback, then the direct imported mapping.

### Prim-to-Entity Mapping

For the full mapping model used by `RealityKitStageView`, including:

- duplicate `_1` / `_2` suffix handling
- generic importer bucket names such as `merged_1`
- the distinction between direct mapping, selection mapping, and pick mapping
- why visibility projection must be more conservative than selection

see:

- [RealityKit Prim-Entity Mapping](resources/REALITYKIT_PRIM_ENTITY_MAPPING.md)

## Requirements

- **macOS 15.0+**
- **iOS 18.0+**
- **iPadOS 18.0+**
- **visionOS 2.0+**
- **Swift 6.0+**

## Related Projects

- [**StageViewHydra**](https://github.com/reality2713/StageViewHydra) - Hydra/OpenUSD viewport implementation
- [**RealityKit**](https://developer.apple.com/documentation/realitykit) - Apple's 3D rendering framework
- [**Reality Composer Pro**](https://developer.apple.com/augmented-reality/tools/) - Apple's USD authoring tool

## License

MIT License
