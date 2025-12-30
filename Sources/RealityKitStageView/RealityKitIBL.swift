import CoreGraphics
import RealityKit
import StageViewCore

/// IBL handling with proper exposure conversion (fixes the 10x brightness bug).
public struct RealityKitIBL {
    @MainActor
    public static func applyEnvironment(
        to entity: Entity,
        iblEntity: Entity,
        configuration: IBLConfiguration,
        cgImage: CGImage
    ) async throws {
        let resource = try await EnvironmentResource(
            equirectangular: cgImage,
            withName: configuration.environmentURL?.lastPathComponent ?? "environment"
        )

        var iblComp = ImageBasedLightComponent(source: .single(resource))
        // FIX: Use converted exposure, not raw 1.0!
        iblComp.intensityExponent = configuration.realityKitIntensityExponent
        iblComp.inheritsRotation = true
        iblEntity.components.set(iblComp)

        // Apply receiver to entity hierarchy
        applyIBLReceiver(to: entity, iblEntity: iblEntity)
    }

    @MainActor
    private static func applyIBLReceiver(to entity: Entity, iblEntity: Entity) {
        // Add IBL receiver to root entity
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: iblEntity))

        // Recursively apply to all children
        for child in entity.children {
            applyIBLReceiver(to: child, iblEntity: iblEntity)
        }
    }
}
