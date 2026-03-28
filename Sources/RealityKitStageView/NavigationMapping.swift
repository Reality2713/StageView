#if os(macOS)
import AppKit
public typealias PlatformModifierFlags = NSEvent.ModifierFlags
#elseif os(iOS) || os(visionOS)
import UIKit
public typealias PlatformModifierFlags = UIKeyModifierFlags
#endif

extension PlatformModifierFlags {
    static var optionKey: Self {
        #if os(macOS)
        .option
        #else
        .alternate
        #endif
    }
}

/// Data-driven camera navigation mapping for the RealityKit viewport.
/// Each preset is a static factory that produces bindings matching
/// a specific DCC tool's camera conventions.
public struct RealityKitNavigationMapping: Sendable, Equatable {
    public enum CameraAction: Sendable, Equatable { case orbit, pan, zoom }

    public struct MouseBinding: Sendable, Equatable {
        public var button: Int          // 0 = LMB, 1 = RMB, 2 = MMB
        public var modifiers: PlatformModifierFlags

        public init(button: Int, modifiers: PlatformModifierFlags = []) {
            self.button = button
            self.modifiers = modifiers
        }

        public static func == (lhs: MouseBinding, rhs: MouseBinding) -> Bool {
            lhs.button == rhs.button && lhs.modifiers == rhs.modifiers
        }
    }

    // Mouse button bindings
    public var orbit: MouseBinding
    public var pan: MouseBinding
    public var zoom: MouseBinding

    // Scroll behavior
    public var scrollAction: CameraAction
    public var optionScrollAction: CameraAction

    // Inversion toggles
    public var invertZoomDirection: Bool
    public var invertScrollDirection: Bool

    // SwiftUI gestures (Apple/Touchpad) vs NSEvent monitors (DCC presets)
    public var useSwiftUIGestures: Bool

    public init(
        orbit: MouseBinding,
        pan: MouseBinding,
        zoom: MouseBinding,
        scrollAction: CameraAction = .pan,
        optionScrollAction: CameraAction = .zoom,
        invertZoomDirection: Bool = false,
        invertScrollDirection: Bool = false,
        useSwiftUIGestures: Bool = true
    ) {
        self.orbit = orbit
        self.pan = pan
        self.zoom = zoom
        self.scrollAction = scrollAction
        self.optionScrollAction = optionScrollAction
        self.invertZoomDirection = invertZoomDirection
        self.invertScrollDirection = invertScrollDirection
        self.useSwiftUIGestures = useSwiftUIGestures
    }
}

// MARK: - Static Factories

extension RealityKitNavigationMapping {
    /// Apple-style: LMB drag = orbit, Option+LMB = pan,
    /// scroll = pan, Option+scroll = zoom, pinch = zoom.
    /// Uses SwiftUI gestures for trackpad-friendly interaction.
    public static let apple = RealityKitNavigationMapping(
        orbit: MouseBinding(button: 0),
        pan: MouseBinding(button: 0, modifiers: .optionKey),
        zoom: MouseBinding(button: 1),
        scrollAction: .pan,
        optionScrollAction: .zoom,
        useSwiftUIGestures: true
    )

    /// Maya-style: Option+LMB = orbit, Option+MMB = pan, Option+RMB = zoom.
    /// Uses NSEvent monitors for three-button mouse interaction.
    public static let maya = RealityKitNavigationMapping(
        orbit: MouseBinding(button: 0, modifiers: .optionKey),
        pan: MouseBinding(button: 2, modifiers: .optionKey),
        zoom: MouseBinding(button: 1, modifiers: .optionKey),
        scrollAction: .pan,
        optionScrollAction: .zoom,
        useSwiftUIGestures: false
    )

    /// Blender-style: MMB = orbit, Shift+MMB = pan, scroll = zoom.
    /// Uses NSEvent monitors for three-button mouse interaction.
    public static let blender = RealityKitNavigationMapping(
        orbit: MouseBinding(button: 2),
        pan: MouseBinding(button: 2, modifiers: .shift),
        zoom: MouseBinding(button: 1),
        scrollAction: .zoom,
        optionScrollAction: .pan,
        useSwiftUIGestures: false
    )

    /// Houdini-style: LMB = orbit, MMB = pan, scroll = zoom.
    /// Uses NSEvent monitors for three-button mouse interaction.
    public static let houdini = RealityKitNavigationMapping(
        orbit: MouseBinding(button: 0),
        pan: MouseBinding(button: 2),
        zoom: MouseBinding(button: 1),
        scrollAction: .zoom,
        optionScrollAction: .pan,
        useSwiftUIGestures: false
    )

    /// Touchpad-only: drag = orbit, two-finger scroll = pan, pinch = zoom.
    /// Uses SwiftUI gestures exclusively.
    public static let touchpad = RealityKitNavigationMapping(
        orbit: MouseBinding(button: 0),
        pan: MouseBinding(button: 0, modifiers: .optionKey),
        zoom: MouseBinding(button: 1),
        scrollAction: .pan,
        optionScrollAction: .zoom,
        useSwiftUIGestures: true
    )

    /// Backward-compatible factory: maps the old two-case preset enum names.
    public static func fromLegacyPreset(_ name: String) -> RealityKitNavigationMapping {
        switch name {
        case "apple": return .apple
        case "industry_standard": return .maya
        default: return .apple
        }
    }
}
