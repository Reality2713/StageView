# Changelog

All notable changes to StageView are documented here.

## 0.3.27

Adoption improvements for hosts that feed the viewport an externally-built
entity hierarchy (an "entity source"), plus a native scene-space drag API. All
changes are additive; the existing public API and the URL load path are
unchanged.

### Added

- **Scene-space entity drag.** A new `.entityDrag` viewport interaction mode
  (`RealityKitConfiguration.interactionMode`) reports a drag on the selected
  entity to the host in **scene space** via
  `RealityKitProvider.setEntityDragHandler(_:)` (and the observable
  `lastSceneDragSample` / `sceneDragGeneration`). The viewport does not move the
  entity itself — the host routes the move through its own runtime. Each
  `SceneSpaceDragSample` carries an incremental `delta`, a running `totalDelta`,
  and an exact `scenePoint` (cursor ray intersected with a camera-facing plane
  through the entity). Drags that begin on empty space still orbit the camera.
- **`SceneSpaceDragMath`.** A pure, platform-independent (no RealityKit/SwiftUI)
  math core for screen→scene conversion: camera-basis delta, NDC conversion,
  perspective camera ray construction, and ray/plane intersection. Fully unit
  tested.
- **Injected-entity source.** `RealityKitConfiguration.source = .injectedEntity`
  gates viewport picking on `isLoaded && modelEntity != nil` alone, so a host
  feeding the viewport via `setModel` no longer needs to supply a `modelURL` (or
  a sentinel load command) to unlock clicks.
- **`setModel(rootNode:metersPerUnit:isZUp:)`.** Maps the passed entity itself as
  the first, selectable node, instead of treating it as an anonymous wrapper.
  The existing `setModel(_:metersPerUnit:isZUp:)` anonymous-wrapper contract is
  now documented.
- **`RealityKitProvider.isExternallyDriven`.** Reflects whether the current model
  was injected via `setModel` rather than loaded from a URL.
- **Appearance knob.** `RealityKitConfiguration.appearance` (optional
  `StageViewAppearance`) themes both the solid background and the grid to match a
  host light/dark mode in one line, and suppresses the environment background
  sphere by default so the themed background is visible — no skybox or
  `showEnvironmentBackground` knowledge required.

### Changed

- **Host-free scene bounds.** When no external bounds are supplied, the provider
  now derives frameable bounds from the injected entity's visual bounds (padding
  planar geometry to a frameable cube) instead of logging an error and clearing
  bounds. Hosts that supply authored bounds via `setExternalSceneBounds(_:)`
  still override. A structural-only hierarchy with no geometry still yields
  non-frameable bounds until the host supplies them.

### Fixed / Maintenance

- Updated pinned dependency versions (`Package.resolved`) to build under the
  current Swift toolchain. Aligned two test files with the current toolchain
  (`import Foundation` for `tan`; key-path `receive` assertion form) and aligned
  the viewport exposure tests with the shipping identity EV mapping (the tests
  asserted an earlier calibration the source no longer implements).
