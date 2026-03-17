import Foundation
import simd

struct FlyWorldGraph: Decodable {
    struct Meta: Decodable {
        let generator: String?
        let layout: String?
        let nodeCount: Int?
        let edgeCount: Int?
        let sourceCompleteness: String?
        let sourceConnectivity: String?
        let notes: String?
    }

    struct Node: Decodable {
        let sourceIndex: Int?
        let connectomeIndex: Int?
        let flywireId: Int64?
        let x: Float
        let y: Float
        let z: Float
        let size: Float?
        let color: [Float]?
        let isFocus: Bool?
        let degree: Float?

        var position: SIMD3<Float> {
            SIMD3(x, y, z)
        }
    }

    struct Edge: Decodable {
        let source: Int
        let target: Int
        let weight: Float?
        let strength: Float?
    }

    let meta: Meta?
    let nodes: [Node]
    let edges: [Edge]
}

struct FlyWorldGraphSource {
    let label: String
    let location: String?
    let notes: String?
}

extension FlyWorldGraph {
    private static let candidateNames = [
        "flybrain_for_vision_pro",
        "flybrain_p9",
        "flybrain_focus",
        "demo_brain_graph"
    ]

    static func loadPreferred(bundle: Bundle = .main) -> (FlyWorldGraph, FlyWorldGraphSource) {
        let fileManager = FileManager.default

        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            for name in candidateNames {
                let url = documentsURL.appendingPathComponent(name).appendingPathExtension("json")
                if let graph = try? load(url: url) {
                    return (
                        graph,
                        FlyWorldGraphSource(
                            label: "Documents graph asset",
                            location: url.lastPathComponent,
                            notes: graph.meta?.notes
                        )
                    )
                }
            }
        }

        for name in candidateNames {
            if let url = bundle.url(forResource: name, withExtension: "json"),
               let graph = try? load(url: url) {
                return (
                    graph,
                    FlyWorldGraphSource(
                        label: "Bundled graph asset",
                        location: url.lastPathComponent,
                        notes: graph.meta?.notes
                    )
                )
            }
        }

        let graph = proceduralDemo()
        return (
            graph,
            FlyWorldGraphSource(
                label: "Procedural fallback graph",
                location: nil,
                notes: "Fallback graph used because no bundled or exported graph asset was found."
            )
        )
    }

    private static func load(url: URL) throws -> FlyWorldGraph {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.flyWorld.decode(FlyWorldGraph.self, from: data)
    }

    private static func proceduralDemo() -> FlyWorldGraph {
        var nodes: [FlyWorldGraph.Node] = []
        var edges: [FlyWorldGraph.Edge] = []

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
                    FlyWorldGraph.Node(
                        sourceIndex: nodes.count,
                        connectomeIndex: nil,
                        flywireId: 720_575_940_600_000_000 + Int64(nodes.count),
                        x: x,
                        y: y,
                        z: z,
                        size: size,
                        color: color,
                        isFocus: focus,
                        degree: nil
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
                edges.append(FlyWorldGraph.Edge(source: a, target: b, weight: 1.0, strength: 0.45))
                edges.append(FlyWorldGraph.Edge(source: a, target: c, weight: 1.0, strength: 0.25))
            }
            offset += count
        }

        let ring0 = 0
        let ring1 = ringCounts[0]
        let ring2 = ringCounts[0] + ringCounts[1]

        for i in 0..<ringCounts[1] {
            let a = ring1 + i
            let b = ring0 + ((i * ringCounts[0]) / ringCounts[1])
            edges.append(FlyWorldGraph.Edge(source: a, target: b, weight: 1.0, strength: 0.55))
        }

        for i in 0..<ringCounts[2] {
            let a = ring2 + i
            let b = ring1 + ((i * ringCounts[1]) / ringCounts[2])
            edges.append(FlyWorldGraph.Edge(source: a, target: b, weight: 1.0, strength: 0.60))
        }

        for i in 0..<8 {
            let angle = Float(i) * 0.82
            nodes.append(
                FlyWorldGraph.Node(
                    sourceIndex: nodes.count,
                    connectomeIndex: nil,
                    flywireId: 920_575_940_600_000_000 + Int64(i),
                    x: cos(angle) * 0.14,
                    y: sin(angle * 1.7) * 0.08,
                    z: sin(angle) * 0.12,
                    size: 0.018,
                    color: [0.84, 0.96, 1.0],
                    isFocus: false,
                    degree: nil
                )
            )
        }

        let innerStart = ringCounts.reduce(0, +)
        for i in innerStart..<nodes.count {
            edges.append(
                FlyWorldGraph.Edge(
                    source: i,
                    target: ring1 + (i - innerStart) % ringCounts[1],
                    weight: 1.0,
                    strength: 0.35
                )
            )
            edges.append(
                FlyWorldGraph.Edge(
                    source: i,
                    target: ring2 + (i - innerStart) % ringCounts[2],
                    weight: 1.0,
                    strength: 0.30
                )
            )
        }

        return FlyWorldGraph(
            meta: FlyWorldGraph.Meta(
                generator: "procedural",
                layout: "procedural_rings",
                nodeCount: nodes.count,
                edgeCount: edges.count,
                sourceCompleteness: nil,
                sourceConnectivity: nil,
                notes: "Procedural fallback graph for whole-fly viewing."
            ),
            nodes: nodes,
            edges: edges
        )
    }
}

extension JSONDecoder {
    static let flyWorld: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
