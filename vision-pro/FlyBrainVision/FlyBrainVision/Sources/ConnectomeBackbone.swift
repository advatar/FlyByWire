import Foundation
import simd

struct ConnectomeBackbone: Decodable {
    struct Metadata: Decodable {
        let sourceNodeCount: Int
        let sourceEdgeCount: Int
        let selectedNodeCount: Int
        let selectedEdgeCount: Int
        let reducedEdgeCount: Int
        let selectionRule: String
    }

    struct Node: Decodable {
        let rootID: String
        let sourceIndex: Int
        let degree: Float
        let degreeNorm: Float
        let balance: Float
        let position: [Float]

        var simdPosition: SIMD3<Float> {
            SIMD3(position[0], position[1], position[2])
        }
    }

    struct Edge: Decodable {
        let source: Int
        let target: Int
        let weight: Float
        let sign: Int
    }

    let metadata: Metadata
    let nodes: [Node]
    let edges: [Edge]
}

extension ConnectomeBackbone.Metadata {
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

extension JSONDecoder {
    static let connectomeBackbone: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
