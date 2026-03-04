import CoreGraphics
import RealityKit

/// IBL handling that follows Hydra's EV semantics (linear gain = 2^EV).
public struct RealityKitIBL {
    @MainActor
    public static func applyEnvironment(
        to entity: Entity,
        iblEntity: Entity,
        configuration: RealityKitConfiguration,
        cgImage: CGImage
    ) async throws {
        let resource = try await EnvironmentResource(
            equirectangular: cgImage,
            withName: configuration.environmentMapURL?.lastPathComponent ?? "environment"
        )

        var iblComp = ImageBasedLightComponent(source: .single(resource))
        // Keep parity with Hydra EV model.
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
