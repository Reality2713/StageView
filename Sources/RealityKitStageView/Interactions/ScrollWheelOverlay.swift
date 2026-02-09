import SwiftUI
#if os(macOS)
import AppKit

public struct ScrollWheelOverlay: NSViewRepresentable {
    public var onScrollPan: (Float, Float) -> Void
    public var onScrollZoom: (Float) -> Void

    public init(
        onScrollPan: @escaping (Float, Float) -> Void = { _, _ in },
        onScrollZoom: @escaping (Float) -> Void = { _ in }
    ) {
        self.onScrollPan = onScrollPan
        self.onScrollZoom = onScrollZoom
    }

    public func makeNSView(context: Context) -> ScrollView {
        let view = ScrollView()
        view.onScrollPan = onScrollPan
        view.onScrollZoom = onScrollZoom
        return view
    }

    public func updateNSView(_ nsView: ScrollView, context: Context) {
        nsView.onScrollPan = onScrollPan
        nsView.onScrollZoom = onScrollZoom
    }

    public class ScrollView: NSView {
        var onScrollPan: ((Float, Float) -> Void)?
        var onScrollZoom: ((Float) -> Void)?

        public override func scrollWheel(with event: NSEvent) {
            if event.modifierFlags.contains(.option) {
                let sensitivity: Float = 0.005
                let delta = Float(event.scrollingDeltaY) * sensitivity
                onScrollZoom?(delta)
            } else {
                let multiplier: Float = event.modifierFlags.contains(.shift) ? 5.0 : 1.0
                let deltaX = Float(event.scrollingDeltaX) * multiplier
                let deltaY = Float(event.scrollingDeltaY) * multiplier
                onScrollPan?(deltaX, deltaY)
            }
        }

        public override var acceptsFirstResponder: Bool { true }

        // Pass mouse events through so SwiftUI gestures (drag, tap) still work
        public override func mouseDown(with event: NSEvent) { super.mouseDown(with: event) }
        public override func mouseDragged(with event: NSEvent) { super.mouseDragged(with: event) }
        public override func mouseUp(with event: NSEvent) { super.mouseUp(with: event) }
        public override func rightMouseDown(with event: NSEvent) { super.rightMouseDown(with: event) }
        public override func rightMouseDragged(with event: NSEvent) { super.rightMouseDragged(with: event) }
        public override func rightMouseUp(with event: NSEvent) { super.rightMouseUp(with: event) }
    }
}
#endif
