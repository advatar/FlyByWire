import Foundation
import RealityKit
import UIKit

enum BundledMeshAssetFactory {
    @MainActor
    static func makeEntity(resource: String) throws -> (ModelEntity, MeshCollectionAsset.Metadata) {
        let asset = try loadAsset(resource: resource)

        var descriptors: [MeshDescriptor] = []
        var materials: [any Material] = []

        for part in asset.parts {
            guard let descriptor = makeDescriptor(from: part) else { continue }
            descriptors.append(descriptor)
            materials.append(
                SimpleMaterial(
                    color: uiColor(from: part.color),
                    roughness: 0.22,
                    isMetallic: false
                )
            )
        }

        let mesh = try MeshResource.generate(from: descriptors)
        let entity = ModelEntity(mesh: mesh, materials: materials)
        entity.components.set(InputTargetComponent())
        entity.components.set(HoverEffectComponent())
        return (entity, asset.metadata)
    }

    private static func loadAsset(resource: String) throws -> MeshCollectionAsset {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
            throw MeshCollectionError.missingAsset(resource)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.connectomeBackbone.decode(MeshCollectionAsset.self, from: data)
    }

    private static func makeDescriptor(from part: MeshCollectionAsset.Part) -> MeshDescriptor? {
        guard !part.vertices.isEmpty, !part.faces.isEmpty else { return nil }

        let vertices = part.vertices.map { values in
            SIMD3<Float>(values[0], values[1], values[2])
        }

        var normals = Array(repeating: SIMD3<Float>(repeating: 0), count: vertices.count)
        var indices: [UInt32] = []
        indices.reserveCapacity(part.faces.count * 3)

        for face in part.faces {
            guard face.count == 3 else { continue }
            let i0 = face[0]
            let i1 = face[1]
            let i2 = face[2]
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }

            let edgeA = vertices[i1] - vertices[i0]
            let edgeB = vertices[i2] - vertices[i0]
            let normal = simd_cross(edgeA, edgeB)
            normals[i0] += normal
            normals[i1] += normal
            normals[i2] += normal
            indices += [UInt32(i0), UInt32(i1), UInt32(i2)]
        }

        normals = normals.map { normal in
            let length = simd_length(normal)
            if length > 0.000001 {
                return normal / length
            }
            return SIMD3<Float>(0, 1, 0)
        }

        var descriptor = MeshDescriptor(name: part.name)
        descriptor.positions = MeshBuffers.Positions(vertices)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }

    private static func uiColor(from values: [Float]) -> UIColor {
        let r = CGFloat(values[safe: 0] ?? 0.85)
        let g = CGFloat(values[safe: 1] ?? 0.85)
        let b = CGFloat(values[safe: 2] ?? 0.85)
        let a = CGFloat(values[safe: 3] ?? 1.0)
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}

private enum MeshCollectionError: LocalizedError {
    case missingAsset(String)

    var errorDescription: String? {
        switch self {
        case let .missingAsset(name):
            return "The bundled mesh asset `\(name).json` could not be found."
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
