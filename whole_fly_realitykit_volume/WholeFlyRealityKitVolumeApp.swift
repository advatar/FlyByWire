import SwiftUI
import RealityKit
import simd
import UIKit
import Foundation

@main
struct WholeFlyRealityKitVolumeApp: App {
    var body: some Scene {
        WindowGroup {
            WholeFlyVolumeView()
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.2, height: 0.9, depth: 0.8, in: .meters)
        .volumeWorldAlignment(.gravityAligned)
    }
}

struct WholeFlyVolumeView: View {
    var body: some View {
        RealityView { content in
            let fly = FlyFactory.makeWholeFly(brainGraph: BrainGraph.loadPreferredGraph())
            content.add(fly)
        }
    }
}

struct BrainGraph: Decodable {
    struct Node: Decodable {
        let x: Float
        let y: Float
        let z: Float
        let size: Float?
        let color: [Float]?
        let is_focus: Bool?
        let flywire_id: Int64?

        init(
            x: Float,
            y: Float,
            z: Float,
            size: Float? = nil,
            color: [Float]? = nil,
            is_focus: Bool? = nil,
            flywire_id: Int64? = nil
        ) {
            self.x = x
            self.y = y
            self.z = z
            self.size = size
            self.color = color
            self.is_focus = is_focus
            self.flywire_id = flywire_id
        }
    }

    struct Edge: Decodable {
        let source: Int
        let target: Int
        let weight: Float?
        let strength: Float?

        init(source: Int, target: Int, weight: Float? = nil, strength: Float? = nil) {
            self.source = source
            self.target = target
            self.weight = weight
            self.strength = strength
        }
    }

    let nodes: [Node]
    let edges: [Edge]

    init(nodes: [Node], edges: [Edge]) {
        self.nodes = nodes
        self.edges = edges
    }

    static func loadPreferredGraph() -> BrainGraph {
        let fileManager = FileManager.default
        let candidateNames = [
            "flybrain_for_vision_pro",
            "flybrain_p9",
            "flybrain_focus",
            "demo_brain_graph"
        ]

        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            for name in candidateNames {
                let url = documentsURL.appendingPathComponent(name).appendingPathExtension("json")
                if let graph = try? load(url: url) {
                    return graph
                }
            }
        }

        for name in candidateNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "json"),
               let graph = try? load(url: url) {
                return graph
            }
        }

        return demoProcedural()
    }

    private static func load(url: URL) throws -> BrainGraph {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BrainGraph.self, from: data)
    }

    static func demoProcedural() -> BrainGraph {
        var nodes: [Node] = []
        var edges: [Edge] = []

        let ringCounts = [14, 12, 10]
        let ringRadii: [Float] = [0.60, 0.42, 0.25]
        let ringHeights: [Float] = [0.16, 0.0, -0.16]

        for (ringIndex, count) in ringCounts.enumerated() {
            let radius = ringRadii[ringIndex]
            let y = ringHeights[ringIndex]

            for i in 0..<count {
                let theta = Float(i) / Float(count) * Float.pi * 2.0
                let x = cos(theta) * radius
                let z = sin(theta) * (radius * 0.72)
                let focus = ringIndex == 0 && i.isMultiple(of: 4)
                let size = focus ? 0.032 : 0.021 + Float(i % 3) * 0.003

                let color: [Float]
                if focus {
                    color = [1.0, 0.24, 0.18]
                } else {
                    switch ringIndex {
                    case 0:
                        color = [0.16, 0.82, 1.0]
                    case 1:
                        color = [0.45, 0.92, 0.92]
                    default:
                        color = [0.90, 0.84, 0.28]
                    }
                }

                nodes.append(
                    Node(
                        x: x,
                        y: y,
                        z: z,
                        size: size,
                        color: color,
                        is_focus: focus,
                        flywire_id: 720575940600000000 + Int64(nodes.count)
                    )
                )
            }
        }

        var offset = 0
        for count in ringCounts {
            for i in 0..<count {
                let a = offset + i
                let b = offset + ((i + 1) % count)
                let c = offset + ((i + 3) % count)
                edges.append(Edge(source: a, target: b, weight: 1.0, strength: 0.45))
                edges.append(Edge(source: a, target: c, weight: 1.0, strength: 0.25))
            }
            offset += count
        }

        let ring0 = 0
        let ring1 = ringCounts[0]
        let ring2 = ringCounts[0] + ringCounts[1]

        for i in 0..<ringCounts[1] {
            let a = ring1 + i
            let b = ring0 + ((i * ringCounts[0]) / ringCounts[1])
            edges.append(Edge(source: a, target: b, weight: 1.0, strength: 0.55))
        }

        for i in 0..<ringCounts[2] {
            let a = ring2 + i
            let b = ring1 + ((i * ringCounts[1]) / ringCounts[2])
            edges.append(Edge(source: a, target: b, weight: 1.0, strength: 0.60))
        }

        for i in 0..<8 {
            let angle = Float(i) * 0.82
            nodes.append(
                Node(
                    x: cos(angle) * 0.14,
                    y: sin(angle * 1.7) * 0.08,
                    z: sin(angle) * 0.12,
                    size: 0.018,
                    color: [0.84, 0.96, 1.0],
                    is_focus: false,
                    flywire_id: 920575940600000000 + Int64(i)
                )
            )
        }

        let innerStart = ringCounts.reduce(0, +)
        for i in innerStart..<nodes.count {
            edges.append(Edge(source: i, target: ring1 + (i - innerStart) % ringCounts[1], weight: 1.0, strength: 0.35))
            edges.append(Edge(source: i, target: ring2 + (i - innerStart) % ringCounts[2], weight: 1.0, strength: 0.30))
        }

        return BrainGraph(nodes: nodes, edges: edges)
    }
}

enum FlyFactory {
    private static let unitSphereMesh = MeshResource.generateSphere(radius: 1.0)
    private static let unitBoxMesh = MeshResource.generateBox(
        size: SIMD3<Float>(1.0, 1.0, 1.0),
        cornerRadius: 0.08
    )
    private static let unitCylinderMesh = MeshResource.generateCylinder(height: 1.0, radius: 1.0)

    static func makeWholeFly(brainGraph: BrainGraph) -> Entity {
        let root = Entity()
        root.name = "WholeFly"

        let amber = SimpleMaterial(color: uiColor(0.88, 0.67, 0.27), isMetallic: false)
        let golden = SimpleMaterial(color: uiColor(0.84, 0.56, 0.22), isMetallic: false)
        let brown = SimpleMaterial(color: uiColor(0.28, 0.18, 0.08), isMetallic: false)
        let darkBrown = SimpleMaterial(color: uiColor(0.16, 0.11, 0.05), isMetallic: false)
        let eye = UnlitMaterial(color: uiColor(0.90, 0.12, 0.06))
        let wing = UnlitMaterial(color: uiColor(0.88, 0.95, 1.0))
        let proboscisMaterial = SimpleMaterial(color: uiColor(0.35, 0.21, 0.10), isMetallic: false)

        let exoskeletonOpacity: Float = 0.42
        let wingOpacity: Float = 0.22

        let thorax = makeSphere(
            name: "Thorax",
            radii: SIMD3<Float>(0.15, 0.12, 0.12),
            position: SIMD3<Float>(0.0, 0.0, 0.0),
            material: amber,
            opacity: exoskeletonOpacity
        )
        root.addChild(thorax)

        let head = makeSphere(
            name: "Head",
            radii: SIMD3<Float>(0.095, 0.085, 0.085),
            position: SIMD3<Float>(-0.19, 0.02, 0.0),
            material: amber,
            opacity: 0.34
        )
        root.addChild(head)

        let neck = makeBone(
            name: "Neck",
            from: SIMD3<Float>(-0.12, 0.01, 0.0),
            to: SIMD3<Float>(-0.05, 0.0, 0.0),
            radius: 0.018,
            material: brown,
            opacity: 0.65
        )
        root.addChild(neck)

        let abdomenBase = makeSphere(
            name: "AbdomenBase",
            radii: SIMD3<Float>(0.12, 0.09, 0.09),
            position: SIMD3<Float>(0.17, -0.01, 0.0),
            material: golden,
            opacity: exoskeletonOpacity
        )
        root.addChild(abdomenBase)

        let abdomenMid = makeSphere(
            name: "AbdomenMid",
            radii: SIMD3<Float>(0.14, 0.085, 0.085),
            position: SIMD3<Float>(0.29, -0.02, 0.0),
            material: golden,
            opacity: exoskeletonOpacity
        )
        root.addChild(abdomenMid)

        let abdomenTip = makeSphere(
            name: "AbdomenTip",
            radii: SIMD3<Float>(0.10, 0.055, 0.055),
            position: SIMD3<Float>(0.41, -0.03, 0.0),
            material: golden,
            opacity: exoskeletonOpacity
        )
        root.addChild(abdomenTip)

        let stripePositions: [Float] = [0.18, 0.26, 0.34, 0.40]
        for (stripeIndex, stripeX) in stripePositions.enumerated() {
            let stripe = makeBox(
                name: "Stripe\(stripeIndex)",
                size: SIMD3<Float>(0.016, 0.125, 0.16),
                position: SIMD3<Float>(stripeX, -0.02 - Float(stripeIndex) * 0.002, 0.0),
                rotation: simd_quatf(angle: 0.0, axis: SIMD3<Float>(0.0, 1.0, 0.0)),
                material: darkBrown,
                opacity: 0.64
            )
            root.addChild(stripe)
        }

        let leftEye = makeSphere(
            name: "LeftEye",
            radii: SIMD3<Float>(0.045, 0.045, 0.045),
            position: SIMD3<Float>(-0.255, 0.04, 0.058),
            material: eye,
            opacity: 0.96
        )
        root.addChild(leftEye)

        let rightEye = makeSphere(
            name: "RightEye",
            radii: SIMD3<Float>(0.045, 0.045, 0.045),
            position: SIMD3<Float>(-0.255, 0.04, -0.058),
            material: eye,
            opacity: 0.96
        )
        root.addChild(rightEye)

        let proboscis = makeBone(
            name: "Proboscis",
            from: SIMD3<Float>(-0.26, -0.015, 0.0),
            to: SIMD3<Float>(-0.34, -0.075, 0.0),
            radius: 0.010,
            material: proboscisMaterial,
            opacity: 0.85
        )
        root.addChild(proboscis)

        for side in [Float(-1.0), Float(1.0)] {
            let antenna = makeBone(
                name: side < 0 ? "LeftAntenna" : "RightAntenna",
                from: SIMD3<Float>(-0.275, 0.07, side * 0.02),
                to: SIMD3<Float>(-0.34, 0.115, side * 0.055),
                radius: 0.006,
                material: brown,
                opacity: 0.88
            )
            root.addChild(antenna)

            let arista = makeBone(
                name: side < 0 ? "LeftArista" : "RightArista",
                from: SIMD3<Float>(-0.34, 0.115, side * 0.055),
                to: SIMD3<Float>(-0.37, 0.155, side * 0.085),
                radius: 0.003,
                material: darkBrown,
                opacity: 0.88
            )
            root.addChild(arista)

            let wingRotation =
                simd_quatf(angle: side * Float.pi / 7.5, axis: SIMD3<Float>(1.0, 0.0, 0.0)) *
                simd_quatf(angle: side * Float.pi / 9.0, axis: SIMD3<Float>(0.0, 1.0, 0.0)) *
                simd_quatf(angle: Float.pi / 30.0, axis: SIMD3<Float>(0.0, 0.0, 1.0))

            let wingEntity = makeBox(
                name: side < 0 ? "LeftWing" : "RightWing",
                size: SIMD3<Float>(0.27, 0.004, 0.15),
                position: SIMD3<Float>(0.04, 0.11, side * 0.125),
                rotation: wingRotation,
                material: wing,
                opacity: wingOpacity
            )
            root.addChild(wingEntity)

            let haltereStem = makeBone(
                name: side < 0 ? "LeftHaltereStem" : "RightHaltereStem",
                from: SIMD3<Float>(0.10, 0.015, side * 0.07),
                to: SIMD3<Float>(0.15, -0.01, side * 0.13),
                radius: 0.0045,
                material: brown,
                opacity: 0.72
            )
            root.addChild(haltereStem)

            let haltereClub = makeSphere(
                name: side < 0 ? "LeftHaltereClub" : "RightHaltereClub",
                radii: SIMD3<Float>(0.015, 0.015, 0.015),
                position: SIMD3<Float>(0.15, -0.01, side * 0.13),
                material: wing,
                opacity: 0.45
            )
            root.addChild(haltereClub)

            makeLegSet(on: root, side: side, material: brown)
        }

        let brain = makeBrainGraphEntity(brainGraph)
        root.addChild(brain)

        root.position = SIMD3<Float>(0.0, 0.02, 0.0)
        root.orientation =
            simd_quatf(angle: -Float.pi / 7.0, axis: SIMD3<Float>(0.0, 1.0, 0.0)) *
            simd_quatf(angle: Float.pi / 22.0, axis: SIMD3<Float>(0.0, 0.0, 1.0))

        return root
    }

    private static func makeLegSet(on root: Entity, side: Float, material: any Material) {
        let legPoints: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (
                SIMD3<Float>(-0.03, -0.01, side * 0.085),
                SIMD3<Float>(-0.11, -0.12, side * 0.17),
                SIMD3<Float>(-0.06, -0.30, side * 0.24)
            ),
            (
                SIMD3<Float>(0.045, -0.02, side * 0.095),
                SIMD3<Float>(0.02, -0.15, side * 0.22),
                SIMD3<Float>(0.11, -0.32, side * 0.26)
            ),
            (
                SIMD3<Float>(0.13, -0.02, side * 0.085),
                SIMD3<Float>(0.20, -0.16, side * 0.18),
                SIMD3<Float>(0.31, -0.31, side * 0.24)
            )
        ]

        for (index, points) in legPoints.enumerated() {
            let upper = makeBone(
                name: "Leg\(side < 0 ? "L" : "R")\(index)Upper",
                from: points.0,
                to: points.1,
                radius: 0.0065,
                material: material,
                opacity: 0.88
            )
            root.addChild(upper)

            let lower = makeBone(
                name: "Leg\(side < 0 ? "L" : "R")\(index)Lower",
                from: points.1,
                to: points.2,
                radius: 0.0045,
                material: material,
                opacity: 0.88
            )
            root.addChild(lower)

            let tarsus = makeBone(
                name: "Leg\(side < 0 ? "L" : "R")\(index)Tarsus",
                from: points.2,
                to: points.2 + SIMD3<Float>(0.06, -0.02, side * 0.01),
                radius: 0.0026,
                material: material,
                opacity: 0.88
            )
            root.addChild(tarsus)
        }
    }

    private static func makeBrainGraphEntity(
        _ graph: BrainGraph,
        maxNodes: Int = 420,
        maxEdges: Int = 1200
    ) -> Entity {
        let brainRoot = Entity()
        brainRoot.name = "BrainGraph"
        brainRoot.position = SIMD3<Float>(-0.195, 0.03, 0.0)

        let nodeLimit = min(graph.nodes.count, maxNodes)
        let limitedNodes = Array(graph.nodes.prefix(nodeLimit))
        let brainScale: Float = 0.060

        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(limitedNodes.count)

        for node in limitedNodes {
            positions.append(SIMD3<Float>(node.x * brainScale, node.y * brainScale, node.z * brainScale))
        }

        let edgeMaterial = UnlitMaterial(color: uiColor(0.32, 0.75, 1.0))
        let limitedEdges = graph.edges.prefix(maxEdges).filter {
            $0.source >= 0 &&
            $0.target >= 0 &&
            $0.source < nodeLimit &&
            $0.target < nodeLimit &&
            $0.source != $0.target
        }

        for (index, edge) in limitedEdges.enumerated() {
            let start = positions[edge.source]
            let end = positions[edge.target]
            let strength = min(max(edge.strength ?? 0.35, 0.0), 1.0)
            let edgeEntity = makeBone(
                name: "BrainEdge\(index)",
                from: start,
                to: end,
                radius: 0.0007 + strength * 0.0011,
                material: edgeMaterial,
                opacity: 0.24 + strength * 0.18
            )
            brainRoot.addChild(edgeEntity)
        }

        for (index, node) in limitedNodes.enumerated() {
            let color = uiColor(from: node.color, fallbackFocus: node.is_focus ?? false)
            let nodeMaterial = UnlitMaterial(color: color)
            let radius = max(0.0024, (node.size ?? 0.020) * 0.20)
            let nodeEntity = ModelEntity(mesh: unitSphereMesh, materials: [nodeMaterial])
            nodeEntity.name = "BrainNode\(index)"
            nodeEntity.position = positions[index]
            nodeEntity.scale = SIMD3<Float>(repeating: radius)
            nodeEntity.components.set(OpacityComponent(opacity: 0.92))
            brainRoot.addChild(nodeEntity)
        }

        let brainHalo = makeSphere(
            name: "BrainHalo",
            radii: SIMD3<Float>(0.085, 0.072, 0.072),
            position: SIMD3<Float>(0.0, 0.0, 0.0),
            material: UnlitMaterial(color: uiColor(0.18, 0.52, 0.95)),
            opacity: 0.08
        )
        brainRoot.addChild(brainHalo)

        return brainRoot
    }

    private static func makeSphere(
        name: String,
        radii: SIMD3<Float>,
        position: SIMD3<Float>,
        material: any Material,
        opacity: Float? = nil
    ) -> ModelEntity {
        let entity = ModelEntity(mesh: unitSphereMesh, materials: [material])
        entity.name = name
        entity.position = position
        entity.scale = radii
        if let opacity {
            entity.components.set(OpacityComponent(opacity: opacity))
        }
        return entity
    }

    private static func makeBox(
        name: String,
        size: SIMD3<Float>,
        position: SIMD3<Float>,
        rotation: simd_quatf,
        material: any Material,
        opacity: Float? = nil
    ) -> ModelEntity {
        let entity = ModelEntity(mesh: unitBoxMesh, materials: [material])
        entity.name = name
        entity.position = position
        entity.scale = size
        entity.orientation = rotation
        if let opacity {
            entity.components.set(OpacityComponent(opacity: opacity))
        }
        return entity
    }

    private static func makeBone(
        name: String,
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        radius: Float,
        material: any Material,
        opacity: Float? = nil
    ) -> ModelEntity {
        let entity = ModelEntity(mesh: unitCylinderMesh, materials: [material])
        entity.name = name

        let delta = end - start
        let length = max(simd_length(delta), 0.0001)
        let midpoint = (start + end) * 0.5
        let direction = delta / length

        entity.position = midpoint
        entity.scale = SIMD3<Float>(radius, length, radius)
        entity.orientation = simd_quatf(from: SIMD3<Float>(0.0, 1.0, 0.0), to: direction)

        if let opacity {
            entity.components.set(OpacityComponent(opacity: opacity))
        }

        return entity
    }

    private static func uiColor(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1.0) -> UIColor {
        UIColor(
            red: CGFloat(r),
            green: CGFloat(g),
            blue: CGFloat(b),
            alpha: CGFloat(a)
        )
    }

    private static func uiColor(from rgb: [Float]?, fallbackFocus: Bool) -> UIColor {
        guard let rgb, rgb.count >= 3 else {
            return fallbackFocus ? uiColor(1.0, 0.24, 0.18) : uiColor(0.30, 0.82, 1.0)
        }
        return uiColor(rgb[0], rgb[1], rgb[2])
    }
}
