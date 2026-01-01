import RealityKit
import StageViewCore
import SwiftUI

/// Main RealityKit viewport implementation conforming to StageViewport protocol.
public struct RealityKitStageView: View {
    @State private var rootEntity: Entity?
    @State private var modelEntity: Entity?
    @State private var iblEntity: Entity?
    @State private var sceneSubscription: (any Sendable)?

    // Configuration
    @Binding private var gridConfig: GridConfiguration
    @Binding private var iblConfig: IBLConfiguration

    // Selection
    @Binding private var _selectedPrimPath: String?
    @Binding private var _externalModelEntity: Entity?
    @State private var lastExternalModelId: ObjectIdentifier?
    @State private var selectionHighlightEntity: Entity?

    // Scene info
    private let _sceneBounds: SceneBounds
    private let _metersPerUnit: Double
    private let _isZUp: Bool

    // Callbacks
    private let onModelLoaded: ((Entity) -> Void)?
    private let onBoundsChanged: ((SceneBounds) -> Void)?

    public init(
        gridConfig: Binding<GridConfiguration>,
        iblConfig: Binding<IBLConfiguration>,
        selectedPrimPath: Binding<String?>,
        modelEntity: Binding<Entity?> = .constant(nil),
        sceneBounds: SceneBounds,
        metersPerUnit: Double,
        isZUp: Bool,
        onModelLoaded: ((Entity) -> Void)? = nil,
        onBoundsChanged: ((SceneBounds) -> Void)? = nil
    ) {
        self._gridConfig = gridConfig
        self._iblConfig = iblConfig
        self.__selectedPrimPath = selectedPrimPath
        self.__externalModelEntity = modelEntity
        self._sceneBounds = sceneBounds
        self._metersPerUnit = metersPerUnit
        self._isZUp = isZUp
        self.onModelLoaded = onModelLoaded
        self.onBoundsChanged = onBoundsChanged
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
        .onChange(of: iblConfig) { _, newConfig in
            // Handle IBL config changes if needed
        }
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

                // Position camera relative to model center
                let newPos: SIMD3<Float> = [
                    center.x,
                    center.y + clampedDistance * 0.4, // Slight offset up
                    center.z + Float(clampedDistance * 1.5),
                ]

                camera.look(at: center, from: newPos, relativeTo: nil)
            }

            onModelLoaded?(entity)
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
        guard let camera = rootEntity?.findEntity(named: "MainCamera") else { return }
        camera.position = [0, 1, 2]
        camera.look(at: .zero, from: [0, 1, 2], relativeTo: nil)
    }

    @MainActor
    public func frameSelection(primPath: String?) {
        // TODO: Implement selection framing
    }
}
