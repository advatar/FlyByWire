import Foundation
import RealityKit
import UIKit

enum ConnectomeGraphFactory {
    @MainActor
    static func makeEntity() throws -> (ModelEntity, ConnectomeBackbone.Metadata) {
        let backbone = try loadBackbone()
        let nodeLookup = Dictionary(uniqueKeysWithValues: backbone.nodes.enumerated().map { ($0.offset, $0.element) })

        let positiveNodes = backbone.nodes.filter { $0.balance > 0.18 }
        let mixedNodes = backbone.nodes.filter { abs($0.balance) <= 0.18 }
        let inhibitoryNodes = backbone.nodes.filter { $0.balance < -0.18 }
        let excitatoryEdges = backbone.edges.filter { $0.sign > 0 }
        let inhibitoryEdges = backbone.edges.filter { $0.sign < 0 }

        var descriptors: [MeshDescriptor] = []
        var materials: [any Material] = []

        appendDescriptor(
            named: "PositiveNodes",
            descriptor: makeNodeDescriptor(from: positiveNodes),
            material: SimpleMaterial(
                color: UIColor(red: 0.93, green: 0.72, blue: 0.34, alpha: 1.0),
                roughness: 0.18,
                isMetallic: false
            ),
            descriptors: &descriptors,
            materials: &materials
        )

        appendDescriptor(
            named: "MixedNodes",
            descriptor: makeNodeDescriptor(from: mixedNodes),
            material: SimpleMaterial(
                color: UIColor(red: 0.91, green: 0.88, blue: 0.80, alpha: 1.0),
                roughness: 0.3,
                isMetallic: false
            ),
            descriptors: &descriptors,
            materials: &materials
        )

        appendDescriptor(
            named: "InhibitoryNodes",
            descriptor: makeNodeDescriptor(from: inhibitoryNodes),
            material: SimpleMaterial(
                color: UIColor(red: 0.33, green: 0.70, blue: 0.78, alpha: 1.0),
                roughness: 0.16,
                isMetallic: false
            ),
            descriptors: &descriptors,
            materials: &materials
        )

        appendDescriptor(
            named: "ExcitatoryEdges",
            descriptor: makeEdgeDescriptor(from: excitatoryEdges, nodeLookup: nodeLookup),
            material: SimpleMaterial(
                color: UIColor(red: 0.98, green: 0.58, blue: 0.26, alpha: 1.0),
                roughness: 0.12,
                isMetallic: false
            ),
            descriptors: &descriptors,
            materials: &materials
        )

        appendDescriptor(
            named: "InhibitoryEdges",
            descriptor: makeEdgeDescriptor(from: inhibitoryEdges, nodeLookup: nodeLookup),
            material: SimpleMaterial(
                color: UIColor(red: 0.22, green: 0.86, blue: 0.70, alpha: 1.0),
                roughness: 0.12,
                isMetallic: false
            ),
            descriptors: &descriptors,
            materials: &materials
        )

        let mesh = try MeshResource.generate(from: descriptors)
        let entity = ModelEntity(mesh: mesh, materials: materials)
        entity.components.set(InputTargetComponent())
        entity.components.set(HoverEffectComponent())
        return (entity, backbone.metadata)
    }

    private static func loadBackbone() throws -> ConnectomeBackbone {
        guard let url = Bundle.main.url(forResource: "ConnectivityBackbone", withExtension: "json") else {
            throw ConnectomeGraphError.missingBackboneAsset
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.connectomeBackbone.decode(ConnectomeBackbone.self, from: data)
    }

    private static func appendDescriptor(
        named: String,
        descriptor: MeshDescriptor?,
        material: any Material,
        descriptors: inout [MeshDescriptor],
        materials: inout [any Material]
    ) {
        guard var descriptor else { return }
        descriptor.name = named
        descriptors.append(descriptor)
        materials.append(material)
    }

    private static func makeNodeDescriptor(from nodes: [ConnectomeBackbone.Node]) -> MeshDescriptor? {
        guard !nodes.isEmpty else { return nil }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        positions.reserveCapacity(nodes.count * 24)
        normals.reserveCapacity(nodes.count * 24)
        indices.reserveCapacity(nodes.count * 36)

        for node in nodes {
            let size = 0.0045 + node.degreeNorm * 0.012
            appendAxisAlignedBox(
                center: node.simdPosition * 0.28,
                size: SIMD3<Float>(repeating: size),
                positions: &positions,
                normals: &normals,
                indices: &indices
            )
        }

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }

    private static func makeEdgeDescriptor(
        from edges: [ConnectomeBackbone.Edge],
        nodeLookup: [Int: ConnectomeBackbone.Node]
    ) -> MeshDescriptor? {
        guard !edges.isEmpty else { return nil }

        let maxWeight = edges.map(\.weight).max() ?? 1
        let logDenominator = log(maxWeight + 1)

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        positions.reserveCapacity(edges.count * 24)
        normals.reserveCapacity(edges.count * 24)
        indices.reserveCapacity(edges.count * 36)

        for edge in edges {
            guard let source = nodeLookup[edge.source], let target = nodeLookup[edge.target] else {
                continue
            }

            let start = source.simdPosition * 0.28
            let end = target.simdPosition * 0.28
            let normalizedWeight = log(edge.weight + 1) / max(logDenominator, 0.0001)
            let thickness = 0.001 + normalizedWeight * 0.0032

            appendOrientedBox(
                start: start,
                end: end,
                thickness: thickness,
                positions: &positions,
                normals: &normals,
                indices: &indices
            )
        }

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }

    private static func appendAxisAlignedBox(
        center: SIMD3<Float>,
        size: SIMD3<Float>,
        positions: inout [SIMD3<Float>],
        normals: inout [SIMD3<Float>],
        indices: inout [UInt32]
    ) {
        let hx = size.x * 0.5
        let hy = size.y * 0.5
        let hz = size.z * 0.5

        let corners: [SIMD3<Float>] = [
            center + SIMD3(-hx, -hy, -hz),
            center + SIMD3(hx, -hy, -hz),
            center + SIMD3(hx, hy, -hz),
            center + SIMD3(-hx, hy, -hz),
            center + SIMD3(-hx, -hy, hz),
            center + SIMD3(hx, -hy, hz),
            center + SIMD3(hx, hy, hz),
            center + SIMD3(-hx, hy, hz)
        ]

        appendBoxFaces(
            corners: corners,
            basisNormals: [
                SIMD3(0, 0, 1),
                SIMD3(0, 0, -1),
                SIMD3(-1, 0, 0),
                SIMD3(1, 0, 0),
                SIMD3(0, 1, 0),
                SIMD3(0, -1, 0)
            ],
            positions: &positions,
            normals: &normals,
            indices: &indices
        )
    }

    private static func appendOrientedBox(
        start: SIMD3<Float>,
        end: SIMD3<Float>,
        thickness: Float,
        positions: inout [SIMD3<Float>],
        normals: inout [SIMD3<Float>],
        indices: inout [UInt32]
    ) {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0.0001 else { return }

        let forward = simd_normalize(delta)
        var reference = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(forward, reference)) > 0.92 {
            reference = SIMD3<Float>(1, 0, 0)
        }
        let right = simd_normalize(simd_cross(reference, forward))
        let up = simd_normalize(simd_cross(forward, right))
        let center = (start + end) * 0.5
        let halfThickness = thickness * 0.5
        let halfLength = length * 0.5

        let corners: [SIMD3<Float>] = [
            center - right * halfThickness - up * halfThickness - forward * halfLength,
            center + right * halfThickness - up * halfThickness - forward * halfLength,
            center + right * halfThickness + up * halfThickness - forward * halfLength,
            center - right * halfThickness + up * halfThickness - forward * halfLength,
            center - right * halfThickness - up * halfThickness + forward * halfLength,
            center + right * halfThickness - up * halfThickness + forward * halfLength,
            center + right * halfThickness + up * halfThickness + forward * halfLength,
            center - right * halfThickness + up * halfThickness + forward * halfLength
        ]

        appendBoxFaces(
            corners: corners,
            basisNormals: [forward, -forward, -right, right, up, -up],
            positions: &positions,
            normals: &normals,
            indices: &indices
        )
    }

    private static func appendBoxFaces(
        corners: [SIMD3<Float>],
        basisNormals: [SIMD3<Float>],
        positions: inout [SIMD3<Float>],
        normals: inout [SIMD3<Float>],
        indices: inout [UInt32]
    ) {
        let faces: [([Int], SIMD3<Float>)] = [
            ([4, 5, 6, 7], basisNormals[0]),
            ([1, 0, 3, 2], basisNormals[1]),
            ([0, 4, 7, 3], basisNormals[2]),
            ([5, 1, 2, 6], basisNormals[3]),
            ([3, 7, 6, 2], basisNormals[4]),
            ([0, 1, 5, 4], basisNormals[5])
        ]

        for (faceCorners, normal) in faces {
            let baseIndex = UInt32(positions.count)
            for cornerIndex in faceCorners {
                positions.append(corners[cornerIndex])
                normals.append(normal)
            }
            indices += [
                baseIndex, baseIndex + 1, baseIndex + 2,
                baseIndex, baseIndex + 2, baseIndex + 3
            ]
        }
    }
}

private enum ConnectomeGraphError: LocalizedError {
    case missingBackboneAsset

    var errorDescription: String? {
        switch self {
        case .missingBackboneAsset:
            return "The bundled `ConnectivityBackbone.json` asset could not be found."
        }
    }
}
