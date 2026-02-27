import RealityKit
import ImageIO
import SwiftUI
import simd
import ComposableArchitecture
import OSLog
#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
#elseif os(iOS) || os(visionOS)
import UIKit
private typealias PlatformColor = UIColor
#endif

private let logger = Logger(subsystem: "RealityKitStageView", category: "Viewport")

public struct RealityKitStageView: View {
    @State private var runtime: RealityKitProvider
    var configuration: RealityKitConfiguration
    var store: StoreOf<StageViewFeature>

    @State private var rootEntity: Entity?
    @State private var iblEntity: Entity?
    @State private var skyboxEntity: Entity?
    @State private var cameraState = ArcballCameraState()
    @State private var selectionHighlightEntity: Entity?
    @State private var outlinedEntityIDs: Set<Entity.ID> = []

    private var environmentRadius: Double {
        let extent = Double(runtime.sceneBounds.maxExtent)
        return Swift.max(1000.0, extent * 10.0)
    }

    public init(store: StoreOf<StageViewFeature>, configuration: RealityKitConfiguration = RealityKitConfiguration()) {
        self._runtime = State(initialValue: RealityKitProvider())
        self.configuration = configuration
        self.store = store
    }

    public var body: some View {
        ZStack {
            RealityView { content in
                let root = makeSceneRoot()
                content.add(root)
                self.rootEntity = root
                runtime.updateRootEntity(root)

                if let entity = runtime.modelEntity {
                    loadModel(entity)
                }
            } update: { content in
                syncIBLState()
                updateCamera(state: cameraState)

                if runtime._resetCameraRequested {
                    resetCameraInternal()
                    Task { @MainActor in runtime._resetCameraRequested = false }
                }
                if runtime._frameSelectionRequested {
                    Task { @MainActor in runtime._frameSelectionRequested = false }
                }
            }
            .overlay {
                if let error = runtime.loadError {
                    errorOverlay(error)
                }
            }

            overlays
        }
        .task {
            for await snapshot in runtime.observeDiscreteState() {
                await MainActor.run {
                    _ = store.send(.discreteStateReceived(snapshot))
                }
            }
        }
        .task(id: store.loadRequestID) {
            guard let command = store.activeLoadCommand else {
                if store.modelURL == nil {
                    await MainActor.run {
                        runtime.teardown()
                    }
                }
                return
            }

            logger.info("Loading model: \(command.url.lastPathComponent, privacy: .public)")
            runtime.setPreserveCameraOnNextLoad(command.preserveCamera)
            do {
                switch command.mode {
                case .fullLoad:
                    try await runtime.load(command.url)
                case .refresh:
                    try await runtime.load(command.url)
                }
                _ = await MainActor.run { store.send(.loadCommandCompleted(command.id)) }
                logger.info("Model loaded successfully")
            } catch {
                _ = await MainActor.run {
                    store.send(.loadCommandFailed(command.id, error.localizedDescription))
                }
                logger.error("Model load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        .onAppear {
            _ = store.send(.viewAppeared)
        }
        .onDisappear {
            _ = store.send(.viewDisappeared)
        }
        .onChange(of: store.selectedPrimPath) { _, newPath in
            Task { @MainActor in
                runtime.setSelection(newPath)
            }
        }
        .onChange(of: store.cameraResetRequestID) { _, requestID in
            guard requestID != nil else { return }
            Task { @MainActor in
                runtime.resetCamera()
            }
        }
        .onChange(of: runtime.modelEntity.map { ObjectIdentifier($0) }) { _, newId in
            if let entity = runtime.modelEntity, newId != nil {
                loadModel(entity)
            }
        }
        .onChange(of: rootEntity.map { ObjectIdentifier($0) }) { _, newId in
            guard newId != nil else { return }
            Task { await updateEnvironment(configuration.environmentMapURL) }
        }
        .onChange(of: runtime.selectedPrimPath) { _, newPath in
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
        .onChange(of: configuration.environmentRotation) { _, newValue in
            updateIBLRotation(newValue)
        }
        .onChange(of: cameraState) { _, newState in
            runtime.updateCameraState(rotation: newState.quaternion, distance: newState.distance)
        }
        .withLiveTransform(store: store, provider: runtime)
        #if os(macOS)
        .modifier(ArcballCameraControls(
            state: $cameraState,
            sceneBounds: runtime.sceneBounds,
            maxDistance: Float(environmentRadius * 0.9)
        ))
        #endif
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    if let path = runtime.nearestMappedPrimPath(from: value.entity) {
                        runtime.userDidPick(path)
                        Task { @MainActor in
                            _ = store.send(.entityPicked(path))
                        }
                    } else {
                        runtime.userDidPick(nil)
                        Task { @MainActor in
                            _ = store.send(.entityPicked(nil))
                        }
                    }
                }
        )
        .gesture(
            SpatialTapGesture()
                .onEnded { _ in
                    runtime.userDidPick(nil)
                    Task { @MainActor in
                        _ = store.send(.entityPicked(nil))
                    }
                }
        )
    }

    @ViewBuilder
    private var overlays: some View {
        GeometryReader { proxy in
            VStack {
                scaleIndicator(viewportWidth: proxy.size.width)
                Spacer()
                HStack {
                    orientationGizmo
                    Spacer()
                }
            }
            .padding(12)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func scaleIndicator(viewportWidth: CGFloat) -> some View {
        let referenceDepthMeters = Double(runtime.cameraDistance)
        if referenceDepthMeters.isFinite, referenceDepthMeters > 0 {
            ScaleIndicatorView(
                referenceDepthMeters: referenceDepthMeters,
                viewportWidthPoints: Double(max(1, viewportWidth)),
                horizontalFOVDegrees: 60
            )
        }
    }

    @ViewBuilder
    private var orientationGizmo: some View {
        if cameraState.quaternion.vector.isFinite {
            OrientationGizmoView(
                cameraRotation: cameraState.quaternion,
                isZUp: runtime.isZUp
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

    @MainActor
    private func makeSceneRoot() -> Entity {
        SelectionOutlineSystem.registerSystem()

        let root = Entity()
        root.name = "SceneRoot"

        let modelAnchor = Entity()
        modelAnchor.name = "ModelAnchor"
        root.addChild(modelAnchor)

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

        if configuration.showGrid {
            let grid = RealityKitGrid.createGridEntity(
                metersPerUnit: configuration.metersPerUnit,
                worldExtent: Double(runtime.sceneBounds.maxExtent) * configuration.metersPerUnit,
                isZUp: configuration.isZUp
            )
            root.addChild(grid)
        }

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

        let ibl = Entity()
        ibl.name = "ImageBasedLight"
        root.addChild(ibl)
        self.iblEntity = ibl

        return root
    }

    @MainActor
    private func loadModel(_ entity: Entity) {
        entity.name = "LoadedModel"
        let preserveCamera = runtime.consumePreserveCameraOnNextLoad()

        let anchor = rootEntity?.findEntity(named: "ModelAnchor")
        anchor?.children.first(where: { $0.name == "LoadedModel" })?.removeFromParent()

        if let modelAnchor = anchor {
            modelAnchor.addChild(entity)

            prepareForPicking(entity)

            if !preserveCamera, rootEntity?.findEntity(named: "MainCamera") != nil {
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

    private func prepareForPicking(_ entity: Entity) {
        markInputTargetsRecursively(entity)
        // Generate collision shapes once for the full subtree.
        entity.generateCollisionShapes(recursive: true)
    }

    private func markInputTargetsRecursively(_ entity: Entity) {
        entity.components.set(InputTargetComponent(allowedInputTypes: .indirect))
        for child in entity.children {
            markInputTargetsRecursively(child)
        }
    }

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

    @MainActor
    private func updateSelectionHighlight(for path: String?) {
        for id in outlinedEntityIDs {
            if let entity = rootEntity?.scene?.findEntity(id: id) {
                entity.components.remove(SelectionOutlineComponent.self)
                if let outlineChild = entity.children.first(where: { $0.name == SelectionOutlineSystem.outlineEntityName }) {
                    outlineChild.removeFromParent()
                }
            }
        }
        outlinedEntityIDs.removeAll()

        selectionHighlightEntity?.removeFromParent()
        selectionHighlightEntity = nil

        guard let path = path, !path.isEmpty else { return }

        guard let target = runtime.entity(for: path) else { return }

        func applyOutline(to entity: Entity) {
            if entity.name == SelectionOutlineSystem.outlineEntityName { return }

            if entity.components.has(ModelComponent.self) {
                entity.components.set(
                    SelectionOutlineComponent(configuration: configuration.outlineConfiguration)
                )
                outlinedEntityIDs.insert(entity.id)
            }
            for child in entity.children {
                applyOutline(to: child)
            }
        }

        applyOutline(to: target)
    }

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

            let options: [String: Any] = [
                kCGImageSourceShouldAllowFloat as String: true,
                kCGImageSourceShouldCache as String: false
            ]

            let resource: EnvironmentResource
            if let dataProvider = CGDataProvider(url: url as CFURL),
               let source = CGImageSourceCreateWithDataProvider(dataProvider, options as CFDictionary),
               let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) {
                resource = try await EnvironmentResource(equirectangular: cgImage, withName: resourceName)
            } else {
                throw NSError(domain: "RealityKitStageView", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage from environment URL"])
            }

            var iblComp = ImageBasedLightComponent(source: .single(resource))
            iblComp.intensityExponent = Float(configuration.environmentExposure)
            iblComp.inheritsRotation = true
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

            if let model = runtime.modelEntity {
                applyIBLReceiver(to: model)
            }
        } catch {
            logger.error("Environment load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private func updateIBLExposure(_ exposure: Float) {
        if let ibl = iblEntity,
           var iblComp = ibl.components[ImageBasedLightComponent.self] {
            iblComp.intensityExponent = exposure
            iblComp.inheritsRotation = true
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

        let orientation: simd_quatf
        if runtime.isZUp {
            let spin = simd_quatf(angle: radians, axis: [0, 0, 1])
            let tilt = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            orientation = spin * tilt
        } else {
            orientation = simd_quatf(angle: radians, axis: [0, 1, 0])
        }

        if let iblEntity {
            iblEntity.transform.rotation = orientation

            if var iblComp = iblEntity.components[ImageBasedLightComponent.self] {
                if !iblComp.inheritsRotation {
                    iblComp.inheritsRotation = true
                }
                iblEntity.components.set(iblComp)
            }
        }

        if let skyboxEntity {
            let axis: SIMD3<Float> = runtime.isZUp ? [0, 0, 1] : [0, 1, 0]
            skyboxEntity.transform.rotation = simd_quatf(angle: radians, axis: axis)
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

fileprivate extension SIMD4 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite && w.isFinite
    }
}
