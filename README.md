# StageView

A Swift package providing shared viewport abstractions for 3D rendering with RealityKit.

## Overview

StageView provides a common protocol and types that RealityKit renderers can conform to, enabling consistent viewport behavior across different rendering backends.

## Features

- **Unified Protocol**: `StageViewport` protocol for consistent viewport interface
- **Dynamic Grid**: Scale-aware grid that extends based on scene size (1 meter = 1 meter always)
- **IBL Support**: Environment lighting with EV-style exposure control
- **Scale Indicator**: Auto-switching scale reference (cm/m/km) based on scene size
- **Colored Axes**: Visual axis indicators (X=red, Y=green, Z=blue)

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

## Hydra / OpenUSD

Hydra support (and its OpenUSD dependency) lives in a separate package: `StageViewHydra`.

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/elkraneo/StageView.git", branch: "main"),
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

## Requirements

- macOS 15.0+
- iOS 18.0+
- visionOS 2.0+
- Swift 6.0+

## License

MIT License
