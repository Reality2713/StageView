import RealityKit
import SwiftUI
import simd
#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
#elseif os(iOS) || os(visionOS)
import UIKit
private typealias PlatformColor = UIColor
#endif

/// RealityKit viewport using the Provider pattern.
/// The view is stateless - all state lives in the RealityKitProvider.
public struct RealityKitStageView: View {
    /// Observable provider that manages scene state
    @Bindable var provider: RealityKitProvider
    
    /// Configuration for rendering options
    var configuration: RealityKitConfiguration
    
    // Internal state
    @State private var rootEntity: Entity?
    @State private var iblEntity: Entity?
    @State private var skyboxEntity: Entity?
    @State private var cameraState = ArcballCameraState()
    @State private var selectionHighlightEntity: Entity?
    
    private var environmentRadius: Double {
        let extent = Double(provider.sceneBounds.maxExtent)
        return Swift.max(1000.0, extent * 10.0)
    }
    
    public init(
        provider: RealityKitProvider,
        configuration: RealityKitConfiguration = RealityKitConfiguration()
    ) {
        self.provider = provider
        self.configuration = configuration
    }
    
    public var body: some View {
        ZStack {
            RealityView { content in
                let root = makeSceneRoot()
                content.add(root)
                self.rootEntity = root
                provider.updateRootEntity(root)
                
                if let entity = provider.modelEntity {
                    loadModel(entity)
                }
            } update: { content in
                syncIBLState()
                updateCamera(state: cameraState)
                
                // Handle camera requests from provider
                if provider._resetCameraRequested {
                    resetCameraInternal()
                    Task { @MainActor in provider._resetCameraRequested = false }
                }
                if provider._frameSelectionRequested {
                    // Frame selection logic
                    Task { @MainActor in provider._frameSelectionRequested = false }
                }
            }
            .overlay {
                if let error = provider.loadError {
                    errorOverlay(error)
                }
            }
            
            // Overlays
            overlays
        }
        .onChange(of: provider.modelEntity.map { ObjectIdentifier($0) }) { _, newId in
            if let entity = provider.modelEntity, newId != nil {
                loadModel(entity)
            }
        }
        .onChange(of: rootEntity.map { ObjectIdentifier($0) }) { _, newId in
            guard newId != nil else { return }
            Task { await updateEnvironment(configuration.environmentMapURL) }
        }
        .onChange(of: provider.selectedPrimPath) { _, newPath in
            updateSelectionHighlight(for: newPath)
        }
        .onChange(of: configuration.environmentMapURL) { _, newValue in
            Task { await updateEnvironment(newValue) }
        }
        .onChange(of: configuration.showEnvironmentBackground) { _, _ in
            Task { await updateEnvironment(configuration.environmentMapURL) }
        }
        .onChange(of: configuration.environmentExposure) { _, _ in
            updateIBLLightIntensity()
        }
        .onChange(of: cameraState) { _, newState in
            provider.updateCameraState(rotation: newState.quaternion, distance: newState.distance)
        }
        #if os(macOS)
        .modifier(ArcballCameraControls(
            state: $cameraState,
            sceneBounds: provider.sceneBounds,
            maxDistance: Float(environmentRadius * 0.9)
        ))
        #endif
    }
    
    // MARK: - Overlays
    
    @ViewBuilder
    private var overlays: some View {
        VStack {
            HStack {
                Spacer()
                scaleIndicator
            }
            Spacer()
            HStack {
                orientationGizmo
                Spacer()
            }
        }
        .padding(12)
        .allowsHitTesting(false)
    }
    
    @ViewBuilder
    private var scaleIndicator: some View {
        let distance = Double(cameraState.distance) * provider.metersPerUnit
        if distance.isFinite && distance > 0 {
            ScaleIndicatorView(cameraDistance: max(0.001, distance))
        }
    }
    
    @ViewBuilder
    private var orientationGizmo: some View {
        if cameraState.quaternion.vector.isFinite {
            OrientationGizmoView(
                cameraRotation: cameraState.quaternion,
                isZUp: provider.isZUp
            )
        }
    }
    
    @ViewBuilder
    private func errorOverlay(_ error: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("Load Failed")
                .font(.headline)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.regularMaterial)
        .cornerRadius(12)
    }
    
    // MARK: - Scene Setup
    
    @MainActor
    private func makeSceneRoot() -> Entity {
        let root = Entity()
        root.name = "SceneRoot"

        // Model Anchor
        let modelAnchor = Entity()
        modelAnchor.name = "ModelAnchor"
        root.addChild(modelAnchor)

        // Lights
        let light = DirectionalLight()
        light.name = "KeyLight"
        light.light.intensity = 2000
        light.light.color = .white
        light.look(at: .zero, from: [2, 4, 5], relativeTo: nil)
        root.addChild(light)

        let fillLight = DirectionalLight()
        fillLight.name = "FillLight"
        fillLight.light.intensity = 1000
        fillLight.look(at: .zero, from: [-2, 2, -3], relativeTo: nil)
        root.addChild(fillLight)

        // Grid
        if configuration.showGrid {
            let grid = RealityKitGrid.createGridEntity(
                metersPerUnit: configuration.metersPerUnit,
                worldExtent: Double(provider.sceneBounds.maxExtent) * configuration.metersPerUnit,
                isZUp: provider.isZUp
            )
            root.addChild(grid)
        }

        // Camera
        let camera = PerspectiveCamera()
        camera.name = "MainCamera"
        if var component = camera.components[PerspectiveCameraComponent.self] {
            component.near = 0.001
            component.far = 1000.0
            camera.components.set(component)
        }
        camera.position = [0, 1, 2]
        camera.look(at: .zero, from: [0, 1, 2], relativeTo: nil)
        root.addChild(camera)

        // IBL Entity
        let ibl = Entity()
        ibl.name = "ImageBasedLight"
        root.addChild(ibl)
        self.iblEntity = ibl

        return root
    }
    
    // MARK: - Model Loading
    
    @MainActor
    private func loadModel(_ entity: Entity) {
        entity.name = "LoadedModel"

        let anchor = rootEntity?.findEntity(named: "ModelAnchor")
        anchor?.children.first(where: { $0.name == "LoadedModel" })?.removeFromParent()

        if let modelAnchor = anchor {
            modelAnchor.addChild(entity)

            // Dynamic Camera Framing
            if let camera = rootEntity?.findEntity(named: "MainCamera") {
                let bounds = entity.visualBounds(relativeTo: nil)
                let extents = bounds.extents
                let center = bounds.center
                let maxDim = max(extents.x, max(extents.y, extents.z))

                let fov: Float = 60.0 * .pi / 180.0
                let tanFov = tan(fov / 2.0)
                let distance = maxDim / (2.0 * tanFov)
                let clampedDistance = max(distance, 0.05)

                var newState = cameraState
                newState.focus = center
                newState.distance = clampedDistance * 1.5
                newState.rotation = SIMD3<Float>(-20 * .pi / 180, 0, 0)
                cameraState = newState
            }

            applyIBLReceiver(to: entity)
        }
    }
    
    // MARK: - Camera
    
    @MainActor
    private func updateCamera(state: ArcballCameraState) {
        guard let camera = rootEntity?.findEntity(named: "MainCamera") else { return }
        camera.transform.matrix = state.transform
    }
    
    @MainActor
    private func resetCameraInternal() {
        cameraState = ArcballCameraState(
            focus: .zero,
            rotation: SIMD3<Float>(-20 * .pi / 180, 0, 0),
            distance: 5.0
        )
    }
    
    // MARK: - Selection
    
    @MainActor
    private func updateSelectionHighlight(for path: String?) {
        selectionHighlightEntity?.removeFromParent()
        selectionHighlightEntity = nil

        guard let path = path, let model = provider.modelEntity else { return }

        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let components = normalizedPath.split(separator: "/")
        var current: Entity? = model
        for comp in components {
            current = current?.children.first(where: { $0.name == String(comp) })
            if current == nil { break }
        }

        if let target = current {
            let bounds = target.visualBounds(relativeTo: nil)
            let mesh = MeshResource.generateBox(size: bounds.extents)
            var material = UnlitMaterial(color: .cyan)
            material.blending = .transparent(opacity: 0.3)

            let highlight = ModelEntity(mesh: mesh, materials: [material])
            highlight.position = bounds.center
            highlight.name = "SelectionHighlight"
            rootEntity?.addChild(highlight)
            selectionHighlightEntity = highlight
        }
    }
    
    // MARK: - IBL
    
    @MainActor
    private func syncIBLState() {
        updateIBLExposure(configuration.environmentExposure)
        updateIBLRotation(configuration.environmentRotation)
        updateIBLLightIntensity()
    }

    @MainActor
    private func updateEnvironment(_ url: URL?) async {
        guard let ibl = iblEntity else { return }

        ibl.components.remove(ImageBasedLightComponent.self)
        skyboxEntity?.removeFromParent()
        skyboxEntity = nil

        guard let url = url else { return }

        do {
            let resourceName = url.deletingLastPathComponent().lastPathComponent + "_" + url.lastPathComponent
            let resource = try EnvironmentResource.__load(contentsOf: url, withName: resourceName)

            var iblComp = ImageBasedLightComponent(source: .single(resource))
            iblComp.intensityExponent = configuration.realityKitIntensityExponent
            ibl.components.set(iblComp)

            if configuration.showEnvironmentBackground {
                let skybox = Entity()
                skybox.name = "SkyboxSphere"

                let texture = try TextureResource.load(
                    contentsOf: url,
                    withName: resourceName,
                    options: .init(semantic: .color)
                )
                var material = UnlitMaterial()
                material.color = .init(texture: .init(texture))

                let radius = Float(environmentRadius)
                skybox.components.set(ModelComponent(
                    mesh: .generateSphere(radius: radius),
                    materials: [material]
                ))
                skybox.scale *= .init(x: -1, y: 1, z: 1)

                rootEntity?.addChild(skybox)
                self.skyboxEntity = skybox
            }

            updateIBLRotation(configuration.environmentRotation)
            
            if let model = provider.modelEntity {
                applyIBLReceiver(to: model)
            }
        } catch {
            print("[RealityKitStageView] Environment load failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func updateIBLExposure(_ exposure: Float) {
        let exponent = configuration.realityKitIntensityExponent
        
        if let ibl = iblEntity,
           var iblComp = ibl.components[ImageBasedLightComponent.self] {
            iblComp.intensityExponent = exponent
            ibl.components.set(iblComp)
        }
        
        if let skybox = skyboxEntity,
           let model = skybox.components[ModelComponent.self] {
            let intensity = powf(2.0, exposure)
            
            var material = (model.materials.first as? UnlitMaterial) ?? UnlitMaterial()
            let color = PlatformColor(
                red: CGFloat(intensity),
                green: CGFloat(intensity),
                blue: CGFloat(intensity),
                alpha: 1.0
            )
            material.color = .init(tint: color, texture: material.color.texture)
            
            var newModel = model
            newModel.materials = [material]
            skybox.components.set(newModel)
        }
    }

    @MainActor
    private func updateIBLRotation(_ degrees: Float) {
        let radians = degrees * .pi / 180.0
        let spinAxis: SIMD3<Float> = provider.isZUp ? [0, 0, 1] : [0, 1, 0]
        let spin = simd_quatf(angle: radians, axis: spinAxis)
        let baseTilt = provider.isZUp ? simd_quatf(angle: .pi / 2, axis: [1, 0, 0]) : simd_quatf()
        let orientation = simd_normalize(spin * baseTilt)

        if let iblEntity {
            iblEntity.transform.rotation = orientation
        }
        if let skyboxEntity {
            skyboxEntity.transform.rotation = orientation
        }
    }

    private func applyIBLReceiver(to entity: Entity) {
        guard let ibl = iblEntity else { return }
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl))
        for child in entity.children {
            applyIBLReceiver(to: child)
        }
    }

    @MainActor
    private func updateIBLLightIntensity() {
        guard let root = rootEntity else { return }
        let useIBL = configuration.environmentMapURL != nil
        if let key = root.findEntity(named: "KeyLight") as? DirectionalLight {
            key.light.intensity = useIBL ? 0 : 2000
        }
        if let fill = root.findEntity(named: "FillLight") as? DirectionalLight {
            fill.light.intensity = useIBL ? 0 : 1000
        }
    }
}

// MARK: - SIMD Extensions

fileprivate extension SIMD4 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite && w.isFinite
    }
}
