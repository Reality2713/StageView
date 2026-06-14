# StageView

![StageView Preview](resources/Screenshot%202026-01-07%20at%2019.41.29.jpg)

A Swift package for Apple-native 3D viewport UI built on **RealityKit**.

## Overview

**What is RealityKit?**

RealityKit is Apple's high-performance 3D rendering framework designed for AR and spatial computing experiences. It runs natively across iOS, iPadOS, macOS, and visionOS, providing:
- Real-time physically-based rendering (PBR)
- AR-specific features (anchoring, occlusion, plane detection)
- Entity-Component-System (ECS) architecture
- Tight integration with SwiftUI and Reality Composer Pro

**About This Package**

StageView provides the RealityKit implementation and shared overlay layer used by RealityKit-based stage viewers. It owns viewport-specific affordances such as procedural grids, overlays, IBL controls, scale indicators, and RealityKit pick remapping.

OpenUSD inspection, editing, validation, and material semantics belong in OpenUSDKit and SwiftUsdShell. StageView stays focused on the viewport experience and can be used without linking the OpenUSDKit product surface.

## Features

- **Dynamic Grid**: Scale-aware grid that extends based on scene size (1 meter = 1 meter always)
- **Viewport Material Assets**: Shader graph recipes for RealityKit viewport affordances such as the generated grid material
- **IBL Support**: Environment lighting with EV-style exposure control
- **Scale Indicator**: Auto-switching scale reference (cm/m/km) based on scene size
- **Colored Axes**: Visual axis indicators (X=red, Y=green, Z=blue)
- **Selection Remapping Hooks**: Upgrade coarse imported pick results to semantic scene paths

## Modules

### StageViewOverlay

Shared SwiftUI overlay primitives with no RealityKit dependency:

- `ViewportOverlayCollection` - Anchored overlay items for viewport chrome
- `ScaleIndicatorView` - SwiftUI scale reference
- `OrientationGizmoView` - Camera-aware orientation indicator
- `StageViewOverlayContext` - Shared overlay context passed to built-in and custom overlay views

### RealityKitStageView

RealityKit implementation:

- `RealityKitStageView` - Full RealityKit viewport view
- `RealityKitProvider` - Observable runtime owner for loaded entities, camera state, and selection
- `RealityKitGrid` - Dynamic grid with metersPerUnit support
- `RealityKitIBL` - IBL handling with proper exposure conversion
- `ViewportGridMaterialSpec` / `ViewportGridMaterialAssetRecipe` - Generated USDA shader graph assets for the RealityKit viewport grid

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

Hydra is Pixar's rendering architecture from OpenUSD that provides production-quality viewport rendering. StageViewHydra owns the Hydra viewport, including viewport reload preparation for Hydra-compatible USD stages. It has a heavier dependency stack (SwiftUsd, SwiftUsdShell, and OpenUSD), while StageView stays lightweight for RealityKit use cases.

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Reality2713/StageView.git", from: "0.3.27"),
]
```

Then add the products to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "StageViewOverlay", package: "StageView"),
        .product(name: "RealityKitStageView", package: "StageView"),
    ]
),
```

## Usage

### Using the Grid

```swift
import RealityKitStageView

let grid = await RealityKitGrid.createProceduralGridEntity(
    metersPerUnit: 0.01,  // Scene in centimeters
    worldExtent: 10.0,    // Scene size
    isZUp: false,         // Y-up coordinate system
    appearance: .dark
)
```

### Generating the Grid Material Asset

```swift
import RealityKitStageView

let spec = ViewportGridMaterialSpec(theme: .dark)
let asset = try ViewportGridMaterialAssetRecipe().makeAsset(from: spec)

try asset.contents.write(to: outputURL, atomically: true, encoding: .utf8)
```

The generated asset is a viewport concern. It intentionally lives in StageView rather than OpenUSDKit because it describes RealityKit viewport chrome, not reusable USD material authoring semantics.

### Using the Scale Indicator

```swift
import StageViewOverlay

ScaleIndicatorView(
    referenceDepthMeters: 2.0,
    viewportWidthPoints: 900
)
```

### IBL Configuration

```swift
import RealityKitStageView

var configuration = RealityKitConfiguration()
configuration.environmentMapURL = URL(fileURLWithPath: "/path/to/studio.hdr")
configuration.environmentExposure = 0.0 // EV-style: 0 = neutral
configuration.showEnvironmentBackground = true
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

### Adopting StageView as an entity-source viewport

`RealityKitStageView` can render an externally-built entity hierarchy without
loading from a URL. This is the path for hosts that reconstruct their own
RealityKit entities and want a production viewport (orbit camera, grid, IBL,
selection outline, correct macOS picking) without re-implementing it.

```swift
import RealityKitStageView

let provider = RealityKitProvider()

// Inject a hierarchy you built yourself. Mark the source as injected so the
// viewport treats it as loaded — no URL or sentinel load command needed.
provider.setModel(rootNode: myWorldEntity, metersPerUnit: 1, isZUp: false)

var configuration = RealityKitConfiguration()
configuration.source = .injectedEntity   // picking gated on isLoaded alone
configuration.appearance = .dark          // themes background + grid; one-liner
```

- **Injected source.** With `source = .injectedEntity`, viewport picking is
  gated on `runtime.isLoaded && runtime.modelEntity != nil` — there is no need
  to supply a `modelURL` to unlock clicks. The URL load path is unchanged.

- **Anonymous-wrapper contract.** `setModel(_:metersPerUnit:isZUp:)` treats its
  argument as an *anonymous root wrapper*: the argument itself is not mapped as a
  prim and only its children are walked (matching the shape `Entity(contentsOf:)`
  produces). Use `setModel(rootNode:metersPerUnit:isZUp:)` when you want the
  passed entity itself mapped as the first, selectable node.

- **Host-free bounds.** When no bounds are supplied via
  `setExternalSceneBounds(_:)`, the provider derives frameable bounds from the
  injected entity's visual bounds, so the camera frames and the grid renders
  without the host computing bounds. Authored bounds still override.

- **Appearance.** Set `configuration.appearance` to a `StageViewAppearance`
  (e.g. `.dark`, `.light`, or `.custom(...)`) to theme both the solid background
  and the grid to match the host, without touching the skybox or
  `showEnvironmentBackground`. When set, the environment background sphere is
  suppressed so the themed background is visible.

### Scene-space entity drag

For hosts that route entity moves through their own runtime (rather than letting
the viewport mutate the entity), `.entityDrag` interaction mode reports a drag on
the selected entity in **scene space**. The viewport never moves the entity
itself.

```swift
configuration.interactionMode = .entityDrag

provider.setEntityDragHandler { sample in
    switch sample.phase {
    case .began:   /* sample.scenePoint is the entity's start position */ break
    case .changed: hostRuntime.apply(delta: sample.delta) // incremental move
    case .ended:   break
    }
}
```

Each `SceneSpaceDragSample` carries an incremental `delta`, a running
`totalDelta`, and an exact `scenePoint` recovered by intersecting the cursor ray
with a camera-facing plane through the entity. Drags that begin on empty space
still orbit the camera, so the user can reframe between moves. The screen→scene
math is exposed as the pure, testable `SceneSpaceDragMath`.

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
- [**OpenUSDKit**](https://github.com/Reality2713/OpenUSDKit) - USD capability layer for inspection, editing, validation, variants, materials, and asset workflows
- [**SwiftUsdShell**](https://github.com/Reality2713/SwiftUsdShell) - Typed shell over SwiftUsd/OpenUSD primitives
- [**RealityKit**](https://developer.apple.com/documentation/realitykit) - Apple's 3D rendering framework
- [**Reality Composer Pro**](https://developer.apple.com/augmented-reality/tools/) - Apple's USD authoring tool

## License

MIT License
