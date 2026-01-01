import RealityKit
import StageViewCore
import SwiftUI

/// Main RealityKit viewport implementation conforming to StageViewport protocol.
public struct RealityKitStageView: View {
    @State private var rootEntity: Entity?
    @State private var modelEntity: Entity?
    @State private var iblEntity: Entity?
    @State private var skyboxEntity: Entity?
    @State private var sceneSubscription: (any Sendable)?
    @State private var cameraState = ArcballCameraState()

    // Configuration
    @Binding private var gridConfig: GridConfiguration
    @Binding private var iblConfig: IBLConfiguration

    // Selection
    @Binding private var _selectedPrimPath: String?
    @Binding private var _externalModelEntity: Entity?
    @State private var lastExternalModelId: ObjectIdentifier?
    @State private var selectionHighlightEntity: Entity?
    @Binding private var _loadError: String?

    // Scene info
    private let _sceneBounds: SceneBounds
    private let _metersPerUnit: Double
    private let _isZUp: Bool

    // Callbacks
    private let onModelLoaded: ((Entity) -> Void)?
    private let onBoundsChanged: ((SceneBounds) -> Void)?
    private let onRootReady: ((Entity) -> Void)?

    public init(
        gridConfig: Binding<GridConfiguration>,
        iblConfig: Binding<IBLConfiguration>,
        selectedPrimPath: Binding<String?>,
        modelEntity: Binding<Entity?> = .constant(nil),
        sceneBounds: SceneBounds,
        metersPerUnit: Double,
        isZUp: Bool,
        loadError: Binding<String?> = .constant(nil),
        onModelLoaded: ((Entity) -> Void)? = nil,
        onBoundsChanged: ((SceneBounds) -> Void)? = nil,
        onRootReady: ((Entity) -> Void)? = nil
    ) {
        self._gridConfig = gridConfig
        self._iblConfig = iblConfig
        self.__selectedPrimPath = selectedPrimPath
        self.__externalModelEntity = modelEntity
        self.__loadError = loadError
        self._sceneBounds = sceneBounds
        self._metersPerUnit = metersPerUnit
        self._isZUp = isZUp
        self.onModelLoaded = onModelLoaded
        self.onBoundsChanged = onBoundsChanged
        self.onRootReady = onRootReady
    }

    public var body: some View {
        ZStack {
            RealityView { content in
                let root = makeSceneRoot()
                content.add(root)
                self.rootEntity = root
                setupSubscriptions(for: root)
                
                if let entity = _externalModelEntity {
                    loadModel(entity)
                    syncRenderInfo()
                }
            } update: { content in
                // Handle dynamic updates
            }
            .overlay {
                if let error = _loadError {
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
                
                VStack {
                    HStack {
                        Spacer()
                        // Use a default camera distance based on scene bounds
                        ScaleIndicatorView(
                            cameraDistance: Double(_sceneBounds.maxExtent) * _metersPerUnit * 2.0
                        )
                        .padding()
                    }
                    Spacer()
                }
            }
        }
        .onChange(of: _externalModelEntity.map { ObjectIdentifier($0) }) { _, newId in
            if let entity = _externalModelEntity, newId != nil {
                loadModel(entity)
                syncRenderInfo()
                lastExternalModelId = newId
            }
        }
        .onChange(of: _selectedPrimPath) { _, newPath in
            updateSelectionHighlight(for: newPath)
        }
        .onChange(of: gridConfig) { _, newConfig in
            updateGrid(configuration: newConfig)
        }
        .onChange(of: iblConfig) { oldValue, newConfig in
            if oldValue.environmentURL != newConfig.environmentURL {
                Task { await updateEnvironment(newConfig.environmentURL) }
            } else if oldValue.exposure != newConfig.exposure {
                updateIBLExposure(newConfig.exposure)
            } else if oldValue.rotation != newConfig.rotation {
                updateIBLRotation(newConfig.rotation)
            }
        }
        .onChange(of: cameraState) { _, newState in
            updateCamera(state: newState)
        }
        .modifier(ArcballCameraControls(state: $cameraState, sceneBounds: _sceneBounds))
    }

    @MainActor
    private func makeSceneRoot() -> Entity {
        let root = Entity()
        root.name = "SceneRoot"

        // Model Anchor (for loading models)
        let modelAnchor = Entity()
        modelAnchor.name = "ModelAnchor"
        root.addChild(modelAnchor)

        // Lights
        let light = DirectionalLight()
        light.light.intensity = 2000
        light.light.color = .white
        light.look(at: .zero, from: [2, 4, 5], relativeTo: nil)
        root.addChild(light)

        let fillLight = DirectionalLight()
        fillLight.light.intensity = 1000
        fillLight.look(at: .zero, from: [-2, 2, -3], relativeTo: nil)
        root.addChild(fillLight)

        // Grid (using the new RealityKitGrid)
        let grid = RealityKitGrid.createGridEntity(
            metersPerUnit: _metersPerUnit,
            worldExtent: Double(_sceneBounds.maxExtent) * _metersPerUnit,
            isZUp: _isZUp
        )
        root.addChild(grid)

        // Camera (for gizmo orientation tracking)
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

        onRootReady?(root)
        return root
    }

    @MainActor
    private func setupSubscriptions(for root: Entity) {
        // Removing Scene.Update subscription that was causing infinite render loops
    }

    @MainActor
    private func syncRenderInfo() {
        guard let root = rootEntity, let model = modelEntity else { return }

        let bounds = model.visualBounds(relativeTo: nil)
        let newBounds = SceneBounds(
            min: bounds.min,
            max: bounds.max
        )

        onBoundsChanged?(newBounds)
    }

    @MainActor
    private func updateGrid(configuration: GridConfiguration) {
        guard let root = rootEntity else { return }

        // Remove existing grid
        root.findEntity(named: "ReferenceGrid")?.removeFromParent()

        // Add new grid
        let grid = RealityKitGrid.createGridEntity(
            metersPerUnit: configuration.metersPerUnit,
            worldExtent: configuration.worldExtent,
            isZUp: _isZUp
        )
        root.addChild(grid)
    }

    @MainActor
    private func updateSelectionHighlight(for path: String?) {
        selectionHighlightEntity?.removeFromParent()
        selectionHighlightEntity = nil

        guard let path = path, let model = modelEntity else { return }

        // Simple name-based search
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

    @MainActor
    private func updateCamera(state: ArcballCameraState) {
        guard let camera = rootEntity?.findEntity(named: "MainCamera") else { return }
        camera.transform.matrix = state.transform
    }

    // MARK: - Environment & IBL

    @MainActor
    private func updateEnvironment(_ url: URL?) async {
        guard let ibl = iblEntity else { return }

        // Remove existing IBL component
        ibl.components.remove(ImageBasedLightComponent.self)
        skyboxEntity?.removeFromParent()
        skyboxEntity = nil

        guard let url = url else {
            return
        }

        do {
            // Load the HDR as a CGImage first, then generate EnvironmentResource (macOS 15+)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                print("[RealityKitStageView] ❌ Failed to create CGImage from: \(url.path)")
                return
            }
            let resource = try await EnvironmentResource(equirectangular: cgImage, withName: url.lastPathComponent)

            var iblComp = ImageBasedLightComponent(source: .single(resource))
            iblComp.intensityExponent = iblConfig.realityKitIntensityExponent
            ibl.components.set(iblComp)

            // Skybox Sphere
            let skybox = Entity()
            skybox.name = "SkyboxSphere"
            
            let texture = try await TextureResource.generate(from: cgImage, options: .init(semantic: .color))
            var material = UnlitMaterial()
            material.color = .init(texture: .init(texture))
            
            skybox.components.set(ModelComponent(
                mesh: .generateSphere(radius: 1000),
                materials: [material]
            ))
            
            // Flip sphere inward
            skybox.scale *= .init(x: -1, y: 1, z: 1)
            
            rootEntity?.addChild(skybox)
            self.skyboxEntity = skybox

            updateIBLRotation(iblConfig.rotation)
            
            // Ensure model receives IBL
            if let model = modelEntity {
                applyIBLReceiver(to: model)
            }
            
            print("[RealityKitStageView] ✅ Environment updated: \(url.lastPathComponent)")
        } catch {
            print("[RealityKitStageView] ❌ Environment load failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func updateIBLExposure(_ exposure: Float) {
        guard let ibl = iblEntity,
              var iblComp = ibl.components[ImageBasedLightComponent.self] else { return }
        iblComp.intensityExponent = iblConfig.realityKitIntensityExponent
        ibl.components.set(iblComp)
    }

    @MainActor
    private func updateIBLRotation(_ degrees: Float) {
        let axis: SIMD3<Float> = _isZUp ? [0, 0, 1] : [0, 1, 0]
        let radians = degrees * .pi / 180.0
        let orientation = simd_quatf(angle: radians, axis: axis)
        
        iblEntity?.orientation = orientation
        skyboxEntity?.orientation = orientation
    }

    private func applyIBLReceiver(to entity: Entity) {
        guard let ibl = iblEntity else { return }
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl))
        for child in entity.children {
            applyIBLReceiver(to: child)
        }
    }

    // MARK: - Public API for loading models

    @MainActor
    public func loadModel(_ entity: Entity) {
        self.modelEntity = entity
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

                // Calculate distance to fit in view (assuming ~60 deg FOV)
                let fov: Float = 60.0 * .pi / 180.0
                let tanFov = tan(fov / 2.0)
                let distance = maxDim / (2.0 * tanFov)

                // Lower the clamp significantly for small models
                let clampedDistance = max(distance, 0.05)

                // Update Camera State
                var newState = cameraState
                newState.focus = center
                newState.distance = clampedDistance * 1.5
                // Reset rotation to default
                newState.rotation = SIMD3<Float>(-20 * .pi / 180, 0, 0)
                cameraState = newState 
            }

            onModelLoaded?(entity)
            applyIBLReceiver(to: entity)
        }
    }
}

// MARK: - StageViewport Conformance

extension RealityKitStageView: @preconcurrency StageViewport {
    public var gridConfiguration: GridConfiguration {
        get { gridConfig }
        set { gridConfig = newValue }
    }

    public var iblConfiguration: IBLConfiguration {
        get { iblConfig }
        set { iblConfig = newValue }
    }

    public var sceneBounds: StageViewCore.SceneBounds {
        return _sceneBounds
    }

    public var metersPerUnit: Double {
        return _metersPerUnit
    }

    public var isZUp: Bool {
        return _isZUp
    }

    public var selectedPrimPath: String? {
        get { _selectedPrimPath }
        set { _selectedPrimPath = newValue }
    }

    @MainActor
    public func resetCamera() {
        // Reset to default
        cameraState = ArcballCameraState(focus: .zero, rotation: SIMD3<Float>(-20 * .pi / 180, 0, 0), distance: 5.0)
    }

    @MainActor
    public func frameSelection(primPath: String?) {
        // TODO: Implement selection framing
    }
}
