# Changelog

All notable changes to StageView are documented here.

## 0.4.0

The `.postProcessOutline` style is now drawn by
[SelectionEffects](https://github.com/elkraneo/SelectionEffects), which also
outlines content rendered by USDKit's `USDStageComponent`.

### Changed

- **`.postProcessOutline`** sets a `SelectionEffectComponent` on the selected
  entity. The provider keeps the one record of it, and only the active
  viewport changes it, so viewports sharing a provider don't erase each
  other's selection. It's removed when the active view disappears and when
  the model is torn down, re-applied after a model refresh, and restyled when
  the outline colour changes.
- **Provider teardown** advances `selectionGeneration` when it clears the
  selection, so viewports reconcile their highlight.
- **Frame capture** goes through `ViewportFrameCapture` (public, with
  `captureIfRequested(from:)`). A capture times out after 5 seconds without a
  frame; a cancelled capture throws `CancellationError`, including when it's
  cancelled before it's queued or while its frame is read back.

### Removed

- **`PostProcessOutlineEffect`** and the PostProcessOutline dependency. Use
  `SelectionEffectComponent` with `installSelectionEffects()` from
  SelectionEffects instead.

## 0.3.31

No code changes.

- MIT license added (`LICENSE`).
- README condensed (install, quick start, features, configuration, picking,
  hosting) with a new banner.
- `resources/SELECTION_OUTLINE.md` notes that the outline renderer now lives in
  PostProcessOutline; the published article's draft and unreferenced
  screenshots are removed.

## 0.3.30

The post-process selection outline now comes from the
[PostProcessOutline](https://github.com/elkraneo/PostProcessOutline) package
instead of a vendored copy. `PostProcessOutlineEffect`'s public API is
unchanged (`init(color:radius:prefersChildMeshes:)`, `color`, `radius`,
`prefersChildMeshes`, `setSelection`, `setViewMatrix`, `requestFrameCapture`).

### Changed

- **Outline rendering** is delegated to `PostProcessOutline.OutlineRenderer`.
  `SelectionOutline/Shaders/OutlineShaders.metal` is removed.
- **Effect copies share their settings.** `color`, `radius` and
  `prefersChildMeshes` now read and write shared state, so every copy reports
  the values it draws with. Setters stay `mutating`, so `@State` observation
  is unchanged.
- **`radius` is clamped to `0...64`** (`OutlineRenderer.maxRadius`); larger
  values stalled the GPU's dilation pass. A stored radius above 64 now reads
  back as 64.

### Fixed

- **Viewport capture** no longer hangs when two captures are requested before
  the next frame: every pending request receives that frame.
- **Viewport capture** reads a copy of the finished frame made on the same
  command buffer, instead of RealityKit's target texture after the frame ends.
- **Viewport capture** reports an error when the GPU work fails, instead of
  returning a stale image.
- **Intel/AMD Macs:** the outline writes sRGB targets through a non-sRGB view
  with manual sRGB encoding, and writes `rgba16Float` targets directly. The
  previous code could darken the frame or abort.
- Thread-safe view matrix, cached intermediate textures, and a pass-through
  frame when Metal encoding fails.
- **Viewport capture colour:** `_srgb` and float (`rgba16Float`) frames are
  now read with the linear variant of the capture colour space, so captures
  no longer come out darker than the on-screen viewport.
- **Outline colour** is blended in linear space, so non-primary colours
  (including the default `.cyan`) render as specified instead of lighter.

### Added

- `PostProcessOutlineEffect.updateTransforms()` to refresh the outline of
  moving entities (call it per frame from a scene event or system).
- **Embedded animation playback controls** on `RealityKitProvider`:
  observable `isEmbeddedAnimationPlaying`, `toggleEmbeddedAnimationPlayback()`,
  and `resetEmbeddedAnimation()` (pauses and returns to the first frame).

## 0.3.28

Adoption improvements for hosts that feed the viewport an externally-built
entity hierarchy (an "entity source"), plus a native scene-space drag API. All
changes are additive; the existing public API and the URL load path are
unchanged.

This release supersedes `0.3.27`, which was tagged before the touch-platform
build check caught that the entity-drag hook type was macOS-scoped while the
iOS/visionOS control initializer referenced it for API parity.

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

- Fixed the generic visionOS library build by making `ViewportEntityDragHooks`
  available to the touch-platform `ArcballCameraControls` API while keeping
  scene-space entity drag behavior macOS-only.
- Updated pinned dependency versions (`Package.resolved`) to build under the
  current Swift toolchain. Aligned two test files with the current toolchain
  (`import Foundation` for `tan`; key-path `receive` assertion form) and aligned
  the viewport exposure tests with the shipping identity EV mapping (the tests
  asserted an earlier calibration the source no longer implements).
