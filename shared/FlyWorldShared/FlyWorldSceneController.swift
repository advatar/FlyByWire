import Foundation
import Observation
import RealityKit
import simd

#if canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias PlatformColor = NSColor
#endif

struct FlyWorldSceneMetadata {
    let graphSourceLabel: String
    let graphSourceLocation: String?
    let graphNodeCount: Int
    let graphEdgeCount: Int
    let graphNotes: String?
    let poseSourceLabel: String?
    let poseSourceLocation: String?
    let behavior: String?
    let jointCount: Int
    let brainChannelCount: Int
    let worldObjectCount: Int
    let packetTimestamp: Double?
    let packetAgeDescription: String?

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    func formatted(_ value: Int) -> String {
        Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func packetAgeDescription(
        for timestamp: Double?,
        referenceDate: Date = .now
    ) -> String? {
        guard let timestamp else { return nil }
        let age = max(referenceDate.timeIntervalSince1970 - timestamp, 0.0)
        if age < 1.0 {
            return "live"
        }
        if age < 60.0 {
            return String(format: "%.1fs ago", age)
        }
        return String(format: "%.0fs ago", age)
    }
}

private enum FlyWorldMotionMode {
    case directPose
    case brainDrivenFallback
}

@MainActor
@Observable
final class FlyWorldSceneController {
    let root = Entity()

    private let arenaRoot = Entity()
    private let worldObjectsRoot = Entity()
    private var graph: FlyWorldGraph?
    private var rig: FlyWorldBuild?
    private var extraRigs: [String: FlyWorldBuild] = [:]
    private var poseTask: Task<Void, Never>?
    private var latestPacket: FlyWorldPosePacket?
    private var latestPoseSource: FlyWorldPosePacketSource?
    private var lastPacketSignature: String?
    private var isLoaded = false
    private var motionMode: FlyWorldMotionMode = .brainDrivenFallback
    private var brainMotionControllers: [String: FlyWorldBrainDrivenMotionController] = [:]

    private let floorY: Float = FlyWorldLegKinematics.arenaFloorSceneY
    private let millimeterScale: Float = FlyWorldLegKinematics.sceneMillimeterScale
    private let simulationToSceneRotation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1.0, 0.0, 0.0))

    private(set) var metadata: FlyWorldSceneMetadata?
    private(set) var errorMessage: String?
    var packetURLString: String = ""

    init() {
        root.addChild(arenaRoot)
        root.addChild(worldObjectsRoot)
        buildArena()
    }

    func loadIfNeeded(bundle: Bundle = .main) {
        guard !isLoaded else { return }

        let (graph, graphSource) = FlyWorldGraph.loadPreferred(bundle: bundle)
        self.graph = graph
        let build = FlyWorldEntityFactory.makeScene(graph: graph)
        rig = build
        root.addChild(build.root)
        isLoaded = true

        metadata = FlyWorldSceneMetadata(
            graphSourceLabel: graphSource.label,
            graphSourceLocation: graphSource.location,
            graphNodeCount: graph.nodes.count,
            graphEdgeCount: graph.edges.count,
            graphNotes: graphSource.notes,
            poseSourceLabel: nil,
            poseSourceLocation: nil,
            behavior: nil,
            jointCount: 0,
            brainChannelCount: 0,
            worldObjectCount: 0,
            packetTimestamp: nil,
            packetAgeDescription: nil
        )

        if let (packet, source) = FlyWorldPosePacket.loadPreferred(bundle: bundle) {
            apply(packet: packet, source: source)
        } else {
            let fallback = Self.makeFallbackPacket()
            apply(packet: fallback, source: nil)
        }
    }

    func startPoseUpdates(bundle: Bundle = .main) {
        guard poseTask == nil else { return }
        poseTask = Task { [weak self] in
            await self?.runPoseLoop(bundle: bundle)
        }
    }

    func stopPoseUpdates() {
        poseTask?.cancel()
        poseTask = nil
    }

    func setSceneScale(_ scale: Float) {
        root.scale = SIMD3<Float>(repeating: scale)
    }

    private func runPoseLoop(bundle: Bundle) async {
        var frameIndex = 0
        while !Task.isCancelled {
            if frameIndex.isMultiple(of: 8) {
                var refreshed: (FlyWorldPosePacket, FlyWorldPosePacketSource)?
                let trimmedURL = packetURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedURL.isEmpty, let url = URL(string: trimmedURL) {
                    refreshed = await FlyWorldPosePacket.loadFromURL(url)
                }
                if refreshed == nil {
                    refreshed = FlyWorldPosePacket.loadPreferred(bundle: bundle)
                }
                if let (packet, source) = refreshed {
                    let signature = packetSignature(for: packet, source: source)
                    if signature != lastPacketSignature {
                        apply(packet: packet, source: source)
                        lastPacketSignature = signature
                    }
                }
            }

            animate(at: Date().timeIntervalSince1970)
            frameIndex += 1

            do {
                try await Task.sleep(nanoseconds: 33_000_000)
            } catch {
                return
            }
        }
    }

    private func apply(packet: FlyWorldPosePacket, source: FlyWorldPosePacketSource?) {
        let renderTime = Date().timeIntervalSince1970
        guard rig != nil else { return }

        latestPacket = packet
        latestPoseSource = source
        switch source?.label {
        case "Documents pose packet", "LAN pose stream":
            motionMode = .directPose
        default:
            motionMode = .brainDrivenFallback
        }
        if motionMode == .brainDrivenFallback {
            resetBrainMotionControllers(for: packet, referenceTime: renderTime)
        }

        let behavior = render(packet: packet, time: renderTime)
        updateWorldObjects(from: packet.worldObjectsOrDefault)
        refreshMetadata(packet: packet, source: source, behavior: behavior)
    }

    private func animate(at time: TimeInterval) {
        guard rig != nil, let packet = latestPacket else { return }
        _ = render(packet: packet, time: time)
        refreshPacketAge(referenceDate: Date(timeIntervalSince1970: time))
    }

    private func resolveMotionFrame(
        packet: FlyWorldPosePacket,
        time: TimeInterval,
        agentID: String
    ) -> FlyWorldMotionFrame {
        switch motionMode {
        case .directPose:
            return FlyWorldMotionFrame.directPose(packet: packet, time: time)
        case .brainDrivenFallback:
            var controller = brainMotionControllers[agentID] ?? FlyWorldBrainDrivenMotionController()
            let motion = controller.synthesize(packet: packet, time: time)
            brainMotionControllers[agentID] = controller
            return motion
        }
    }

    private func render(packet: FlyWorldPosePacket, time: TimeInterval) -> String {
        syncExtraRigs(for: packet.displayAgents)

        var primaryBehavior = packet.behavior
        for (index, agent) in packet.displayAgents.enumerated() {
            let agentPacket = packet.packet(for: agent)
            let motion = resolveMotionFrame(packet: agentPacket, time: time, agentID: agent.id)
            guard let build = rig(for: agent, index: index) else { continue }
            applyRootTransform(motion: motion, rig: build)
            applyBehaviorState(packet: agentPacket, motion: motion, rig: build)
            if index == 0 {
                primaryBehavior = motion.behavior
            }
        }

        return primaryBehavior
    }

    private func rig(for agent: FlyWorldPosePacket.Agent, index: Int) -> FlyWorldBuild? {
        if index == 0 {
            return rig
        }
        return extraRigs[agent.id]
    }

    private func syncExtraRigs(for agents: [FlyWorldPosePacket.Agent]) {
        guard let graph else { return }

        let required = Set(agents.dropFirst().map(\.id))
        for (agentID, build) in Array(extraRigs) where !required.contains(agentID) {
            build.root.removeFromParent()
            extraRigs.removeValue(forKey: agentID)
            brainMotionControllers.removeValue(forKey: agentID)
        }

        for agent in agents.dropFirst() where extraRigs[agent.id] == nil {
            let build = FlyWorldEntityFactory.makeScene(graph: graph)
            extraRigs[agent.id] = build
            root.addChild(build.root)
        }
    }

    private func resetBrainMotionControllers(
        for packet: FlyWorldPosePacket,
        referenceTime: TimeInterval
    ) {
        let activeAgents = packet.displayAgents
        let activeIDs = Set(activeAgents.map(\.id))
        brainMotionControllers = brainMotionControllers.filter { activeIDs.contains($0.key) }

        for agent in activeAgents {
            var controller = brainMotionControllers[agent.id] ?? FlyWorldBrainDrivenMotionController()
            controller.reset(using: packet.packet(for: agent), referenceTime: referenceTime)
            brainMotionControllers[agent.id] = controller
        }
    }

    private func applyRootTransform(motion: FlyWorldMotionFrame, rig: FlyWorldBuild) {
        let simulationPosition = motion.rootPositionMm
        rig.poseAnchor.position = SIMD3<Float>(
            simulationPosition.x * millimeterScale,
            simulationPosition.z * millimeterScale,
            -simulationPosition.y * millimeterScale
        )

        let packetOrientation = motion.rootQuaternion
        rig.poseAnchor.orientation =
            simulationToSceneRotation * packetOrientation * simulationToSceneRotation.inverse
    }

    private func applyBehaviorState(
        packet: FlyWorldPosePacket,
        motion: FlyWorldMotionFrame,
        rig: FlyWorldBuild
    ) {
        let phase = motion.gaitPhase
        let legPoses = resolveLegPoses(
            packet: packet,
            motion: motion,
            phase: phase
        )

        for pose in legPoses {
            guard let legRig = rig.legs[pose.id] else { continue }
            retargetLeg(legRig, pose: pose)
        }

        applyProboscis(rig: rig, feedDrive: motion.feedDrive, phase: phase)
        applyWingMotion(
            rig: rig,
            behavior: motion.behavior,
            escapeDrive: motion.escapeDrive,
            strideDrive: (motion.leftStrideDrive + motion.rightStrideDrive) * 0.5,
            phase: phase
        )
        applyBrainHalo(rig: rig, brainDrive: motion.brainDrive, behavior: motion.behavior, phase: phase)
    }

    private func resolveLegPoses(
        packet: FlyWorldPosePacket,
        motion: FlyWorldMotionFrame,
        phase: Float
    ) -> [FlyWorldLegPose] {
        FlyWorldLegID.allCases.map { leg in
            if motionMode == .directPose,
               let directAngles = packet.directLegAngles(for: leg) {
                return FlyWorldLegKinematics.pose(
                    leg: leg,
                    directAngles: directAngles
                )
            }

            return FlyWorldLegKinematics.pose(
                leg: leg,
                packet: packet,
                gaitPhase: phase,
                leftStrideDrive: motion.leftStrideDrive,
                rightStrideDrive: motion.rightStrideDrive,
                behavior: motion.behavior
            )
        }
    }

    private func retargetLeg(
        _ rig: FlyWorldLegRig,
        pose: FlyWorldLegPose
    ) {
        FlyWorldEntityFactory.retargetBone(rig.upper, from: pose.shoulder, to: pose.knee, radius: rig.upperRadius)
        FlyWorldEntityFactory.retargetBone(rig.lower, from: pose.knee, to: pose.ankle, radius: rig.lowerRadius)
        FlyWorldEntityFactory.retargetBone(rig.tarsus, from: pose.ankle, to: pose.tip, radius: rig.tarsusRadius)
    }

    private func applyProboscis(rig: FlyWorldBuild, feedDrive: Float, phase: Float) {
        let extensionAmount = 1.0 + min(max(feedDrive, 0.0), 1.2) * 0.9 + max(0.0, sin(phase * 8.0)) * 0.04
        let end = rig.proboscisStart + (rig.proboscisEnd - rig.proboscisStart) * extensionAmount
        FlyWorldEntityFactory.retargetBone(
            rig.proboscis,
            from: rig.proboscisStart,
            to: end,
            radius: rig.proboscisRadius
        )
    }

    private func applyWingMotion(
        rig: FlyWorldBuild,
        behavior: String,
        escapeDrive: Float,
        strideDrive: Float,
        phase: Float
    ) {
        let flapDrive = FlyWorldPresentationTuning.wingFlapDrive(
            behavior: behavior,
            escapeDrive: escapeDrive,
            strideDrive: strideDrive
        )
        let flapFrequency = FlyWorldPresentationTuning.wingFlapFrequency(
            behavior: behavior,
            strideDrive: strideDrive
        )
        let flap = flapDrive * sin(phase * flapFrequency)
        rig.leftWing.orientation =
            rig.leftWingBaseOrientation
            * simd_quatf(angle: flap * 0.35, axis: SIMD3<Float>(0.0, 0.0, 1.0))
        rig.rightWing.orientation =
            rig.rightWingBaseOrientation
            * simd_quatf(angle: -flap * 0.35, axis: SIMD3<Float>(0.0, 0.0, 1.0))
    }

    private func applyBrainHalo(
        rig: FlyWorldBuild,
        brainDrive: Float,
        behavior: String,
        phase: Float
    ) {
        let clamped = min(max(brainDrive, 0.0), 1.2)
        let pulse = 1.0 + clamped * 0.18 + max(0.0, sin(phase * 6.0)) * 0.03
        rig.brainHalo.scale = rig.brainHaloBaseScale * pulse

        let color: PlatformColor
        switch behavior {
        case "fly":
            color = FlyWorldEntityFactory.color(0.62, 0.30, 0.96)
        case "feed":
            color = FlyWorldEntityFactory.color(0.98, 0.74, 0.22)
        case "escape":
            color = FlyWorldEntityFactory.color(1.0, 0.28, 0.20)
        case "groom":
            color = FlyWorldEntityFactory.color(0.88, 0.92, 0.26)
        default:
            color = FlyWorldEntityFactory.color(0.18, 0.52, 0.95)
        }

        rig.brainHalo.model?.materials = [UnlitMaterial(color: color)]
        rig.brainHalo.components.set(OpacityComponent(opacity: 0.08 + clamped * 0.10))
    }

    private func updateWorldObjects(from objects: [FlyWorldPosePacket.WorldObject]) {
        for child in Array(worldObjectsRoot.children) {
            child.removeFromParent()
        }

        let effectiveObjects = objects.isEmpty ? Self.defaultWorldObjects : objects
        for object in effectiveObjects {
            worldObjectsRoot.addChild(makeWorldObjectEntity(object))
        }
    }

    private func makeWorldObjectEntity(_ object: FlyWorldPosePacket.WorldObject) -> Entity {
        let kind = object.kind.lowercased()
        let sizeMm = object.sizeVector ?? defaultWorldObjectSize(for: kind)
        let size = SIMD3<Float>(
            max(sizeMm.x * millimeterScale, 0.02),
            max(sizeMm.y * millimeterScale, 0.02),
            max(sizeMm.z * millimeterScale, 0.02)
        )

        let color = FlyWorldEntityFactory.color(from: object.color, fallbackKind: kind)
        let opacity = object.opacity ?? defaultOpacity(for: kind)
        let position = SIMD3<Float>(
            object.positionVector.x * millimeterScale,
            floorY + size.y * 0.5 + object.positionVector.z * millimeterScale,
            -object.positionVector.y * millimeterScale
        )

        let base: ModelEntity
        switch kind {
        case "food":
            base = ModelEntity(
                mesh: .generateCylinder(height: max(size.y, 0.03), radius: max(size.x, 0.03) * 0.55),
                materials: [SimpleMaterial(color: color, isMetallic: false)]
            )
        case "drink":
            base = ModelEntity(
                mesh: .generateCylinder(height: max(size.y, 0.008), radius: max(size.x, 0.03) * 0.6),
                materials: [UnlitMaterial(color: color)]
            )
        case "odor":
            base = ModelEntity(
                mesh: .generateSphere(radius: max(size.x, 0.03) * 0.5),
                materials: [UnlitMaterial(color: color)]
            )
        case "visualtarget", "visual_target":
            base = ModelEntity(
                mesh: .generateSphere(radius: max(size.x, 0.03) * 0.5),
                materials: [UnlitMaterial(color: color)]
            )
        default:
            base = ModelEntity(
                mesh: .generateBox(size: size, cornerRadius: min(size.x, size.z) * 0.18),
                materials: [SimpleMaterial(color: color, roughness: 0.45, isMetallic: false)]
            )
        }

        base.name = object.id
        base.position = position
        base.components.set(OpacityComponent(opacity: opacity))
        return base
    }

    private func defaultWorldObjectSize(for kind: String) -> SIMD3<Float> {
        switch kind {
        case "drink":
            return SIMD3<Float>(1.6, 0.2, 1.6)
        case "food":
            return SIMD3<Float>(1.8, 0.9, 1.8)
        case "odor":
            return SIMD3<Float>(2.2, 2.2, 2.2)
        case "visualtarget", "visual_target":
            return SIMD3<Float>(1.4, 1.4, 1.4)
        default:
            return SIMD3<Float>(2.1, 1.3, 2.1)
        }
    }

    private func defaultOpacity(for kind: String) -> Float {
        switch kind {
        case "drink":
            return 0.82
        case "odor":
            return 0.18
        case "visualtarget", "visual_target":
            return 0.88
        default:
            return 0.72
        }
    }

    private func refreshMetadata(
        packet: FlyWorldPosePacket,
        source: FlyWorldPosePacketSource?,
        behavior: String
    ) {
        guard let current = metadata else { return }
        metadata = FlyWorldSceneMetadata(
            graphSourceLabel: current.graphSourceLabel,
            graphSourceLocation: current.graphSourceLocation,
            graphNodeCount: current.graphNodeCount,
            graphEdgeCount: current.graphEdgeCount,
            graphNotes: current.graphNotes,
            poseSourceLabel: source?.label,
            poseSourceLocation: source?.location,
            behavior: behavior,
            jointCount: packet.jointAnglesRad.count,
            brainChannelCount: packet.brainState.count,
            worldObjectCount: packet.worldObjectsOrDefault.isEmpty ? Self.defaultWorldObjects.count : packet.worldObjectsOrDefault.count,
            packetTimestamp: packet.timestamp,
            packetAgeDescription: FlyWorldSceneMetadata.packetAgeDescription(for: packet.timestamp)
        )
    }

    private func refreshPacketAge(referenceDate: Date) {
        guard let current = metadata else { return }
        metadata = FlyWorldSceneMetadata(
            graphSourceLabel: current.graphSourceLabel,
            graphSourceLocation: current.graphSourceLocation,
            graphNodeCount: current.graphNodeCount,
            graphEdgeCount: current.graphEdgeCount,
            graphNotes: current.graphNotes,
            poseSourceLabel: current.poseSourceLabel,
            poseSourceLocation: current.poseSourceLocation,
            behavior: current.behavior,
            jointCount: current.jointCount,
            brainChannelCount: current.brainChannelCount,
            worldObjectCount: current.worldObjectCount,
            packetTimestamp: current.packetTimestamp,
            packetAgeDescription: FlyWorldSceneMetadata.packetAgeDescription(
                for: current.packetTimestamp,
                referenceDate: referenceDate
            )
        )
    }

    private func packetSignature(
        for packet: FlyWorldPosePacket,
        source: FlyWorldPosePacketSource
    ) -> String {
        [
            source.location ?? "bundle",
            source.modificationDate?.formatted(date: .numeric, time: .standard) ?? "none",
            String(packet.timestamp),
            packet.behavior,
            String(packet.displayAgents.count)
        ].joined(separator: "|")
    }

    private func buildArena() {
        let floor = ModelEntity(
            mesh: .generateCylinder(height: 0.008, radius: FlyWorldLegKinematics.arenaRadiusScene),
            materials: [SimpleMaterial(color: FlyWorldEntityFactory.color(0.64, 0.58, 0.42), roughness: 0.98, isMetallic: false)]
        )
        floor.position = SIMD3<Float>(0.0, floorY, 0.0)
        arenaRoot.addChild(floor)

        let floorTint = ModelEntity(
            mesh: .generateCylinder(height: 0.002, radius: 0.36),
            materials: [UnlitMaterial(color: FlyWorldEntityFactory.color(0.58, 0.49, 0.34))]
        )
        floorTint.position = SIMD3<Float>(0.0, floorY + 0.004, 0.0)
        floorTint.components.set(OpacityComponent(opacity: 0.22))
        arenaRoot.addChild(floorTint)

        let drinkDish = ModelEntity(
            mesh: .generateCylinder(height: 0.012, radius: 0.08),
            materials: [SimpleMaterial(color: FlyWorldEntityFactory.color(0.22, 0.22, 0.24), roughness: 0.72, isMetallic: false)]
        )
        drinkDish.position = SIMD3<Float>(0.17, floorY + 0.005, 0.11)
        arenaRoot.addChild(drinkDish)

        let drinkSurface = ModelEntity(
            mesh: .generateCylinder(height: 0.004, radius: 0.062),
            materials: [UnlitMaterial(color: FlyWorldEntityFactory.color(0.32, 0.76, 0.96))]
        )
        drinkSurface.position = SIMD3<Float>(0.17, floorY + 0.012, 0.11)
        drinkSurface.components.set(OpacityComponent(opacity: 0.82))
        arenaRoot.addChild(drinkSurface)

        let targetMarker = ModelEntity(
            mesh: .generateSphere(radius: 0.018),
            materials: [UnlitMaterial(color: FlyWorldEntityFactory.color(0.98, 0.34, 0.22))]
        )
        targetMarker.position = SIMD3<Float>(-0.18, floorY + 0.030, -0.16)
        targetMarker.components.set(OpacityComponent(opacity: 0.88))
        arenaRoot.addChild(targetMarker)
    }

    private static func makeFallbackPacket() -> FlyWorldPosePacket {
        FlyWorldPosePacket(
            timestamp: Date().timeIntervalSince1970,
            rootPositionMm: [0.0, 0.0, 0.2],
            rootQuaternionXyzw: [0.0, 0.0, 0.0, 1.0],
            jointAnglesRad: [
                "LFCoxa": 0.16,
                "LFFemur": -0.22,
                "LFTibia": 0.28,
                "RFCoxa": -0.16,
                "RFFemur": -0.18,
                "RFTibia": 0.24
            ],
            brainState: [
                "DNa01": 0.14,
                "DNa02": 0.13,
                "oDN1": 0.46,
                "aDN1": 0.0,
                "MN9": 0.0,
                "loom_escape": 0.0
            ],
            behavior: "walk",
            worldObjects: defaultWorldObjects
        )
    }

    private static let defaultWorldObjects: [FlyWorldPosePacket.WorldObject] = [
        FlyWorldPosePacket.WorldObject(
            id: "nectar-dish",
            kind: "drink",
            label: "Nectar",
            positionMm: [1.4, -0.9, 0.0],
            sizeMm: [1.6, 0.3, 1.6],
            color: [0.34, 0.72, 0.95],
            opacity: 0.82
        ),
        FlyWorldPosePacket.WorldObject(
            id: "odor-source",
            kind: "odor",
            label: "Odor",
            positionMm: [-3.2, 1.8, 0.4],
            sizeMm: [2.4, 2.4, 2.4],
            color: [0.26, 0.82, 0.72],
            opacity: 0.16
        ),
        FlyWorldPosePacket.WorldObject(
            id: "visual-target",
            kind: "visual_target",
            label: "Target",
            positionMm: [-2.4, 2.6, 1.0],
            sizeMm: [1.4, 1.4, 1.4],
            color: [1.0, 0.22, 0.18],
            opacity: 0.92
        ),
        FlyWorldPosePacket.WorldObject(
            id: "obstacle",
            kind: "obstacle",
            label: "Obstacle",
            positionMm: [2.0, 1.8, 0.0],
            sizeMm: [2.0, 1.0, 1.6],
            color: [0.46, 0.50, 0.56],
            opacity: 0.76
        )
    ]
}

private struct FlyWorldBuild {
    let root: Entity
    let poseAnchor: Entity
    let legs: [FlyWorldLegID: FlyWorldLegRig]
    let leftWing: ModelEntity
    let rightWing: ModelEntity
    let leftWingBaseOrientation: simd_quatf
    let rightWingBaseOrientation: simd_quatf
    let proboscis: ModelEntity
    let proboscisStart: SIMD3<Float>
    let proboscisEnd: SIMD3<Float>
    let proboscisRadius: Float
    let brainHalo: ModelEntity
    let brainHaloBaseScale: SIMD3<Float>
}

private struct FlyWorldLegRig {
    let upper: ModelEntity
    let lower: ModelEntity
    let tarsus: ModelEntity
    let shoulder: SIMD3<Float>
    let knee: SIMD3<Float>
    let ankle: SIMD3<Float>
    let tip: SIMD3<Float>
    let upperRadius: Float
    let lowerRadius: Float
    let tarsusRadius: Float
}

@MainActor
private enum FlyWorldEntityFactory {
    private static let unitSphereMesh = MeshResource.generateSphere(radius: 1.0)
    private static let unitBoxMesh = MeshResource.generateBox(
        size: SIMD3<Float>(1.0, 1.0, 1.0),
        cornerRadius: 0.08
    )
    private static let unitCylinderMesh = MeshResource.generateCylinder(height: 1.0, radius: 1.0)

    static func makeScene(graph: FlyWorldGraph, includeBrainGraph: Bool = true, brainDetailScale: Float = 1.0) -> FlyWorldBuild {
        let sceneRoot = Entity()
        let poseAnchor = Entity()
        let flyRoot = Entity()
        flyRoot.name = "WholeFly"
        flyRoot.position = SIMD3<Float>(0.0, FlyWorldLegKinematics.flyRootVerticalBiasScene, 0.0)
        flyRoot.scale = SIMD3<Float>(repeating: FlyWorldLegKinematics.flyGeometryScale)
        flyRoot.orientation = FlyWorldPresentationTuning.bodyBaseOrientation

        sceneRoot.addChild(poseAnchor)
        poseAnchor.addChild(flyRoot)

        let amber = SimpleMaterial(color: color(0.88, 0.67, 0.27), isMetallic: false)
        let golden = SimpleMaterial(color: color(0.84, 0.56, 0.22), isMetallic: false)
        let brown = SimpleMaterial(color: color(0.28, 0.18, 0.08), isMetallic: false)
        let darkBrown = SimpleMaterial(color: color(0.16, 0.11, 0.05), isMetallic: false)
        let eye = UnlitMaterial(color: color(0.90, 0.12, 0.06))
        let wingMaterial = UnlitMaterial(color: color(0.88, 0.95, 1.0))
        let proboscisMaterial = SimpleMaterial(color: color(0.35, 0.21, 0.10), isMetallic: false)

        let exoskeletonOpacity: Float = 0.42
        let wingOpacity: Float = 0.22

        flyRoot.addChild(
            makeSphere(
                name: "Thorax",
                radii: SIMD3<Float>(0.15, 0.12, 0.12),
                position: SIMD3<Float>(0.0, 0.0, 0.0),
                material: amber,
                opacity: exoskeletonOpacity
            )
        )

        flyRoot.addChild(
            makeSphere(
                name: "Head",
                radii: SIMD3<Float>(0.095, 0.085, 0.085),
                position: SIMD3<Float>(-0.19, 0.02, 0.0),
                material: amber,
                opacity: 0.34
            )
        )

        flyRoot.addChild(
            makeBone(
                name: "Neck",
                from: SIMD3<Float>(-0.12, 0.01, 0.0),
                to: SIMD3<Float>(-0.05, 0.0, 0.0),
                radius: 0.018,
                material: brown,
                opacity: 0.65
            )
        )

        flyRoot.addChild(
            makeSphere(
                name: "AbdomenBase",
                radii: SIMD3<Float>(0.12, 0.09, 0.09),
                position: SIMD3<Float>(0.17, -0.01, 0.0),
                material: golden,
                opacity: exoskeletonOpacity
            )
        )

        flyRoot.addChild(
            makeSphere(
                name: "AbdomenMid",
                radii: SIMD3<Float>(0.14, 0.085, 0.085),
                position: SIMD3<Float>(0.29, -0.02, 0.0),
                material: golden,
                opacity: exoskeletonOpacity
            )
        )

        flyRoot.addChild(
            makeSphere(
                name: "AbdomenTip",
                radii: SIMD3<Float>(0.10, 0.055, 0.055),
                position: SIMD3<Float>(0.41, -0.03, 0.0),
                material: golden,
                opacity: exoskeletonOpacity
            )
        )

        let stripePositions: [Float] = [0.18, 0.26, 0.34, 0.40]
        for (stripeIndex, stripeX) in stripePositions.enumerated() {
            flyRoot.addChild(
                makeBox(
                    name: "Stripe\(stripeIndex)",
                    size: SIMD3<Float>(0.016, 0.125, 0.16),
                    position: SIMD3<Float>(stripeX, -0.02 - Float(stripeIndex) * 0.002, 0.0),
                    rotation: simd_quatf(angle: 0.0, axis: SIMD3<Float>(0.0, 1.0, 0.0)),
                    material: darkBrown,
                    opacity: 0.64
                )
            )
        }

        flyRoot.addChild(
            makeSphere(
                name: "LeftEye",
                radii: SIMD3<Float>(0.045, 0.045, 0.045),
                position: SIMD3<Float>(-0.255, 0.04, 0.058),
                material: eye,
                opacity: 0.96
            )
        )

        flyRoot.addChild(
            makeSphere(
                name: "RightEye",
                radii: SIMD3<Float>(0.045, 0.045, 0.045),
                position: SIMD3<Float>(-0.255, 0.04, -0.058),
                material: eye,
                opacity: 0.96
            )
        )

        let proboscisStart = SIMD3<Float>(-0.26, -0.015, 0.0)
        let proboscisEnd = SIMD3<Float>(-0.34, -0.075, 0.0)
        let proboscisRadius: Float = 0.010
        let proboscis = makeBone(
            name: "Proboscis",
            from: proboscisStart,
            to: proboscisEnd,
            radius: proboscisRadius,
            material: proboscisMaterial,
            opacity: 0.85
        )
        flyRoot.addChild(proboscis)

        var leftWing: ModelEntity?
        var rightWing: ModelEntity?
        var leftWingBaseOrientation = simd_quatf(angle: 0.0, axis: SIMD3<Float>(0.0, 1.0, 0.0))
        var rightWingBaseOrientation = leftWingBaseOrientation
        var builtLegs: [FlyWorldLegID: FlyWorldLegRig] = [:]

        for side in [Float(-1.0), Float(1.0)] {
            let antenna = makeBone(
                name: side < 0 ? "LeftAntenna" : "RightAntenna",
                from: SIMD3<Float>(-0.275, 0.07, side * 0.02),
                to: SIMD3<Float>(-0.34, 0.115, side * 0.055),
                radius: 0.006,
                material: brown,
                opacity: 0.88
            )
            flyRoot.addChild(antenna)

            let arista = makeBone(
                name: side < 0 ? "LeftArista" : "RightArista",
                from: SIMD3<Float>(-0.34, 0.115, side * 0.055),
                to: SIMD3<Float>(-0.37, 0.155, side * 0.085),
                radius: 0.003,
                material: darkBrown,
                opacity: 0.88
            )
            flyRoot.addChild(arista)

            let wingRotation =
                simd_quatf(angle: side * Float.pi / 7.5, axis: SIMD3<Float>(1.0, 0.0, 0.0)) *
                simd_quatf(angle: side * Float.pi / 9.0, axis: SIMD3<Float>(0.0, 1.0, 0.0)) *
                simd_quatf(angle: Float.pi / 30.0, axis: SIMD3<Float>(0.0, 0.0, 1.0))

            let wing = makeBox(
                name: side < 0 ? "LeftWing" : "RightWing",
                size: SIMD3<Float>(0.27, 0.004, 0.15),
                position: SIMD3<Float>(0.04, 0.11, side * 0.125),
                rotation: wingRotation,
                material: wingMaterial,
                opacity: wingOpacity
            )
            flyRoot.addChild(wing)

            if side < 0 {
                leftWing = wing
                leftWingBaseOrientation = wingRotation
            } else {
                rightWing = wing
                rightWingBaseOrientation = wingRotation
            }

            flyRoot.addChild(
                makeBone(
                    name: side < 0 ? "LeftHaltereStem" : "RightHaltereStem",
                    from: SIMD3<Float>(0.10, 0.015, side * 0.07),
                    to: SIMD3<Float>(0.15, -0.01, side * 0.13),
                    radius: 0.0045,
                    material: brown,
                    opacity: 0.72
                )
            )

            flyRoot.addChild(
                makeSphere(
                    name: side < 0 ? "LeftHaltereClub" : "RightHaltereClub",
                    radii: SIMD3<Float>(0.015, 0.015, 0.015),
                    position: SIMD3<Float>(0.15, -0.01, side * 0.13),
                    material: wingMaterial,
                    opacity: 0.45
                )
            )

            let legSet = makeLegSet(on: flyRoot, side: side, material: brown)
            if side < 0 {
                builtLegs[.leftFront] = legSet.front
                builtLegs[.leftMid] = legSet.mid
                builtLegs[.leftHind] = legSet.hind
            } else {
                builtLegs[.rightFront] = legSet.front
                builtLegs[.rightMid] = legSet.mid
                builtLegs[.rightHind] = legSet.hind
            }
        }

        let nodeBudget = max(8, Int(Float(80) * brainDetailScale))
        let edgeBudget = max(16, Int(Float(150) * brainDetailScale))
        let brain = makeBrainGraphEntity(
            graph,
            maxNodes: nodeBudget,
            maxEdges: edgeBudget,
            includeGraph: includeBrainGraph
        )
        flyRoot.addChild(brain.root)

#if os(visionOS)
        flyRoot.components.set(InputTargetComponent())
        flyRoot.components.set(HoverEffectComponent())
#endif

        return FlyWorldBuild(
            root: sceneRoot,
            poseAnchor: poseAnchor,
            legs: FlyWorldLegID.allCases.reduce(into: [:]) { result, leg in
                result[leg] = builtLegs[leg] ?? makeFallbackLegRig(for: leg)
            },
            leftWing: leftWing ?? ModelEntity(),
            rightWing: rightWing ?? ModelEntity(),
            leftWingBaseOrientation: leftWingBaseOrientation,
            rightWingBaseOrientation: rightWingBaseOrientation,
            proboscis: proboscis,
            proboscisStart: proboscisStart,
            proboscisEnd: proboscisEnd,
            proboscisRadius: proboscisRadius,
            brainHalo: brain.halo,
            brainHaloBaseScale: brain.halo.scale
        )
    }

    static func retargetBone(
        _ entity: ModelEntity,
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        radius: Float
    ) {
        let delta = end - start
        let length = max(simd_length(delta), 0.0001)
        let midpoint = (start + end) * 0.5
        let direction = delta / length

        entity.position = midpoint
        entity.scale = SIMD3<Float>(radius, length, radius)
        entity.orientation = simd_quatf(from: SIMD3<Float>(0.0, 1.0, 0.0), to: direction)
    }

    static func color(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1.0) -> PlatformColor {
        PlatformColor(
            red: CGFloat(r),
            green: CGFloat(g),
            blue: CGFloat(b),
            alpha: CGFloat(a)
        )
    }

    static func color(from rgb: [Float]?, fallbackKind: String) -> PlatformColor {
        guard let rgb, rgb.count >= 3 else {
            switch fallbackKind {
            case "drink":
                return color(0.34, 0.72, 0.95)
            case "food":
                return color(0.98, 0.78, 0.26)
            case "odor":
                return color(0.24, 0.84, 0.74)
            case "visualtarget", "visual_target":
                return color(1.0, 0.22, 0.18)
            default:
                return color(0.56, 0.60, 0.66)
            }
        }
        return color(rgb[0], rgb[1], rgb[2])
    }

    private static func makeLegSet(on root: Entity, side: Float, material: any Material) -> (front: FlyWorldLegRig, mid: FlyWorldLegRig, hind: FlyWorldLegRig) {
        let legIDs: [FlyWorldLegID] = side < 0
            ? [.leftFront, .leftMid, .leftHind]
            : [.rightFront, .rightMid, .rightHind]
        var rigs: [FlyWorldLegRig] = []
        for leg in legIDs {
            let geometry = FlyWorldLegKinematics.geometry(for: leg)
            let radii = FlyWorldLegKinematics.radii(for: leg)
            let upper = makeBone(
                name: "Leg\(leg.prefix)Upper",
                from: geometry.shoulder,
                to: geometry.knee,
                radius: radii.0,
                material: material,
                opacity: 0.88
            )
            root.addChild(upper)

            let lower = makeBone(
                name: "Leg\(leg.prefix)Lower",
                from: geometry.knee,
                to: geometry.ankle,
                radius: radii.1,
                material: material,
                opacity: 0.88
            )
            root.addChild(lower)

            let tarsus = makeBone(
                name: "Leg\(leg.prefix)Tarsus",
                from: geometry.ankle,
                to: geometry.tip,
                radius: radii.2,
                material: material,
                opacity: 0.88
            )
            root.addChild(tarsus)

            rigs.append(
                FlyWorldLegRig(
                    upper: upper,
                    lower: lower,
                    tarsus: tarsus,
                    shoulder: geometry.shoulder,
                    knee: geometry.knee,
                    ankle: geometry.ankle,
                    tip: geometry.tip,
                    upperRadius: radii.0,
                    lowerRadius: radii.1,
                    tarsusRadius: radii.2
                )
            )
        }

        return (rigs[0], rigs[1], rigs[2])
    }

    private static func makeBrainGraphEntity(_ graph: FlyWorldGraph, maxNodes: Int = 80, maxEdges: Int = 150, includeGraph: Bool = true) -> (root: Entity, halo: ModelEntity) {
        let brainRoot = Entity()
        brainRoot.name = "BrainGraph"
        brainRoot.position = SIMD3<Float>(-0.195, 0.03, 0.0)

        if includeGraph {
            let nodeLimit = min(graph.nodes.count, maxNodes)
            let limitedNodes = Array(graph.nodes.prefix(nodeLimit))
            let brainScale: Float = 0.060

            var positions: [SIMD3<Float>] = []
            positions.reserveCapacity(limitedNodes.count)
            for node in limitedNodes {
                positions.append(node.position * brainScale)
            }

            let edgeMaterial = UnlitMaterial(color: color(0.32, 0.75, 1.0))
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
                let nodeColor = color(from: node.color, fallbackKind: (node.isFocus ?? false) ? "focus" : "graph")
                let nodeMaterial = UnlitMaterial(color: nodeColor)
                let radius = max(0.0024, (node.size ?? 0.020) * 0.20)
                let nodeEntity = ModelEntity(mesh: unitSphereMesh, materials: [nodeMaterial])
                nodeEntity.name = "BrainNode\(index)"
                nodeEntity.position = positions[index]
                nodeEntity.scale = SIMD3<Float>(repeating: radius)
                nodeEntity.components.set(OpacityComponent(opacity: 0.92))
                brainRoot.addChild(nodeEntity)
            }
        }

        let halo = makeSphere(
            name: "BrainHalo",
            radii: SIMD3<Float>(0.085, 0.072, 0.072),
            position: SIMD3<Float>(0.0, 0.0, 0.0),
            material: UnlitMaterial(color: color(0.18, 0.52, 0.95)),
            opacity: 0.08
        )
        brainRoot.addChild(halo)
        return (brainRoot, halo)
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
        retargetBone(entity, from: start, to: end, radius: radius)
        if let opacity {
            entity.components.set(OpacityComponent(opacity: opacity))
        }
        return entity
    }

    private static func makeFallbackLegRig(for leg: FlyWorldLegID) -> FlyWorldLegRig {
        let dummy = ModelEntity(mesh: unitCylinderMesh, materials: [])
        let geometry = FlyWorldLegKinematics.geometry(for: leg)
        let radii = FlyWorldLegKinematics.radii(for: leg)
        return FlyWorldLegRig(
            upper: dummy,
            lower: dummy,
            tarsus: dummy,
            shoulder: geometry.shoulder,
            knee: geometry.knee,
            ankle: geometry.ankle,
            tip: geometry.tip,
            upperRadius: radii.0,
            lowerRadius: radii.1,
            tarsusRadius: radii.2
        )
    }
}
