# Viewport navigation: the canonical spec

Status: draft, 26 October 2026. This is the single source of truth for camera navigation in every Reality2713
viewport (Shapemoss, Gantry, Preflight, Hull and anything built on StageView). It defines **what** each input does.
Each app still owns **how it feels**: sensitivity, inertia, the camera model, and the renderer.

- Machine-readable presets: [`presets.json`](presets.json)
- Evidence for every row: [`SOURCES.md`](SOURCES.md)

## 1. Why

The users these apps are built for move between Maya, Blender, Cinema 4D, Houdini, Reality Composer Pro, Plasticity
and Shapr3D every day. A viewport that ignores their muscle memory feels broken, however good its renderer is.
Before this spec, StageView, StageViewHydra and the apps each carried their own copy of the bindings, and the copies
had drifted apart. This spec replaces those copies with one vocabulary and one preset table.

## 2. Vocabulary

**Actions**

| Action | Meaning |
|---|---|
| `orbit` | Rotate the camera around the pivot (tumble). |
| `pan` | Translate the camera parallel to the view plane (track). |
| `dolly` | Move the camera along the view direction. Apps may implement it as a lens zoom in orthographic views. |
| `frameSelection` | Fit the selection in view and move the pivot to it. |
| `frameAll` | Fit the whole scene in view. |
| `fly` | First-person movement (WASD/QE) while a trigger is held. |
| `none` | The input goes on to the tools and selection. |

**Inputs**

- **Buttons:** `left`, `middle`, `right`, `button4`, `button5`; or `none` for modifier-only navigation.
- **Modifiers:** `option`, `shift`, `control`, `command`, plus `space` held as a modifier (Houdini).
- **Continuous inputs:**
  - `wheel`: a discrete or precise scroll without gesture phases.
  - `swipe`: two-finger trackpad scroll, which carries gesture phases.
  - `pinch`: magnify.
  - `rotate`: the two-finger rotation gesture.

**Platform fact (macOS):** AppKit can't tell a trackpad from a Magic Mouse. Both deliver scroll events with gesture
phases, and Blender's own code says so. Treat them as one device class, `touchSurface`, with one setting.

## 3. Rules every app must follow

1. **Navigation captures first.** When a press matches a navigation binding, it owns the gesture until release. Selection,
   handles, gizmos, tools and the context menu never see it. (Godot, D228)
2. **The more specific binding wins.** When several bindings match, the one that needs more held keys wins. So
   `control+shift+middle` beats `shift+middle`. (Godot)
3. **A preset is a writer, not a mode.** Choosing a preset fills in the ordinary per-action bindings and settings.
   Editing any of them switches the preset label to **Custom**. At runtime only the concrete bindings matter. (Godot)
4. **Swipe follows the bindings.** A `swipe` with no modifiers performs the scheme's modifier-free drag action.
   Swipe with a modifier performs the action bound to that modifier. A scheme may override this with an explicit
   `swipe` entry. (Godot, generalised)
5. **Right-click stays a menu.** A right press that doesn't move past a small threshold (3 pt) opens the context menu,
   even in schemes that bind `right` to navigation. (Shapemoss D91)
6. **Cancel is cheap.** Esc, or a right-click during a navigation drag, cancels the drag and restores the camera. (Godot)
7. **Active edits are never hijacked.** A navigation press can't start during an active manipulation, drawing or
   creation gesture.
8. **Accessibility is kept.** Keyboard navigation, menu commands and VoiceOver actions work in every preset.

## 4. Presets

Mouse bindings. `+` joins inputs pressed together. Every row is sourced in [`SOURCES.md`](SOURCES.md).

| Preset | Orbit | Pan | Dolly | Frame selection | Notes |
|---|---|---|---|---|---|
| **industry** (Maya, RCP 3, Cinema 4D, Unity, Blender Industry Compatible, Unreal alt) | `option+left` | `option+middle`, `middle` | `option+right`, `wheel` | `F` (`A` frames all) | The de facto standard: 6 of 7 apps in Blender's 2018 chart agree. Plain `middle` pan comes from Unity and Godot's Maya scheme; Maya itself needs Option. **Tie-breaker: Maya.** |
| **blender** | `middle` | `shift+middle` | `control+middle`, `wheel` | numpad `.` | `emulateMiddleButton`: `option+left` acts as `middle`. |
| **plasticity** | `middle` | `right` | `control+middle`, `wheel` | — | `option+middle` aligns to the nearest axis. |
| **godot** | `middle` | `shift+middle` | `control+middle`, `wheel` | `F` | `option` snaps the orbit to axis angles. |
| **houdini** | `space+left` or `option+left` | `space+middle` or `option+middle` | `space+right` or `option+right`, `wheel` | `F` (`⌘A` frames all) | Space-hold leaves Option free for tools. |
| **shapr3d** | `right` | `middle`, `shift+right` | `wheel` | `Space` over a face | Mac and iPad. |
| **fusion360** | `shift+middle` | `middle` | `wheel` | — | |
| **rhino** (also Mol3D) | `right` | `shift+right` | `option+right`, `wheel` | — | |
| **max3ds** | `option+middle` | `middle` | `control+option+middle`, `wheel` | — | Windows only. Reference. |
| **modo** | `option+left` | `shift+option+left` | `control+option+left`, `wheel` | `shift+A` | Discontinued (Foundry, Nov 2024). Reference. |
| **touchSurface** (Godot "Tablet/Trackpad") | `option` + move | `shift` + move | `control` + move | `F` | Modifier-only navigation, no button needed. |

Touch surface (`swipe`, `pinch`, `rotate`). This is where apps disagree most:

| Family | Swipe | Shift + swipe | Control + swipe | Pinch | Rotate | Apps |
|---|---|---|---|---|---|---|
| **swipeOrbits** | orbit | pan | dolly | dolly | orbit | Blender (both keymaps), Shapr3D, Godot default |
| **swipePans** | pan | — | dolly | dolly | orbit | Reality Composer Pro 3, Plasticity touchpad, Maya |
| **swipeDollies** | dolly | — | — | dolly | — | Unity, Houdini (scroll arrives as wheel), Shapemoss before D228 |

Each app exposes this as one three-way setting (Orbit / Pan / Zoom), unless rule 4 already derives it from the
preset. Pinch dollies everywhere.

## 5. Settings vocabulary

| Setting | Values | Seen in |
|---|---|---|
| `orbitMethod` | `turntable` (default), `trackball` | Blender, Cinema 4D, Plasticity (Tumble/Arcball), Godot, Unreal (arcball) |
| `pivot` | `fixed`, `selection`, `pointer` | Cinema 4D (Cursor is its default), Plasticity "Rotate around cursor", Houdini "Set Pivot on Tumble", Blender "Orbit Around Selection", Maya "Tumble on object" |
| `zoomToPointer` | bool | Plasticity, Cinema 4D "Dolly to Cursor", Blender "Zoom to Mouse Position", Houdini, Maya "Towards center" off, Modo |
| `zoomAxis` | `vertical`, `horizontal` | Blender, Plasticity, Godot |
| `invertZoom`, `invertWheel` | bool | Blender, Plasticity, Godot (invert X/Y) |
| `orbitSensitivity`, `panSensitivity`, `dollySensitivity` | per-app units | all |
| `emulateMiddleButton` | bool | Blender, Godot, Shapemoss (Blender scheme) |
| `touchSurface` | `orbit`, `pan`, `dolly` | see §4 |
| `fly` | trigger + WASD/QE, `shift` faster, wheel sets speed | Unity, Unreal, Godot, RCP 3 (hold right button), Houdini (`M`) |

## 6. What each app decides for itself

- **Feel:** sensitivity, inertia, pitch limits, turntable vs trackball maths, how much framing leaves around the subject.
- **A native preset:** the app's own historical bindings. For Shapemoss that's `shapemoss`: a background drag
  orbits, as in Neo and ZBrush.
- **Its own conflicts.** Example: in `industry`, `option+left` always navigates, so Shapemoss's Option-drag duplicate
  is unavailable there and ⌘D duplicates instead.
- **Which presets it offers.** At minimum: its native preset, `industry`, `blender`, and the three-way touch-surface setting.

## 7. Out of scope (for now)

- **SpaceMouse (6-DoF):** Plasticity, Modo, Cinema 4D and Maya expose speeds, dead zones and per-axis inversion. It
  will get its own section later.
- **iPad and visionOS input models:** Shapr3D is the reference for iPad: one finger orbits, two fingers pan, pinch
  dollies.
- **Shared code:** a `NavigationScheme` value type in StageViewCore comes after at least two apps implement this spec.
  See decision 0001 on the `core-extraction` branch.
