import Foundation
import simd

struct FlyWorldPosePacket: Decodable {
    struct Agent: Decodable, Identifiable {
        let id: String
        let label: String?
        let generation: Int?
        let score: Float?
        let rootPositionMm: [Float]
        let rootQuaternionXyzw: [Float]
        let jointAnglesRad: [String: Float]
        let brainState: [String: Float]
        let behavior: String
        let genomeSummary: String?
        let lifeState: String?
        let deathReason: String?
        let deathTime: Double?

        var rootPositionVector: SIMD3<Float> {
            FlyWorldPosePacket.vector3(from: rootPositionMm, fallback: .zero)
        }

        var rootQuaternion: simd_quatf {
            FlyWorldPosePacket.quaternion(from: rootQuaternionXyzw)
        }

        var isDead: Bool {
            FlyWorldPosePacket.isDead(lifeState: lifeState, behavior: behavior)
        }
    }

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

    struct MatingEvent: Decodable {
        let id: String?
        let parentIds: [String]?
        let offspringId: String?
        let generation: Int?
        let timestamp: Double?
    }

    let timestamp: Double
    let rootPositionMm: [Float]
    let rootQuaternionXyzw: [Float]
    let jointAnglesRad: [String: Float]
    let brainState: [String: Float]
    let behavior: String
    let lifeState: String?
    let deathReason: String?
    let deathTime: Double?
    let worldObjects: [WorldObject]?
    let agents: [Agent]?
    let channelAliases: [String: String]?
    let matingEvents: [MatingEvent]?

    init(
        timestamp: Double,
        rootPositionMm: [Float],
        rootQuaternionXyzw: [Float],
        jointAnglesRad: [String: Float],
        brainState: [String: Float],
        behavior: String,
        lifeState: String? = nil,
        deathReason: String? = nil,
        deathTime: Double? = nil,
        worldObjects: [WorldObject]?,
        agents: [Agent]? = nil,
        channelAliases: [String: String]? = nil,
        matingEvents: [MatingEvent]? = nil
    ) {
        self.timestamp = timestamp
        self.rootPositionMm = rootPositionMm
        self.rootQuaternionXyzw = rootQuaternionXyzw
        self.jointAnglesRad = jointAnglesRad
        self.brainState = brainState
        self.behavior = behavior
        self.lifeState = lifeState
        self.deathReason = deathReason
        self.deathTime = deathTime
        self.worldObjects = worldObjects
        self.agents = agents
        self.channelAliases = channelAliases
        self.matingEvents = matingEvents
    }

    var rootPositionVector: SIMD3<Float> {
        Self.vector3(from: rootPositionMm, fallback: .zero)
    }

    var rootQuaternion: simd_quatf {
        Self.quaternion(from: rootQuaternionXyzw)
    }

    var worldObjectsOrDefault: [WorldObject] {
        worldObjects ?? []
    }

    var isDead: Bool {
        Self.isDead(lifeState: lifeState, behavior: behavior)
    }

    var displayAgents: [Agent] {
        if let agents, !agents.isEmpty {
            return agents
        }
        return [legacyPrimaryAgent]
    }

    func packet(for agent: Agent) -> FlyWorldPosePacket {
        FlyWorldPosePacket(
            timestamp: timestamp,
            rootPositionMm: agent.rootPositionMm,
            rootQuaternionXyzw: agent.rootQuaternionXyzw,
            jointAnglesRad: agent.jointAnglesRad,
            brainState: agent.brainState,
            behavior: agent.behavior,
            lifeState: agent.lifeState,
            deathReason: agent.deathReason,
            deathTime: agent.deathTime,
            worldObjects: worldObjects,
            agents: nil,
            channelAliases: channelAliases,
            matingEvents: matingEvents
        )
    }

    private var legacyPrimaryAgent: Agent {
        Agent(
            id: "primary",
            label: nil,
            generation: nil,
            score: nil,
            rootPositionMm: rootPositionMm,
            rootQuaternionXyzw: rootQuaternionXyzw,
            jointAnglesRad: jointAnglesRad,
            brainState: brainState,
            behavior: behavior,
            genomeSummary: nil,
            lifeState: lifeState,
            deathReason: deathReason,
            deathTime: deathTime
        )
    }

    fileprivate static func isDead(lifeState: String?, behavior: String) -> Bool {
        let normalizedState = normalizedLifecycleToken(lifeState)
        if ["dead", "killed", "terminated"].contains(normalizedState) {
            return true
        }

        let normalizedBehavior = normalizedLifecycleToken(behavior)
        return ["dead", "killed", "terminated"].contains(normalizedBehavior)
    }

    private static func normalizedLifecycleToken(_ token: String?) -> String {
        (token ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }

    fileprivate static func vector3(from values: [Float], fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard values.count >= 3 else { return fallback }
        return SIMD3(values[0], values[1], values[2])
    }

    fileprivate static func quaternion(from values: [Float]) -> simd_quatf {
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
}

struct FlyWorldPosePacketSource {
    let label: String
    let location: String?
    let modificationDate: Date?
}

struct FlyWorldDirectLegAngles {
    let coxa: Float
    let femur: Float
    let tibia: Float
}

extension FlyWorldPosePacket {
    func directLegAngles(for leg: FlyWorldLegID) -> FlyWorldDirectLegAngles? {
        Self.directLegAngles(jointAnglesRad: jointAnglesRad, for: leg)
    }
}

extension FlyWorldPosePacket.Agent {
    func directLegAngles(for leg: FlyWorldLegID) -> FlyWorldDirectLegAngles? {
        FlyWorldPosePacket.directLegAngles(jointAnglesRad: jointAnglesRad, for: leg)
    }
}

extension FlyWorldPosePacket {
    fileprivate static func directLegAngles(
        jointAnglesRad: [String: Float],
        for leg: FlyWorldLegID
    ) -> FlyWorldDirectLegAngles? {
        func value(_ key: String) -> Float? {
            jointAnglesRad[key]
        }

        let prefix = leg.packetJointPrefix

        guard let coxa = value("\(prefix)Coxa"),
              let femur = value("\(prefix)Femur"),
              let tibia = value("\(prefix)Tibia") else {
            return nil
        }

        return FlyWorldDirectLegAngles(
            coxa: coxa,
            femur: femur,
            tibia: tibia
        )
    }
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

    /// Fetch a pose packet from a LAN HTTP endpoint (e.g. the LearningToFly
    /// `run_live_multi_fly.py` driver). Used when the Vision Pro device cannot
    /// share a filesystem with the host running the simulator.
    static func loadFromURL(_ url: URL, timeout: TimeInterval = 1.5) async -> (FlyWorldPosePacket, FlyWorldPosePacketSource)? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                return nil
            }
            let packet = try JSONDecoder.flyWorld.decode(FlyWorldPosePacket.self, from: data)
            return (
                packet,
                FlyWorldPosePacketSource(
                    label: "LAN pose stream",
                    location: url.absoluteString,
                    modificationDate: Date()
                )
            )
        } catch {
            return nil
        }
    }
}
