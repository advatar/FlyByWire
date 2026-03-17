import Foundation
import simd

struct FlyWorldPosePacket: Decodable {
    struct WorldObject: Decodable, Identifiable {
        let id: String
        let kind: String
        let label: String?
        let positionMm: [Float]
        let sizeMm: [Float]?
        let color: [Float]?
        let opacity: Float?

        var positionVector: SIMD3<Float> {
            FlyWorldPosePacket.vector3(from: positionMm, fallback: SIMD3<Float>(0.0, 0.0, 0.0))
        }

        var sizeVector: SIMD3<Float>? {
            guard let sizeMm else { return nil }
            return FlyWorldPosePacket.vector3(from: sizeMm, fallback: SIMD3<Float>(repeating: 1.0))
        }
    }

    let timestamp: Double
    let rootPositionMm: [Float]
    let rootQuaternionXyzw: [Float]
    let jointAnglesRad: [String: Float]
    let brainState: [String: Float]
    let behavior: String
    let worldObjects: [WorldObject]?

    var rootPositionVector: SIMD3<Float> {
        Self.vector3(from: rootPositionMm, fallback: .zero)
    }

    var rootQuaternion: simd_quatf {
        let values = rootQuaternionXyzw
        guard values.count >= 4 else {
            return simd_quatf(angle: 0.0, axis: SIMD3<Float>(0.0, 1.0, 0.0))
        }
        let quaternion = simd_quatf(ix: values[0], iy: values[1], iz: values[2], r: values[3])
        let length = simd_length(quaternion.vector)
        guard length > 0.0001 else {
            return simd_quatf(angle: 0.0, axis: SIMD3<Float>(0.0, 1.0, 0.0))
        }
        return simd_normalize(quaternion)
    }

    var worldObjectsOrDefault: [WorldObject] {
        worldObjects ?? []
    }

    fileprivate static func vector3(from values: [Float], fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard values.count >= 3 else { return fallback }
        return SIMD3(values[0], values[1], values[2])
    }
}

struct FlyWorldPosePacketSource {
    let label: String
    let location: String?
    let modificationDate: Date?
}

extension FlyWorldPosePacket {
    private static let candidateNames = [
        "vision_pro_pose_packet",
        "fly_world_pose_packet",
        "sample_vision_pro_pose_packet"
    ]

    static func loadPreferred(bundle: Bundle = .main) -> (FlyWorldPosePacket, FlyWorldPosePacketSource)? {
        let fileManager = FileManager.default

        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            for name in candidateNames {
                let url = documentsURL.appendingPathComponent(name).appendingPathExtension("json")
                if let packet = try? load(url: url) {
                    let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                    return (
                        packet,
                        FlyWorldPosePacketSource(
                            label: "Documents pose packet",
                            location: url.lastPathComponent,
                            modificationDate: attributes?[.modificationDate] as? Date
                        )
                    )
                }
            }
        }

        for name in candidateNames {
            if let url = bundle.url(forResource: name, withExtension: "json"),
               let packet = try? load(url: url) {
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                return (
                    packet,
                    FlyWorldPosePacketSource(
                        label: "Bundled pose packet",
                        location: url.lastPathComponent,
                        modificationDate: attributes?[.modificationDate] as? Date
                    )
                )
            }
        }

        return nil
    }

    private static func load(url: URL) throws -> FlyWorldPosePacket {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.flyWorld.decode(FlyWorldPosePacket.self, from: data)
    }
}
