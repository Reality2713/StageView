import SwiftUI

/// Anchored positions for viewport overlay items.
///
/// The overlay surface is divided into 8 anchored regions around the viewport perimeter.
/// Multiple items can occupy the same anchor; they stack according to their priority.
public enum ViewportOverlayAnchor: String, CaseIterable, Sendable, Equatable {
    case topLeading
    case top
    case topTrailing
    case leading
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing
}

extension ViewportOverlayAnchor {
    /// The frame alignment corresponding to this anchor.
    public var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .top: return .top
        case .topTrailing: return .topTrailing
        case .leading: return .leading
        case .trailing: return .trailing
        case .bottomLeading: return .bottomLeading
        case .bottom: return .bottom
        case .bottomTrailing: return .bottomTrailing
        }
    }

    /// Whether this anchor is along the top edge.
    public var isTop: Bool {
        switch self {
        case .topLeading, .top, .topTrailing: return true
        default: return false
        }
    }

    /// Whether this anchor is along the bottom edge.
    public var isBottom: Bool {
        switch self {
        case .bottomLeading, .bottom, .bottomTrailing: return true
        default: return false
        }
    }

    /// Whether this anchor is on a leading/trailing edge.
    public var isVerticalEdge: Bool {
        switch self {
        case .leading, .trailing: return true
        default: return false
        }
    }

    /// The stacking axis for items at this anchor.
    public var stackAxis: Axis {
        switch self {
        case .topLeading, .top, .topTrailing, .bottomLeading, .bottom, .bottomTrailing:
            return .horizontal
        case .leading, .trailing:
            return .vertical
        }
    }
}
