import SwiftUI
import AppKit

/// A transparent NSView that captures native macOS events and bridges them to callbacks.
public struct InteractionOverlay: NSViewRepresentable {
    public var onScroll: (NSEvent) -> Void
    public var onMagnify: (NSEvent) -> Void
    
    public init(onScroll: @escaping (NSEvent) -> Void, onMagnify: @escaping (NSEvent) -> Void) {
        self.onScroll = onScroll
        self.onMagnify = onMagnify
    }
    
    public func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        return view
    }
    
    public func updateNSView(_ nsView: EventView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onMagnify = onMagnify
    }
    
    public class EventView: NSView {
        var onScroll: ((NSEvent) -> Void)?
        var onMagnify: ((NSEvent) -> Void)?
        
        public override func scrollWheel(with event: NSEvent) {
            onScroll?(event)
            // Allow event to propagate if needed, but usually we handle it fully here
        }
        
        public override func magnify(with event: NSEvent) {
            onMagnify?(event)
        }
        
        // Ensure the view can receive events
        public override var acceptsFirstResponder: Bool { true }
    }
}
