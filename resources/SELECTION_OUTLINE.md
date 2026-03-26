# Selection Outline: Research, Challenges & Implementation

A log of the full process that produced the post-process selection outline in `RealityKitStageView`.

---

## Context

Gantry needed meaningful selection feedback in its RealityKit viewport. The goal was: click an entity → it gets visually highlighted → the inspector responds. "Decorative" was explicitly ruled out — the selection had to be real state driving downstream UI.

---

## Phase 1 — TCA Selection Flow

Before any visual work, the reducer wiring was broken.

`GantryRealityKitFeature.viewportUserPickedPrim` was returning `.none`:

```swift
case let .viewportUserPickedPrim(path):
    state.selectedPrimPath = path
    state.selectionContext = .primPath(path, ...)
    return .none  // ← never propagated
```

Fix: return `._syncSelectionToViewport(path)` so the selection travels the full chain:

```
viewportUserPickedPrim
  → ._syncSelectionToViewport
    → .delegate(.selectionChanged)
      → GantryFeature → StageViewFeature.selectionChanged
        → state.selectedPrimPath = path
          → onChange in view → runtime.setSelection(path)
```

**Lesson**: the outline rendering and the picking gesture are meaningless if the reducer never propagates the pick upward. Fix data flow first.

---

## Phase 2 — Click Detection on macOS

### Attempt 1: SpatialTapGesture

```swift
RealityView { ... }
    .gesture(SpatialTapGesture().targetedToAnyEntity())
```

**Problem**: `SpatialTapGesture().targetedToAnyEntity()` does not work on macOS. It requires a spatial input system (visionOS eye/hand tracking, iOS ARKit). On macOS there is no such system and the gesture never fires regardless of entity setup.

### Attempt 2: InputTargetComponent(.indirect)

Adding `InputTargetComponent(allowedInputTypes: .indirect)` also did nothing on macOS. `.indirect` maps to visionOS ray-cast input (indirect far-field pointing). macOS mouse clicks arrive as `.direct` input type. The component needs `.all`:

```swift
entity.components.set(InputTargetComponent(allowedInputTypes: .all))
```

Even with `.all`, `SpatialTapGesture` still does not fire on macOS. The input type fix is necessary but not sufficient.

### Solution: AppKit NSEvent Monitor

The same pattern used by `HydraContainerView` (which overrides `mouseDown`/`mouseUp` on its NSView subclass). In StageView the infrastructure already had `LocalMouseEventMonitor`; we wired a click-detection block into `ArcballEventController.handleMouseEvent` **before** the `useSwiftUIGestures` early return so it runs for all navigation presets:

```swift
// Click detection — runs for ALL presets, always passes the event through.
if let view = eventRegionView {
    let localPoint = view.convert(event.locationInWindow, from: nil)
    switch event.type {
    case .leftMouseDown where isEventInsideViewport(event):
        mouseDownLocation = localPoint
        mouseDownTime = Date()
    case .leftMouseUp:
        let distance = hypot(localPoint.x - mouseDownLocation.x,
                             localPoint.y - mouseDownLocation.y)
        let duration = Date().timeIntervalSince(mouseDownTime)
        if activeMouseInteraction == nil && distance < 5 && duration < 0.5
            && isEventInsideViewport(event) {
            onPick?(localPoint, size)
        }
    default: break
    }
}
// Camera handling follows (DCC presets only) ...
guard !navigationMapping.useSwiftUIGestures else { return event }
```

Key constraints:
- `distance < 5` and `duration < 0.5` distinguish clicks from drag-starts
- `activeMouseInteraction == nil` prevents firing during camera drags (DCC presets)
- Events are never consumed (never `return nil`) — the block is purely observational

### Ray Construction

`onPick` delivers an AppKit-space point (y=0 at bottom). `macOSPick` converts to a world-space ray:

```swift
// AppKit y-up → NDC y-up (direct linear mapping, no flip needed)
let ndcX = Float(location.x / size.width) * 2 - 1
let ndcY = Float(location.y / size.height) * 2 - 1

// Ray direction in camera local space (RealityKit looks down -Z)
let localDir = SIMD3<Float>(ndcX * tanHalfFov * aspect, ndcY * tanHalfFov, -1)

// Rotate to world space using camera transform columns
let t = runtime.cameraWorldTransform
let camPos  = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
let worldDir = simd_normalize(SIMD3<Float>(
    t.columns.0.x * localDir.x + t.columns.1.x * localDir.y + t.columns.2.x * localDir.z,
    t.columns.0.y * localDir.x + t.columns.1.y * localDir.y + t.columns.2.y * localDir.z,
    t.columns.0.z * localDir.x + t.columns.1.z * localDir.y + t.columns.2.z * localDir.z
))
```

`cameraWorldTransform` is set on every `onChange(of: cameraState)` from `ArcballCameraState.transform` — the same matrix used to position the actual camera entity, so it is always in sync.

#### Bug: Inverted Y (found and fixed)

A linter removed the y-flip that was being applied at the `onPick` call site, while `macOSPick` still computed NDC as if the coordinate was y-down (`ndcY = 1 - y/h*2`). The effect: clicking on the top of the viewport cast a ray toward the bottom of the scene. Objects appeared "impossible to click" unless you clicked at the vertically mirrored position.

Fix: remove the compensating formula and use the direct linear mapping above.

### Collision Shapes

`scene.raycast` requires `CollisionComponent` on entities. Called once after load:

```swift
entity.generateCollisionShapes(recursive: true)
```

This generates convex-hull shapes per mesh. Accuracy is sufficient for selection — not for physics.

### Path Resolution

RealityKit's importer collapses meshes into generic buckets (`merged_1`, `mesh_0`, etc.). A plain `nearestMappedPrimPath` walk would always resolve to these useless names. `preferredPickPrimPath(from: [Entity])` iterates raycast hits in depth order, skips generic names, and falls back to semantic sibling/ancestor paths when needed.

Raycast uses `query: .all` to collect all hits, not just the nearest — this gives the resolver the full ordered hit list to find the most semantically useful prim.

---

## Phase 3 — Highlight Style: Choosing Post-Process Outline

### Options Evaluated

| Style | Mechanism | Verdict |
|---|---|---|
| Bounding box | `ModelDebugOptionsComponent` | Too coarse — marks the axis-aligned box, not the shape |
| Material tint | Modify `ModelComponent.materials` | Destructive — mutates the scene; hard to restore correctly |
| `SpatialTapGesture` + RealityKit built-in highlight | N/A | SpatialTapGesture doesn't fire on macOS |
| Post-process outline | Custom `PostProcessEffect` + Metal | Pixel-perfect, non-destructive, scale-independent |

The post-process approach was chosen: it never mutates scene content, renders at screen resolution regardless of mesh complexity, and produces a visually clean result comparable to what DCC tools show.

---

## Phase 4 — PostProcessOutlineEffect Implementation

### Three-Pass Metal Pipeline

```
Frame N:
  [Main Actor]
    setSelection(entity) → extract packed positions → store as PendingEntry (CPU)
    setViewMatrix(camera.inverse) → store on OutlineRenderState

  [PostProcessEffect callback, render thread]
    flushPending() → upload vertex/index buffers to GPU
    Pass 1 — Mask:      render mesh silhouettes → R8Unorm texture
    Pass 2 — Dilation:  compute kernel expands mask by `radius` px → edge ring
    Pass 3 — Composite: compute kernel blends outline color over source frame
```

### OutlineRenderState

All mutable Metal resources live in a single class shared by all copies of the struct:

```swift
final class OutlineRenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var _pending: [PendingEntry]?           // written @MainActor, read render thread
    var meshEntries: [MeshEntry] = []               // render thread only
    var viewMatrix:  simd_float4x4 = ...            // written @MainActor, read render thread
    var maskPipeline, dilatePipeline, compositePipeline ...
}
```

`pending` is protected by `NSLock` (written on main actor, read in `flushPending` on render thread). `viewMatrix` relies on frame ordering: `update` completes before `postProcess` runs for the same frame, so no formal lock is needed — though it is not formally data-race-safe.

### Why a struct holds a class

`PostProcessEffect` is a value-type protocol. The framework copies the effect struct between `prepare`, `update`, and `postProcess` calls. Storing all Metal state in a class (`private let state = OutlineRenderState()`) ensures every copy refers to the same resources.

### Mesh Extraction Strategy

Walking the entity subtree naively and adding every `ModelComponent` leads to outlining the entire imported model when you select a high-level group node. The fix: stop at the first entity that owns a concrete mesh:

```swift
func collectSelectionMeshEntries(from entity: Entity, into entries: ...) {
    if appendMeshEntryIfAvailable(from: entity, into: &entries) {
        return  // this entity has a mesh — don't descend further
    }
    for child in entity.children {
        collectSelectionMeshEntries(from: child, into: &entries)
    }
}
```

For entities without their own mesh (group/xform nodes), the descent finds the first level of concrete geometry children.

### View Matrix

The outline mask pass needs the correct MVP matrix to project world-space geometry into screen space:

```glsl
float4 outlineMaskVertex(...) {
    float4x4 mvp = uniforms.projection * uniforms.viewMatrix * uniforms.modelMatrix;
    return mvp * float4(position, 1.0);
}
```

`viewMatrix` = inverse of camera world transform, set every frame from the `RealityView` update closure.

`setViewMatrix` is non-mutating (it writes to the `OutlineRenderState` class, not the struct) so the update closure needs no copy-and-writeback:

```swift
// update closure — no var, no writeback
if let effect = outlineBox.effect as? PostProcessOutlineEffect {
    effect.setViewMatrix(camera.transformMatrix(relativeTo: nil).inverse)
    content.renderingEffects.customPostProcessing = .effect(effect)
}
```

### OutlineEffectBox

`PostProcessOutlineEffect` is `@available(macOS 26.0, ...)`. `RealityKitStageView` must compile on earlier platforms. The `@available` annotation cannot be placed on a stored property of a struct without making the entire struct `@available`. Solution: type-erase through `AnyObject`:

```swift
final class OutlineEffectBox {
    var effect: Any?  // holds PostProcessOutlineEffect when available
}

@State private var outlineBox = OutlineEffectBox()
```

Initialized in `.task` under an availability check, accessed in `update` under the same check. The `Any?` cast is safe because only one code path writes to it.

### Availability

```swift
@available(macOS 26.0, iOS 26.0, tvOS 26.0, *)
@available(visionOS, unavailable)
public struct PostProcessOutlineEffect: PostProcessEffect { ... }
```

visionOS is excluded — it has its own spatial highlight system and `PostProcessEffect` behaves differently there.

---

## Diagnostics Approach

`NSLog` was initially used for pick-path tracing. Replaced with `Logger` (OSLog) throughout:

| File | Logger | Category |
|---|---|---|
| `ArcballCameraControls.swift` | `pickLogger` | `Picking` |
| `RealityKitStageView.swift` | `logger` | `Viewport` |
| `RealityKitProvider.swift` | `providerLogger` | `Provider` |

Capture with:
```
log stream --predicate 'subsystem == "RealityKitStageView"' --level debug
```

All interpolated values are marked `privacy: .public` so they appear in captured logs without requiring a profiling certificate.

---

## Summary of Gotchas

| Gotcha | Symptom | Fix |
|---|---|---|
| `SpatialTapGesture` on macOS | Gesture never fires | AppKit NSEvent monitor |
| `InputTargetComponent(.indirect)` | No macOS mouse input | Change to `.all` |
| Reducer returning `.none` | Clicks registered but no highlight | Return `._syncSelectionToViewport` |
| Y-coordinate inversion | Can only "hit" objects at mirrored vertical position | `ndcY = y/h*2 - 1` (AppKit y-up → NDC y-up) |
| `setViewMatrix` mutating | Forced unnecessary struct copy-writeback every frame | Remove `mutating` |
| No collision shapes | Raycast hits nothing | `entity.generateCollisionShapes(recursive: true)` |
| Generic merged paths | Selection always returns `merged_1` | `preferredPickPrimPath(from: [Entity])` with semantic fallback |
| `NSLog` instead of Logger | Unstructured output, no subsystem filtering | `Logger(subsystem:category:)` with `privacy: .public` |
