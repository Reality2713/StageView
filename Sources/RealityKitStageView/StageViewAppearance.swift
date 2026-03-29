import SwiftUI
import simd

/// Describes the viewport's appearance intent.
///
/// Use `.automatic` for the package defaults, `.light`/`.dark` to force a
/// specific look, and `.custom` when a host application wants to supply
/// explicit background or grid styling.
public enum StageViewAppearance: Sendable, Equatable {
    case automatic
    case light
    case dark
    case custom(StageViewAppearanceOverrides)
}

/// Advanced appearance overrides layered on top of the viewport's base mode.
///
/// This type is intended for host applications that persist user or document
/// preferences and need to pass that intent into `StageViewFeature.State`.
public struct StageViewAppearanceOverrides: Sendable, Equatable {
    public var background: StageViewBackgroundStyle?
    public var grid: StageViewGridStyle?

    public init(
        background: StageViewBackgroundStyle? = nil,
        grid: StageViewGridStyle? = nil
    ) {
        self.background = background
        self.grid = grid
    }
}

/// Describes how the viewport background should be chosen.
public enum StageViewBackgroundStyle: Sendable, Equatable {
    case automatic
    case color(SIMD4<Float>)
    case palette(light: SIMD4<Float>, dark: SIMD4<Float>)
}

/// Describes custom grid color behavior.
///
/// Omit either color to keep the package defaults for that channel.
public struct StageViewGridStyle: Sendable, Equatable {
    public var minorColor: StageViewColorStyle?
    public var majorColor: StageViewColorStyle?

    public init(
        minorColor: StageViewColorStyle? = nil,
        majorColor: StageViewColorStyle? = nil
    ) {
        self.minorColor = minorColor
        self.majorColor = majorColor
    }
}

/// Describes how a single viewport color should be chosen.
public enum StageViewColorStyle: Sendable, Equatable {
    case automatic
    case color(SIMD3<Float>)
    case palette(light: SIMD3<Float>, dark: SIMD3<Float>)
}

struct ResolvedStageViewAppearance: Equatable {
    var viewportAppearance: ViewportAppearance
    var backgroundColor: SIMD4<Float>
    var gridMinorColor: SIMD3<Float>
    var gridMajorColor: SIMD3<Float>
}

extension StageViewAppearance {
    func resolvedAppearance(for colorScheme: ColorScheme) -> ResolvedStageViewAppearance {
        let viewportAppearance = resolvedViewportAppearance(for: colorScheme)
        let defaultPalette = ProceduralGridPalette(appearance: viewportAppearance)
        let gridOverride = customGridOverride

        return ResolvedStageViewAppearance(
            viewportAppearance: viewportAppearance,
            backgroundColor: resolvedBackgroundColor(for: viewportAppearance),
            gridMinorColor: resolvedGridColor(
                gridOverride?.minorColor,
                appearance: viewportAppearance,
                defaultColor: defaultPalette.minorColor
            ),
            gridMajorColor: resolvedGridColor(
                gridOverride?.majorColor,
                appearance: viewportAppearance,
                defaultColor: defaultPalette.majorColor
            )
        )
    }

    private var customBackgroundOverride: StageViewBackgroundStyle? {
        if case let .custom(overrides) = self {
            return overrides.background
        }
        return nil
    }

    private var customGridOverride: StageViewGridStyle? {
        if case let .custom(overrides) = self {
            return overrides.grid
        }
        return nil
    }

    private func resolvedViewportAppearance(for colorScheme: ColorScheme) -> ViewportAppearance {
        switch self {
        case .automatic, .custom:
            return colorScheme == .light ? .light : .dark
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private func resolvedBackgroundColor(for appearance: ViewportAppearance) -> SIMD4<Float> {
        if let customBackgroundOverride {
            return resolvedBackgroundColor(customBackgroundOverride, for: appearance)
        }
        return defaultBackgroundColor(for: appearance)
    }

    private func resolvedBackgroundColor(
        _ style: StageViewBackgroundStyle,
        for appearance: ViewportAppearance
    ) -> SIMD4<Float> {
        switch style {
        case .automatic:
            return defaultBackgroundColor(for: appearance)
        case let .color(color):
            return clamped(color)
        case let .palette(light, dark):
            return clamped(appearance == .light ? light : dark)
        }
    }

    private func resolvedGridColor(
        _ style: StageViewColorStyle?,
        appearance: ViewportAppearance,
        defaultColor: SIMD3<Float>
    ) -> SIMD3<Float> {
        guard let style else {
            return defaultColor
        }

        switch style {
        case .automatic:
            return defaultColor
        case let .color(color):
            return clamped(color)
        case let .palette(light, dark):
            return clamped(appearance == .light ? light : dark)
        }
    }

    private func defaultBackgroundColor(for appearance: ViewportAppearance) -> SIMD4<Float> {
        switch appearance {
        case .light:
            return SIMD4<Float>(0.93, 0.94, 0.96, 1.0)
        case .dark:
            return SIMD4<Float>(0.18, 0.18, 0.18, 1.0)
        }
    }

    private func clamped(_ color: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(
            Swift.min(Swift.max(color.x, 0), 1),
            Swift.min(Swift.max(color.y, 0), 1),
            Swift.min(Swift.max(color.z, 0), 1),
            Swift.min(Swift.max(color.w, 0), 1)
        )
    }

    private func clamped(_ color: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            Swift.min(Swift.max(color.x, 0), 1),
            Swift.min(Swift.max(color.y, 0), 1),
            Swift.min(Swift.max(color.z, 0), 1)
        )
    }
}
