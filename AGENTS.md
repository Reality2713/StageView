# StageView visionOS RealityKit Rules

For `RealityKitStageView` and other visionOS 26 rendering surfaces:

- Do not add or extend `RealityView update:` behavior. Use observable RealityKit
  entities, explicit runtime events, gesture callbacks, or systems.
- Use `onGeometryChange3D` for volumetric bounds and placement; do not add
  `GeometryReader3D`.
- Keep fit/placement state on RealityKit-owned entities/components or runtime
  state. Never mutate SwiftUI state from a RealityKit view-update pass.

Reference: Apple WWDC25 session 274, *Better together: SwiftUI and RealityKit*.
