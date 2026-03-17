import RealityKit
import SwiftUI

@MainActor
@Observable
final class BrainSceneController {
    let root = Entity()
    private let anatomyRoot = Entity()
    private let graphRoot = Entity()
    private let atlasRoot = Entity()
    private let flyWireRoot = Entity()
    private let wholeFlyRoot = Entity()
    private var wholeFlySceneController: FlyWorldSceneController?
    private var wholeFlyMetadataTask: Task<Void, Never>?
    private var anatomyEntity: ModelEntity?
    private var graphEntity: ModelEntity?
    private var atlasEntity: ModelEntity?
    private var flyWireEntity: ModelEntity?
    private(set) var anatomyLoaded = false
    private(set) var graphLoaded = false
    private(set) var atlasLoaded = false
    private(set) var flyWireLoaded = false
    private(set) var wholeFlyLoaded = false
    private(set) var graphMetadata: ConnectomeBackbone.Metadata?
    private(set) var atlasMetadata: MeshCollectionAsset.Metadata?
    private(set) var flyWireMetadata: MeshCollectionAsset.Metadata?
    private(set) var wholeFlyMetadata: FlyWorldSceneMetadata?
    private(set) var errorMessage: String?

    init() {
        root.addChild(anatomyRoot)
        root.addChild(graphRoot)
        root.addChild(atlasRoot)
        root.addChild(flyWireRoot)
        root.addChild(wholeFlyRoot)
        graphRoot.isEnabled = false
        atlasRoot.isEnabled = false
        flyWireRoot.isEnabled = false
        wholeFlyRoot.isEnabled = false
    }

    func loadIfNeeded(for mode: BrainVisualizationMode) async {
        switch mode {
        case .anatomy:
            guard !anatomyLoaded else { return }
            do {
                let entity = try BrainMeshFactory.makeEntity()
                entity.position = .zero
                anatomyRoot.addChild(entity)
                anatomyEntity = entity
                anatomyLoaded = true
            } catch {
                errorMessage = "Unable to build anatomy mesh: \(error.localizedDescription)"
                let fallback = ModelEntity(
                    mesh: .generateSphere(radius: 0.06),
                    materials: [SimpleMaterial(color: .lightGray, roughness: 0.5, isMetallic: false)]
                )
                fallback.position = .zero
                anatomyRoot.addChild(fallback)
                anatomyEntity = fallback
                anatomyLoaded = true
            }

        case .graph:
            guard !graphLoaded else { return }
            do {
                let (entity, metadata) = try ConnectomeGraphFactory.makeEntity()
                entity.position = .zero
                graphRoot.addChild(entity)
                graphEntity = entity
                graphMetadata = metadata
                graphLoaded = true
            } catch {
                errorMessage = "Unable to build connectome graph: \(error.localizedDescription)"
                let fallback = ModelEntity(
                    mesh: .generateBox(size: 0.08),
                    materials: [SimpleMaterial(color: .lightGray, roughness: 0.4, isMetallic: false)]
                )
                fallback.position = .zero
                graphRoot.addChild(fallback)
                graphEntity = fallback
                graphLoaded = true
            }

        case .atlas:
            guard !atlasLoaded else { return }
            do {
                let (entity, metadata) = try BundledMeshAssetFactory.makeEntity(resource: "AtlasMesh")
                atlasRoot.addChild(entity)
                atlasEntity = entity
                atlasMetadata = metadata
                atlasLoaded = true
            } catch {
                errorMessage = "Unable to build atlas mesh: \(error.localizedDescription)"
                let fallback = ModelEntity(
                    mesh: .generateSphere(radius: 0.06),
                    materials: [SimpleMaterial(color: .lightGray, roughness: 0.4, isMetallic: false)]
                )
                atlasRoot.addChild(fallback)
                atlasEntity = fallback
                atlasLoaded = true
            }

        case .flywire:
            guard !flyWireLoaded else { return }
            do {
                let (entity, metadata) = try BundledMeshAssetFactory.makeEntity(resource: "FlyWireMeshes")
                flyWireRoot.addChild(entity)
                flyWireEntity = entity
                flyWireMetadata = metadata
                flyWireLoaded = true
            } catch {
                errorMessage = "Unable to build FlyWire meshes: \(error.localizedDescription)"
                let fallback = ModelEntity(
                    mesh: .generateBox(size: 0.08),
                    materials: [SimpleMaterial(color: .lightGray, roughness: 0.4, isMetallic: false)]
                )
                flyWireRoot.addChild(fallback)
                flyWireEntity = fallback
                flyWireLoaded = true
            }

        case .wholeFly:
            guard !wholeFlyLoaded else { return }
            let sceneController = FlyWorldSceneController()
            sceneController.loadIfNeeded()
            sceneController.startPoseUpdates()
            wholeFlyRoot.addChild(sceneController.root)
            wholeFlySceneController = sceneController
            wholeFlyMetadata = sceneController.metadata
            startWholeFlyMetadataMirroring()
            wholeFlyLoaded = true
        }
    }

    func setMode(_ mode: BrainVisualizationMode) {
        anatomyRoot.isEnabled = mode == .anatomy
        graphRoot.isEnabled = mode == .graph
        atlasRoot.isEnabled = mode == .atlas
        flyWireRoot.isEnabled = mode == .flywire
        wholeFlyRoot.isEnabled = mode == .wholeFly
    }

    func updateTransform(
        uniformScale: Float,
        depthScale: Float,
        mode: BrainVisualizationMode
    ) {
        anatomyRoot.scale = [uniformScale, uniformScale, uniformScale * depthScale]
        anatomyRoot.orientation = simd_quatf(angle: -.pi / 10, axis: [1, 0, 0])

        graphRoot.scale = [uniformScale, uniformScale, uniformScale]
        graphRoot.orientation =
            simd_quatf(angle: .pi / 9, axis: [0, 1, 0])
            * simd_quatf(angle: -.pi / 12, axis: [1, 0, 0])

        atlasRoot.scale = [uniformScale * 0.34, uniformScale * 0.34, uniformScale * 0.34]
        atlasRoot.orientation =
            simd_quatf(angle: .pi / 10, axis: [0, 1, 0])
            * simd_quatf(angle: -.pi / 14, axis: [1, 0, 0])
        atlasRoot.position = .zero

        flyWireRoot.scale = [uniformScale * 0.36, uniformScale * 0.36, uniformScale * 0.36]
        flyWireRoot.orientation =
            simd_quatf(angle: -.pi / 8, axis: [0, 1, 0])
            * simd_quatf(angle: -.pi / 14, axis: [1, 0, 0])
        flyWireRoot.position = .zero

        wholeFlyRoot.scale = [uniformScale * 0.22, uniformScale * 0.22, uniformScale * 0.22]
        wholeFlyRoot.position = [0.0, -0.28, 0.0]
        wholeFlyRoot.orientation = simd_quatf(angle: 0.2, axis: [0, 1, 0])

        setMode(mode)
    }

    private func startWholeFlyMetadataMirroring() {
        wholeFlyMetadataTask?.cancel()
        wholeFlyMetadataTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let sceneController = self.wholeFlySceneController else { return }
                self.wholeFlyMetadata = sceneController.metadata
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    return
                }
            }
        }
    }
}
