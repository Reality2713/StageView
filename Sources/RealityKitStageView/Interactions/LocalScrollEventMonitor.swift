import SwiftUI
#if os(macOS)
import AppKit

/// Observes scroll wheel events without inserting a hit-testable view on top of SwiftUI.
///
/// This avoids breaking SwiftUI/RealityKit gestures while still allowing the viewport
/// to consume trackpad/mouse wheel scrolling when the pointer is inside a target view.
@MainActor
final class LocalScrollEventMonitor {
    // `NSEvent` returns an opaque monitor token (`Any`). This is not `Sendable`,
    // and `deinit` is nonisolated, so store it as `nonisolated(unsafe)` so we can
    // remove the monitor during teardown without fighting isolation.
    nonisolated(unsafe) private let monitor: Any?

    init(handler: @escaping (NSEvent) -> NSEvent?) {
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            handler(event)
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

@MainActor
final class LocalMouseEventMonitor {
    nonisolated(unsafe) private let monitor: Any?

    init(handler: @escaping (NSEvent) -> NSEvent?) {
        self.monitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                .rightMouseDown, .rightMouseDragged, .rightMouseUp,
                .otherMouseDown, .otherMouseDragged, .otherMouseUp,
            ]
        ) { event in
            handler(event)
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

/// A non-interactive AppKit view we can use as a geometry anchor for filtering events.
struct EventRegionView: NSViewRepresentable {
    var onResolveView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughNSView()
        DispatchQueue.main.async {
            onResolveView(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolveView(nsView)
        }
    }

    private final class PassthroughNSView: NSView {
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
