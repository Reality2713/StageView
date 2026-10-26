# Sources

Gathered 25–26 October 2026. Every binding in [`README.md`](README.md) and [`presets.json`](presets.json) traces to
one of these. "Primary" means a vendor's documentation, its source code, or the installed app's own files.
**Unconfirmed** marks anything that rests on secondary evidence.

| Id | App | Evidence | Kind |
|---|---|---|---|
| `maya` | Maya 2026 | Autodesk help: Tumble ([GUID-A3305185](https://help.autodesk.com/cloudhelp/2026/ENU/Maya-Basics/files/GUID-A3305185-DFBD-42BF-8A70-59208C2C9887.htm)), Track ([GUID-12A3D7B8](https://help.autodesk.com/cloudhelp/2026/ENU/Maya-Basics/files/GUID-12A3D7B8-357C-467D-A139-8E2DF7B55AA6.htm)), Dolly ([GUID-A2851E8C](https://help.autodesk.com/cloudhelp/2026/ENU/Maya-Basics/files/GUID-A2851E8C-A4EE-4546-B383-27D9CB530AB8.htm)), Frame ([GUID-C420C235](https://help.autodesk.com/cloudhelp/2026/ENU/Maya-Basics/files/GUID-C420C235-B8DC-4129-8449-8B7B7911F94B.htm)), Multi-touch ([GUID-B0E00E49](https://help.autodesk.com/cloudhelp/2026/ENU/Maya-Customizing/files/GUID-B0E00E49-90BF-4714-AB89-66CD0E3E27F3.htm)) | Primary |
| `rcp3` | Reality Composer Pro 3.0 | Behaviour observed in the app | Observed |
| `c4d` | Cinema 4D 2027 | Maxon help: [Quick Start](https://help.maxon.net/c4d/2027/en-us/Content/html/CINEMA_4D_QUICKSTART.html), [Camera Navigation prefs](https://help.maxon.net/c4d/2027/en-us/Content/html/PREFSNAVIGATION-PREF_NAVIGATION_MAIN_GROUP.html), [View menu](https://help.maxon.net/c4d/2027/en-us/Content/html/5852.html) | Primary. Trackpad mapping unconfirmed |
| `blender` | Blender (main) | `scripts/presets/keyconfig/keymap_data/blender_default.py` `km_view3d` (L1636–1811), `intern/ghost/intern/GHOST_SystemCocoa.mm` (scroll phases, Magic Mouse comment), `source/blender/windowmanager/intern/wm_event_system.cc` `wm_eventemulation` (Emulate 3 Button Mouse), `rna_userdef.cc` (preferences) | Primary (source) |
| `blenderIC` | Blender Industry Compatible | `scripts/presets/keyconfig/keymap_data/industry_compatible_data.py` `km_view3d` (L676–720) | Primary (source) |
| `blender54963` | Blender design task #54963 (2018) | [projects.blender.org/blender/blender/issues/54963](https://projects.blender.org/blender/blender/issues/54963): a chart comparing 3ds Max, Maya, C4D, Modo, Houdini, Unreal and Unity, plus the tie-breaker-app idea | Secondary (design research) |
| `plasticity` | Plasticity 26.2.1 | The app's own `keymap.json` and `settings.json`, recorded while each Navigation preset was selected in turn: `mouse0`/`mouse1`/`mouse2` = left/middle/right, `gesture` = swipe, `pinch` | Primary (app output) |
| `godot` | Godot (master) | `scene/debugger/view_3d_controller.{h,cpp}` (`NavigationScheme`, gesture handling), `editor/settings/editor_settings_dialog.cpp` `update_3d_navigation_preset()`, `editor/settings/editor_settings.cpp`; PRs [#85331](https://github.com/godotengine/godot/pull/85331) and [#97985](https://github.com/godotengine/godot/pull/97985) | Primary (source) |
| `houdini` | Houdini 21.0.631 | The installed app's `config/Hotkeys/h.pane.gview.state`, `HotkeyDefaultBindings.json`, and its shipped help (`help/basics.zip:view.txt`, `macosx.txt`) | Primary (installed files) |
| `shapr3d` | Shapr3D | [Keyboard shortcuts, gestures and hotkeys](https://support.shapr3d.com/hc/en-us/articles/7873906073884-Keyboard-shortcuts-gestures-and-hotkeys), [Navigation Presets](https://support.shapr3d.com/hc/en-us/articles/7873881091356-Navigation-Presets) | Primary. Only the default preset is spelled out |
| `unity` | Unity 6.6 | [Scene view navigation](https://docs.unity3d.com/Manual/SceneViewNavigation.html) | Primary |
| `unreal` | Unreal Engine 5.8 | [Viewport controls](https://dev.epicgames.com/documentation/en-us/unreal-engine/viewport-controls-in-unreal-engine) | Primary |
| `fusion` | Fusion | [Autodesk help](https://help.autodesk.com/view/fusion360/ENU/?guid=GUID-F0491540-0324-470A-B651-2238D0EFAC30) | Primary |
| `max` | 3ds Max 2026 | Autodesk help [GUID-D65DE5FD](https://help.autodesk.com/cloudhelp/2026/ENU/3DSMax-Basics/files/GUID-D65DE5FD-F859-4F66-9E14-F9A5C1016411.htm) | Primary |
| `modo` | Modo 17.1 | [3D viewport](https://learn.foundry.com/modo/content/help/pages/modo_interface/3d_viewport.html), [Input prefs](https://learn.foundry.com/modo/content/help/pages/preferences/pref_input.html), [wind-down notice](https://foundry.com/news-and-awards/foundry-winds-down-modo-development) | Primary |
| `solidworks` | SolidWorks | [Middle mouse button](https://help.solidworks.com/2024/English/SolidWorks/sldworks/r_Middle_Mouse_Button.htm): middle-drag rotates, Control + middle pans, Shift + middle zooms | **Unconfirmed** (page not readable); not a preset |

## Known gaps

- Plasticity Touchpad preset: how you orbit isn't recorded in its keymap.
- Shapr3D's eleven compatibility presets are shown only as an in-app diagram.
- Cinema 4D's and Houdini's trackpad gestures on macOS aren't documented by their vendors.
- Rhino bindings come from Plasticity's emulation of Rhino, not from McNeel's docs.
