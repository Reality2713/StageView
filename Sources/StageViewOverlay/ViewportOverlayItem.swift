import SwiftUI

/// A viewport overlay item with anchored positioning and priority-based stacking.
///
/// Items sharing the same anchor are sorted by priority (higher = closer to viewport edge).
/// For example, at `.bottomLeading`, higher priority items sit closer to the corner.
public struct ViewportOverlayItem: Identifiable, Sendable {
    public let id: UUID
    public let anchor: ViewportOverlayAnchor
    public let priority: Int
    public let role: ViewportOverlayRole
    
    /// Storage for accessory content (host/domain accessories only).
    /// Uses unchecked sendable wrapper because AnyView is not Sendable.
    let content: UncheckedAnyViewBox?
    
    public init(
        id: UUID = UUID(),
        anchor: ViewportOverlayAnchor,
        priority: Int = 0,
        role: ViewportOverlayRole,
        content: UncheckedAnyViewBox? = nil
    ) {
        self.id = id
        self.anchor = anchor
        self.priority = priority
        self.role = role
        self.content = content
    }
}

/// A wrapper that allows AnyView to be used in Sendable contexts.
///
/// This is safe because the view is only accessed on the main actor.
public final class UncheckedAnyViewBox: @unchecked Sendable {
    public let view: AnyView
    
    public init<V: View>(_ view: V) {
        self.view = AnyView(view)
    }
}

/// Identifies the role of an overlay item for coordination and styling.
public enum ViewportOverlayRole: Sendable, Equatable {
    /// Built-in orientation gizmo.
    case orientationGizmo
    
    /// Built-in scale indicator.
    case scaleIndicator
    
    /// Host-provided accessory (e.g., renderer badge).
    case hostAccessory
    
    /// Domain-specific accessory (e.g., variant picker from Variety).
    case domainAccessory
}

/// A collection of overlay items grouped for coordinated layout.
public struct ViewportOverlayCollection: Sendable {
    public var items: [ViewportOverlayItem]
    
    public init(items: [ViewportOverlayItem] = []) {
        self.items = items
    }
    
    public static let empty = ViewportOverlayCollection()
    
    /// Adds a built-in orientation gizmo at the specified anchor.
    public func orientationGizmo(
        anchor: ViewportOverlayAnchor = .bottomLeading,
        priority: Int = 0
    ) -> Self {
        var copy = self
        copy.items.append(ViewportOverlayItem(
            anchor: anchor,
            priority: priority,
            role: .orientationGizmo
        ))
        return copy
    }
    
    /// Adds a built-in scale indicator at the specified anchor.
    public func scaleIndicator(
        anchor: ViewportOverlayAnchor = .top,
        priority: Int = 0
    ) -> Self {
        var copy = self
        copy.items.append(ViewportOverlayItem(
            anchor: anchor,
            priority: priority,
            role: .scaleIndicator
        ))
        return copy
    }
    
    /// Adds a host-provided accessory with content at the specified anchor.
    public func hostAccessory<V: View>(
        anchor: ViewportOverlayAnchor,
        priority: Int = 0,
        @ViewBuilder content: () -> V
    ) -> Self {
        var copy = self
        copy.items.append(ViewportOverlayItem(
            anchor: anchor,
            priority: priority,
            role: .hostAccessory,
            content: UncheckedAnyViewBox(content())
        ))
        return copy
    }
    
    /// Adds a domain-specific accessory with content at the specified anchor.
    public func domainAccessory<V: View>(
        anchor: ViewportOverlayAnchor,
        priority: Int = 0,
        @ViewBuilder content: () -> V
    ) -> Self {
        var copy = self
        copy.items.append(ViewportOverlayItem(
            anchor: anchor,
            priority: priority,
            role: .domainAccessory,
            content: UncheckedAnyViewBox(content())
        ))
        return copy
    }

    // MARK: - Legacy Compatibility (without content)

    /// Adds a host-provided accessory without content (legacy API).
    /// Content must be provided via the `accessoryContent` closure in the container.
    @available(*, deprecated, message: "Use hostAccessory with content closure")
    public func hostAccessory(
        anchor: ViewportOverlayAnchor,
        priority: Int = 0
    ) -> Self {
        var copy = self
        copy.items.append(ViewportOverlayItem(
            anchor: anchor,
            priority: priority,
            role: .hostAccessory,
            content: nil
        ))
        return copy
    }

    /// Adds a domain-specific accessory without content (legacy API).
    /// Content must be provided via the `accessoryContent` closure in the container.
    @available(*, deprecated, message: "Use domainAccessory with content closure")
    public func domainAccessory(
        anchor: ViewportOverlayAnchor,
        priority: Int = 0
    ) -> Self {
        var copy = self
        copy.items.append(ViewportOverlayItem(
            anchor: anchor,
            priority: priority,
            role: .domainAccessory,
            content: nil
        ))
        return copy
    }

    // MARK: - Internal API for Migration

    /// Creates a host accessory with pre-built content (for migration from legacy slots).
    func hostAccessory(anchor: ViewportOverlayAnchor, priority: Int = 0, content: UncheckedAnyViewBox) -> Self {
        var copy = self
        copy.items.append(ViewportOverlayItem(
            anchor: anchor,
            priority: priority,
            role: .hostAccessory,
            content: content
        ))
        return copy
    }

    /// Returns items grouped by anchor.
    public func groupedByAnchor() -> [ViewportOverlayAnchor: [ViewportOverlayItem]] {
        Dictionary(grouping: items) { $0.anchor }
    }
    
    /// Returns items grouped by anchor, sorted by priority for display.
    /// For trailing anchors, lower priority is closer to the edge to maintain
    /// correct visual ordering when aligned to the trailing edge.
    public func groupedAndSortedForDisplay() -> [ViewportOverlayAnchor: [ViewportOverlayItem]] {
        Dictionary(grouping: items) { $0.anchor }
            .mapValues { items in
                items.sorted { lhs, rhs in
                    // For trailing anchors, reverse the sort so lower priority
                    // items end up closer to the edge when aligned trailing
                    let isTrailing = lhs.anchor.alignment == .topTrailing ||
                                    lhs.anchor.alignment == .bottomTrailing ||
                                    lhs.anchor.alignment == .trailing
                    return isTrailing ? lhs.priority < rhs.priority : lhs.priority > rhs.priority
                }
            }
    }
}