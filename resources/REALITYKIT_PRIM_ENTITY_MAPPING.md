# RealityKit Prim-Entity Mapping

This document explains how `RealityKitStageView` reconstructs USD-like prim paths
from RealityKit-imported entities, what guarantees that mapping does and does not
provide, and how consumers should use it.

It consolidates behavior that was previously split across implementation comments,
the StageView README, and selection-resolution tests.

---

## Why This Exists

RealityKit does not expose a public API that says "this imported `Entity` came from
 USD prim `/Foo/Bar/Baz`".

`RealityKitStageView` therefore reconstructs a best-effort prim path mapping by
walking the imported `Entity` tree produced by:

```swift
try await Entity(contentsOf: url)
```

This mapping is used for:

- selection synchronization
- pick-path upgrading
- non-destructive viewport-only runtime projections such as visibility

It is **not** a formal USD identity contract from RealityKit.

---

## Core Assumption

For most imported USD content, RealityKit preserves enough of the source hierarchy
and names that the entity tree is a usable structural mirror of the prim tree.

The mapping logic therefore:

1. walks the imported entity tree
2. treats each entity name as a prim name
3. reconstructs a slash-delimited prim path from parent to child

Implementation:

- `RealityKitProvider.buildPrimPathMapping(root:)`
- `RealityKitProvider.stripDuplicateSuffix(_:amongSiblingsOf:)`

Source:

- [RealityKitProvider.swift](../Sources/RealityKitStageView/RealityKitProvider.swift)

---

## Duplicate Name Suffixes

RealityKit may append suffixes such as `_1`, `_2`, etc. when sibling names collide.

Example:

```text
Wheel
Wheel_1
Wheel_2
```

The mapper does **not** blindly strip trailing underscore-number sequences. It only
strips them when sibling evidence suggests RealityKit introduced the suffix.

Current rule:

- detect a trailing `_<digits>` suffix
- derive the base name
- check whether sibling names confirm the base-name collision
- strip only when that sibling evidence exists

This is why a legitimate authored prim named something like `LOD_1` is less likely
to be damaged by the heuristic.

---

## Internal Entities

RealityKit can inject internal helper entities that are not source prims.

These are explicitly skipped from the mapping.

Current example:

- `usdPrimitiveAxis`

If more importer-generated internal names appear, they should be added to the
skip list rather than treated as authored prims.

---

## Generic Imported Names

RealityKit may collapse imported geometry into generic buckets such as:

- `merged_1`
- `mesh_0`

Those names are often not semantically useful as pick/selection results. Because of
that, StageView separates **direct imported mapping** from **semantic pick upgrade**.

Direct mapping:

- `entity(for:)`
- `primPath(for:)`
- `nearestMappedPrimPath(from:)`

Semantic pick upgrade:

- `preferredPickPrimPath(from:)`
- `preferredPickPrimPath(from: [Entity])`

Selection/picking may therefore return a path that is more semantic than the direct
imported mapping.

---

## Mapping Tiers

There are three different mapping needs in StageView. They should not be treated as
interchangeable.

### 1. Direct Imported Mapping

This is the raw reconstructed mapping from entity hierarchy and names.

Use when:

- you want the closest RealityKit-imported identity
- you are debugging importer structure
- you are doing conservative renderer-local projections

API:

- `entity(for:)`
- `primPath(for:)`

### 2. Selection Mapping

Selection needs a more tolerant resolver because the imported hierarchy can differ
from Hydra/OpenUSD structure.

Current fallback behavior includes:

- exact match
- dropping leading path segments
- nearest descendant
- suffix matching
- nearest ancestor

API:

- `selectionEntity(for:)`

This is intentionally more permissive than direct mapping.

### 3. Pick Mapping

Picking from a raycast hit list is even more specialized. It must avoid reporting
generic merged importer buckets when a more meaningful sibling/override is known.

API:

- `preferredPickPrimPath(from:)`
- `preferredPickPrimPath(from: [Entity])`
- `setPickPathOverrides(_:)`
- `setPickPathResolver(_:)`

Consumer overrides run before built-in generic-name fallback.

---

## Selection vs Visibility

This distinction matters.

### Selection

Selection can tolerate fuzzy fallback:

- ancestor
- descendant
- suffix match
- consumer semantic override

If the selected thing is slightly coarser than the authored prim, the user still
gets a usable selection experience.

### Visibility

Visibility is stricter.

Viewport visibility projection should not automatically reuse the full selection
resolver because hiding the wrong ancestor or semantic sibling is a behavioral bug.

For RealityKit runtime visibility projection, the safer model is:

1. start from canonical authored hidden prim paths
2. find direct mapped descendants in the imported entity graph
3. project only onto render-carrying entities or renderable subtrees
4. treat unsupported deep subprims as a renderer limitation, not a reason to apply
   broader fuzzy matching

In other words:

- selection may be approximate
- visibility should be conservative

---

## Renderability Caveat

A mapped entity is not necessarily a render carrier.

An entity may:

- exist in the imported hierarchy
- map cleanly to a USD-like path
- yet have no `ModelComponent`
- and no renderable descendants

That means:

- selection can still "work" for that path
- visibility projection onto that entity can visually do nothing

This is the main reason deep subprim visibility can fail in RealityKit even when
top-level and first-level children work.

The current debugging signal for this is the StageView log line used by selection
highlighting:

```text
Selection highlight path=... directModel=false subtreeModels=0
```

That indicates the mapped entity is logical, but not renderable.

---

## Consumer Hooks

Consumers can improve pick semantics using:

```swift
provider.setPickPathOverrides([
    "/RootNode/merged_1": "/RootNode/Forklift"
])

provider.setPickPathResolver { directPath, entity, provider in
    guard directPath == "/RootNode/merged_1" else { return nil }
    return "/RootNode/Forklift/Body"
}
```

These hooks are intended for:

- generic merged importer buckets
- app-specific scene knowledge
- semantic pick remapping

They are **not** a substitute for exact renderability data.

---

## Current Tests

Relevant tests:

- `RealityKitProviderSelectionResolutionTests`

Covered today:

- exact resolution
- dropped-leading-segment fallback
- ancestor fallback
- generic merged pick-path fallback
- consumer overrides/resolvers

Not yet covered well enough:

- duplicate suffix edge cases with legitimate authored underscores
- render-carrying vs non-render-carrying mapped entities
- deep subprim visibility projection behavior

Those are the next meaningful tests to add.

---

## Practical Guidance

If you are building new behavior on top of this mapping:

1. decide whether you need direct mapping, selection mapping, or pick mapping
2. do not use the most permissive resolver by default
3. treat renderability as a separate concern from path identity
4. prefer explicit unsupported-state handling over broad fuzzy fallback for
   mutating operations

This keeps StageView honest about what RealityKit actually imported.
