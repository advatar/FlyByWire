import Foundation

struct MeshCollectionAsset: Decodable {
    struct Metadata: Decodable {
        let title: String
        let description: String
        let sourceURL: String?
        let source: String?
        let rootIDs: [String]?
        let cellSizeNm: Float?
    }

    struct Part: Decodable {
        let name: String
        let color: [Float]
        let vertices: [[Float]]
        let faces: [[Int]]
        let lod: Int?
    }

    let metadata: Metadata
    let parts: [Part]
}
