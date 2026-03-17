import Foundation
import simd

struct WholeFlyGraph: Decodable {
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

struct WholeFlySceneMetadata {
    let sourceLabel: String
    let sourceLocation: String?
    let nodeCount: Int
    let edgeCount: Int
    let notes: String?

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    func formatted(_ value: Int) -> String {
        Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

extension WholeFlyGraph {
    private static let candidateNames = [
        "flybrain_for_vision_pro",
        "flybrain_p9",
        "flybrain_focus",
        "demo_brain_graph"
    ]

    static func loadPreferred() -> (WholeFlyGraph, WholeFlySceneMetadata) {
        let fileManager = FileManager.default

        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            for name in candidateNames {
                let url = documentsURL.appendingPathComponent(name).appendingPathExtension("json")
                if let graph = try? load(url: url) {
                    return (
                        graph,
                        WholeFlySceneMetadata(
                            sourceLabel: "Whole-fly graph from Documents",
                            sourceLocation: url.lastPathComponent,
                            nodeCount: graph.nodes.count,
                            edgeCount: graph.edges.count,
                            notes: graph.meta?.notes
                        )
                    )
                }
            }
        }

        for name in candidateNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "json"),
               let graph = try? load(url: url) {
                return (
                    graph,
                    WholeFlySceneMetadata(
                        sourceLabel: "Bundled whole-fly graph asset",
                        sourceLocation: url.lastPathComponent,
                        nodeCount: graph.nodes.count,
                        edgeCount: graph.edges.count,
                        notes: graph.meta?.notes
                    )
                )
            }
        }

        if let bundledBackbone = try? makeFromConnectomeBackbone() {
            return bundledBackbone
        }

        let graph = proceduralDemo()
        return (
            graph,
            WholeFlySceneMetadata(
                sourceLabel: "Procedural fallback graph",
                sourceLocation: nil,
                nodeCount: graph.nodes.count,
                edgeCount: graph.edges.count,
                notes: "Fallback graph used because no exported whole-fly JSON or bundled backbone was available."
            )
        )
    }

    private static func load(url: URL) throws -> WholeFlyGraph {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.wholeFlyGraph.decode(WholeFlyGraph.self, from: data)
    }

    private static func makeFromConnectomeBackbone() throws -> (WholeFlyGraph, WholeFlySceneMetadata) {
        guard let url = Bundle.main.url(forResource: "ConnectivityBackbone", withExtension: "json") else {
            throw WholeFlyGraphError.missingBackboneAsset
        }

        let data = try Data(contentsOf: url)
        let backbone = try JSONDecoder.connectomeBackbone.decode(ConnectomeBackbone.self, from: data)
        let focusIndices = Set(
            backbone.nodes.enumerated()
                .sorted { $0.element.degree > $1.element.degree }
                .prefix(12)
                .map(\.offset)
        )

        let maxWeight = backbone.edges.map(\.weight).max() ?? 1
        let maxLogWeight = max(log(Double(maxWeight) + 1.0), 0.0001)

        let nodes = backbone.nodes.enumerated().map { index, node in
            let color: [Float]
            if node.balance > 0.18 {
                color = [0.96, 0.66, 0.28]
            } else if node.balance < -0.18 {
                color = [0.37, 0.82, 0.77]
            } else {
                color = [0.91, 0.84, 0.72]
            }

            return WholeFlyGraph.Node(
                sourceIndex: index,
                connectomeIndex: node.sourceIndex,
                flywireId: Int64(node.rootID),
                x: node.position[0],
                y: node.position[1],
                z: node.position[2],
                size: 0.015 + node.degreeNorm * 0.020,
                color: color,
                isFocus: focusIndices.contains(index),
                degree: node.degree
            )
        }

        let edges = backbone.edges
            .sorted { $0.weight > $1.weight }
            .map { edge in
                WholeFlyGraph.Edge(
                    source: edge.source,
                    target: edge.target,
                    weight: edge.weight,
                    strength: Float(log(Double(edge.weight) + 1.0) / maxLogWeight)
                )
            }

        let graph = WholeFlyGraph(
            meta: WholeFlyGraph.Meta(
                generator: "ConnectivityBackbone.json",
                layout: "bundled_backbone_projection",
                nodeCount: backbone.nodes.count,
                edgeCount: backbone.edges.count,
                sourceCompleteness: nil,
                sourceConnectivity: "FlyBrainVision/Resources/ConnectivityBackbone.json",
                notes: "Whole-fly view is using the bundled reduced connectome backbone inside the procedural body."
            ),
            nodes: nodes,
            edges: edges
        )

        return (
            graph,
            WholeFlySceneMetadata(
                sourceLabel: "Bundled connectome backbone",
                sourceLocation: url.lastPathComponent,
                nodeCount: graph.nodes.count,
                edgeCount: graph.edges.count,
                notes: graph.meta?.notes
            )
        )
    }

    private static func proceduralDemo() -> WholeFlyGraph {
        var nodes: [WholeFlyGraph.Node] = []
        var edges: [WholeFlyGraph.Edge] = []

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
                    WholeFlyGraph.Node(
                        sourceIndex: nodes.count,
                        connectomeIndex: nil,
                        flywireId: 720575940600000000 + Int64(nodes.count),
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
                edges.append(WholeFlyGraph.Edge(source: a, target: b, weight: 1.0, strength: 0.45))
                edges.append(WholeFlyGraph.Edge(source: a, target: c, weight: 1.0, strength: 0.25))
            }
            offset += count
        }

        let ring0 = 0
        let ring1 = ringCounts[0]
        let ring2 = ringCounts[0] + ringCounts[1]

        for i in 0..<ringCounts[1] {
            let a = ring1 + i
            let b = ring0 + ((i * ringCounts[0]) / ringCounts[1])
            edges.append(WholeFlyGraph.Edge(source: a, target: b, weight: 1.0, strength: 0.55))
        }

        for i in 0..<ringCounts[2] {
            let a = ring2 + i
            let b = ring1 + ((i * ringCounts[1]) / ringCounts[2])
            edges.append(WholeFlyGraph.Edge(source: a, target: b, weight: 1.0, strength: 0.60))
        }

        for i in 0..<8 {
            let angle = Float(i) * 0.82
            nodes.append(
                WholeFlyGraph.Node(
                    sourceIndex: nodes.count,
                    connectomeIndex: nil,
                    flywireId: 920575940600000000 + Int64(i),
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
                WholeFlyGraph.Edge(
                    source: i,
                    target: ring1 + (i - innerStart) % ringCounts[1],
                    weight: 1.0,
                    strength: 0.35
                )
            )
            edges.append(
                WholeFlyGraph.Edge(
                    source: i,
                    target: ring2 + (i - innerStart) % ringCounts[2],
                    weight: 1.0,
                    strength: 0.30
                )
            )
        }

        return WholeFlyGraph(
            meta: WholeFlyGraph.Meta(
                generator: "proceduralDemo",
                layout: "ring_layout",
                nodeCount: nodes.count,
                edgeCount: edges.count,
                sourceCompleteness: nil,
                sourceConnectivity: nil,
                notes: "Procedural whole-fly graph fallback."
            ),
            nodes: nodes,
            edges: edges
        )
    }
}

private enum WholeFlyGraphError: LocalizedError {
    case missingBackboneAsset

    var errorDescription: String? {
        switch self {
        case .missingBackboneAsset:
            return "ConnectivityBackbone.json is missing from the app bundle."
        }
    }
}

private extension JSONDecoder {
    static let wholeFlyGraph: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
