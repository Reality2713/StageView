import RealityKit
import SwiftUI

#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
#elseif os(iOS) || os(visionOS)
import UIKit
private typealias PlatformColor = UIColor
#endif

/// Factory for creating the outline material.
enum OutlineMaterial {
    /// Creates an unlit material that renders only back-faces,
    /// producing an inverted-hull outline when the entity is scaled up.
    static func make(configuration: OutlineConfiguration) throws -> any RealityKit.Material {
        var material = UnlitMaterial()
        
        // Convert SwiftUI Color to platform color, then extract RGBA
        let resolved = configuration.color.resolve(in: EnvironmentValues())
        let r = Float(resolved.red)
        let g = Float(resolved.green)
        let b = Float(resolved.blue)
        
        material.color = .init(
            tint: PlatformColor(
                red: CGFloat(r),
                green: CGFloat(g),
                blue: CGFloat(b),
                alpha: 1.0
            )
        )
        material.faceCulling = .front
        return material
    }
}
