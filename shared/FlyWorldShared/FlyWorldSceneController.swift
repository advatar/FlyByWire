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
    #if os(macOS)
    static let defaultPacketURLString = "http://127.0.0.1:8765/pose"
    #else
    static let defaultPacketURLString = ""
    #endif

    let root = Entity()

    private let arenaRoot = Entity()
    private let worldObjectsRoot = Entity()
    private let evolutionRoot = Entity()
    private var graph: FlyWorldGraph?
    private var rig: FlyWorldBuild?
    private var extraRigs: [String: FlyWorldBuild] = [:]
    private var evolutionVisual: FlyWorldEvolutionVisual?
    private var poseTask: Task<Void, Never>?
    private var latestPacket: FlyWorldPosePacket?
    private var latestPoseSource: FlyWorldPosePacketSource?
    private var lastPacketSignature: String?
    private var isLoaded = false
    private var motionMode: FlyWorldMotionMode = .brainDrivenFallback
    private var brainMotionControllers: [String: FlyWorldBrainDrivenMotionController] = [:]
    private var deathAnimations: [String: FlyWorldDeathAnimation] = [:]
    #if os(macOS)
    private var localPoseServerProcess: Process?
    private var localPoseServerPipe: Pipe?
    #endif

    private let floorY: Float = FlyWorldLegKinematics.arenaFloorSceneY
    private let millimeterScale: Float = FlyWorldLegKinematics.sceneMillimeterScale
    private let simulationToSceneRotation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1.0, 0.0, 0.0))

    private(set) var metadata: FlyWorldSceneMetadata?
    private(set) var errorMessage: String?
    private(set) var poseServerStatus: String?
    var packetURLString: String = FlyWorldSceneController.defaultPacketURLString

    init() {
        root.addChild(arenaRoot)
        root.addChild(worldObjectsRoot)
        root.addChild(evolutionRoot)
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
        startLocalPoseServerIfNeeded()
        poseTask = Task { [weak self] in
            await self?.runPoseLoop(bundle: bundle)
        }
    }

    func stopPoseUpdates() {
        poseTask?.cancel()
        poseTask = nil
    }

    func stopLocalPoseServer() {
        #if os(macOS)
        localPoseServerPipe?.fileHandleForReading.readabilityHandler = nil
        if let process = localPoseServerProcess, process.isRunning {
            process.terminate()
        }
        localPoseServerProcess = nil
        localPoseServerPipe = nil
        #endif
    }

    func startLocalPoseServerIfNeeded() {
        #if os(macOS)
        guard localPoseServerProcess == nil else { return }
        guard isDefaultLocalPoseURL(packetURLString) else { return }
        guard !isRunningUnderXCTest() else { return }
        guard let simulationDirectory = resolveSimulationDirectory() else {
            updatePoseServerStatus("Simulation directory not found. Set LEARNING_TO_FLY_ROOT to the LearningToFly checkout.")
            return
        }

        let scriptURL = simulationDirectory.appendingPathComponent("run_live_multi_fly.py")
        let outputURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("vision_pro_pose_packet.json")

        let launcher = localPythonLauncher(for: simulationDirectory.deletingLastPathComponent())
        let process = Process()
        process.executableURL = launcher.executableURL
        var arguments = launcher.arguments
        arguments.append(contentsOf: [
            scriptURL.path,
            "--output",
            outputURL?.path ?? (NSHomeDirectory() + "/Documents/vision_pro_pose_packet.json"),
            "--http-host",
            "0.0.0.0",
            "--http-port",
            "8765"
        ])
        process.arguments = arguments
        process.currentDirectoryURL = simulationDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let line = text
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                self?.updatePoseServerStatus(line.isEmpty ? "Starting local pose server..." : line)
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.updatePoseServerStatus("Local pose server exited with status \(process.terminationStatus).")
                self?.localPoseServerProcess = nil
                self?.localPoseServerPipe?.fileHandleForReading.readabilityHandler = nil
                self?.localPoseServerPipe = nil
            }
        }

        do {
            updatePoseServerStatus("Launching local pose server with \(launcher.executableURL.path) ...")
            try process.run()
            localPoseServerProcess = process
            localPoseServerPipe = pipe
            updatePoseServerStatus("Starting local pose server on http://127.0.0.1:8765/pose...")
        } catch {
            updatePoseServerStatus("Could not start local pose server: \(error.localizedDescription)")
        }
        #endif
    }

    func setSceneScale(_ scale: Float) {
        root.scale = SIMD3<Float>(repeating: scale)
    }

    private func runPoseLoop(bundle: Bundle) async {
        var frameIndex = 1
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
        agentID: String,
        neighborsMm: [SIMD2<Float>] = []
    ) -> FlyWorldMotionFrame {
        switch motionMode {
        case .directPose:
            return FlyWorldMotionFrame.directPose(packet: packet, time: time)
        case .brainDrivenFallback:
            var controller = brainMotionControllers[agentID] ?? {
                var controller = FlyWorldBrainDrivenMotionController()
                controller.phaseSeed = phaseSeed(for: agentID)
                return controller
            }()
            let motion = controller.synthesize(packet: packet, time: time, neighborsMm: neighborsMm)
            brainMotionControllers[agentID] = controller
            return motion
        }
    }

    private func neighborPositions(excluding agentID: String) -> [SIMD2<Float>] {
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(brainMotionControllers.count)
        for (id, controller) in brainMotionControllers where id != agentID {
            result.append(controller.currentPlanarPositionMm)
        }
        return result
    }

    private func render(packet: FlyWorldPosePacket, time: TimeInterval) -> String {
        syncExtraRigs(for: packet.displayAgents)

        var primaryBehavior = packet.behavior
        var renderedAgents: [FlyWorldRenderedAgentState] = []
        renderedAgents.reserveCapacity(packet.displayAgents.count)
        for (index, agent) in packet.displayAgents.enumerated() {
            let agentPacket = packet.packet(for: agent)
            let neighbors = neighborPositions(excluding: agent.id)
            let motion = resolveMotionFrame(
                packet: agentPacket,
                time: time,
                agentID: agent.id,
                neighborsMm: neighbors
            )
            let displayMotion = deathAdjustedMotion(
                packet: agentPacket,
                motion: motion,
                agentID: agent.id,
                time: time
            )
            guard let build = rig(for: agent, index: index) else { continue }
            applyRootTransform(motion: displayMotion, rig: build)
            applyBehaviorState(packet: agentPacket, motion: displayMotion, rig: build)
            renderedAgents.append(
                FlyWorldRenderedAgentState(
                    id: agent.id,
                    label: agent.label,
                    generation: agent.generation,
                    score: agent.score,
                    genomeSummary: agent.genomeSummary,
                    positionMm: displayMotion.rootPositionMm,
                    scenePosition: scenePosition(from: displayMotion.rootPositionMm),
                    behavior: displayMotion.behavior,
                    isDead: agentPacket.isDead
                )
            )
            if index == 0 {
                primaryBehavior = displayMotion.behavior
            }
        }

        updateEvolutionVisualization(
            packet: packet,
            renderedAgents: renderedAgents,
            time: time
        )

        return primaryBehavior
    }

    private func phaseSeed(for agentID: String) -> Float {
        var hasher = Hasher()
        hasher.combine(agentID)
        let hash = UInt32(truncatingIfNeeded: hasher.finalize())
        return Float(hash % 6283) / 1000.0  // 0 .. ~6.28 rad
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
            deathAnimations.removeValue(forKey: agentID)
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
            controller.phaseSeed = phaseSeed(for: agent.id)
            controller.reset(using: packet.packet(for: agent), referenceTime: referenceTime)
            brainMotionControllers[agent.id] = controller
        }
    }

    private func deathAdjustedMotion(
        packet: FlyWorldPosePacket,
        motion: FlyWorldMotionFrame,
        agentID: String,
        time: TimeInterval
    ) -> FlyWorldMotionFrame {
        guard packet.isDead else {
            deathAnimations.removeValue(forKey: agentID)
            return motion
        }

        let animation = deathAnimations[agentID] ?? {
            let seededSign: Float = deathFallSign(for: agentID)
            let startedAt = packet.deathTime ?? time
            let animation = FlyWorldDeathAnimation(
                startedAt: startedAt,
                initialPositionMm: motion.rootPositionMm,
                initialQuaternion: motion.rootQuaternion,
                fallSign: seededSign
            )
            deathAnimations[agentID] = animation
            return animation
        }()

        let elapsed = max(Float(time - animation.startedAt), 0.0)
        let normalizedElapsed = Swift.min(Swift.max(elapsed / 1.15, 0.0), 1.0)
        let progress = smoothstep(normalizedElapsed)
        let fallenPosition = SIMD3<Float>(
            animation.initialPositionMm.x,
            animation.initialPositionMm.y,
            min(animation.initialPositionMm.z, 0.2)
        )
        let rootPosition = animation.initialPositionMm + (fallenPosition - animation.initialPositionMm) * progress
        let fallRotation = simd_quatf(
            angle: animation.fallSign * Float.pi * 0.52,
            axis: SIMD3<Float>(1.0, 0.0, 0.0)
        )
        let fallenQuaternion = simd_normalize(fallRotation * animation.initialQuaternion)
        let rootQuaternion = simd_slerp(animation.initialQuaternion, fallenQuaternion, progress)

        return FlyWorldMotionFrame(
            rootPositionMm: rootPosition,
            rootQuaternion: rootQuaternion,
            leftStrideDrive: 0.0,
            rightStrideDrive: 0.0,
            gaitPhase: motion.gaitPhase,
            behavior: "dead",
            feedDrive: 0.0,
            escapeDrive: 0.0,
            brainDrive: 0.0
        )
    }

    private func deathFallSign(for agentID: String) -> Float {
        var hasher = Hasher()
        hasher.combine(agentID)
        return (hasher.finalize() & 1) == 0 ? 1.0 : -1.0
    }

    private func smoothstep(_ value: Float) -> Float {
        value * value * (3.0 - 2.0 * value)
    }

    private func applyRootTransform(motion: FlyWorldMotionFrame, rig: FlyWorldBuild) {
        let simulationPosition = motion.rootPositionMm
        rig.poseAnchor.position = scenePosition(from: simulationPosition)

        let packetOrientation = motion.rootQuaternion
        var orientation =
            simulationToSceneRotation * packetOrientation * simulationToSceneRotation.inverse

        if motion.behavior == "fly" {
            // Bank into the turn: tilt the body about its forward axis
            // proportionally to the current turn rate, clamped to ~±18°.
            let turnRate = motion.leftStrideDrive - motion.rightStrideDrive
            let rollMagnitude = max(-0.32, min(0.32, turnRate * 0.55))
            let forwardAxisScene = orientation.act(SIMD3<Float>(1.0, 0.0, 0.0))
            orientation = simd_quatf(angle: -rollMagnitude, axis: forwardAxisScene) * orientation
        }

        rig.poseAnchor.orientation = orientation
    }

    private func scenePosition(from simulationPosition: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            simulationPosition.x * millimeterScale,
            simulationPosition.z * millimeterScale,
            -simulationPosition.y * millimeterScale
        )
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
        let turnBias = motion.leftStrideDrive - motion.rightStrideDrive
        applyWingMotion(
            rig: rig,
            behavior: motion.behavior,
            escapeDrive: motion.escapeDrive,
            strideDrive: (motion.leftStrideDrive + motion.rightStrideDrive) * 0.5,
            turnBias: turnBias,
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
        turnBias: Float,
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
        // Banking: when leftStride > rightStride the fly turns right; the
        // inside (right) wing strokes shallower than the outside (left).
        let clampedBias = max(-1.0, min(1.0, turnBias))
        let leftGain: Float = 0.35 * (1.0 + clampedBias * 0.4)
        let rightGain: Float = 0.35 * (1.0 - clampedBias * 0.4)
        rig.leftWing.orientation =
            rig.leftWingBaseOrientation
            * simd_quatf(angle: flap * leftGain, axis: SIMD3<Float>(0.0, 0.0, 1.0))
        rig.rightWing.orientation =
            rig.rightWingBaseOrientation
            * simd_quatf(angle: -flap * rightGain, axis: SIMD3<Float>(0.0, 0.0, 1.0))
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
        case "dead":
            color = FlyWorldEntityFactory.color(0.34, 0.35, 0.36)
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
        let opacity: Float = behavior == "dead" ? 0.035 : 0.08 + clamped * 0.10
        rig.brainHalo.components.set(OpacityComponent(opacity: opacity))
    }

    private func updateEvolutionVisualization(
        packet: FlyWorldPosePacket,
        renderedAgents: [FlyWorldRenderedAgentState],
        time: TimeInterval
    ) {
        guard let pair = selectedMatingPair(packet: packet, renderedAgents: renderedAgents) else {
            evolutionVisual?.root.isEnabled = false
            return
        }

        let visual = ensureEvolutionVisual()
        visual.root.isEnabled = true

        let phase = FlyWorldGeneticVisualization.phase(for: time)
        let pulse = 0.5 + sin(phase * Float.pi * 2.0) * 0.5
        let parentOffset = SIMD3<Float>(0.0, 0.12 + pulse * 0.012, 0.0)
        let parentAPosition = pair.parentA.scenePosition + parentOffset
        let parentBPosition = pair.parentB.scenePosition + parentOffset
        let midpoint = (parentAPosition + parentBPosition) * 0.5

        let offspringProgress = FlyWorldGeneticVisualization.offspringProgress(forPhase: phase)
        let offspringTarget: SIMD3<Float>
        if let offspring = pair.offspring {
            offspringTarget = offspring.scenePosition + SIMD3<Float>(0.0, 0.16, 0.0)
        } else {
            offspringTarget = midpoint + SIMD3<Float>(0.0, 0.10, 0.0)
        }
        let offspringPosition =
            midpoint +
            (offspringTarget - midpoint) * offspringProgress +
            SIMD3<Float>(0.0, sin(phase * Float.pi * 2.0) * 0.018, 0.0)

        visual.parentA.position = parentAPosition
        visual.parentB.position = parentBPosition
        visual.offspring.position = offspringPosition
        visual.generationBeacon.position = offspringPosition + SIMD3<Float>(0.0, 0.036, 0.0)

        let generationScale = 1.0 + Float(min(pair.offspringGeneration ?? 0, 12)) * 0.045
        visual.parentA.scale = SIMD3<Float>(repeating: 0.032 + pulse * 0.006)
        visual.parentB.scale = SIMD3<Float>(repeating: 0.032 + (1.0 - pulse) * 0.006)
        visual.offspring.scale = SIMD3<Float>(repeating: (0.018 + offspringProgress * 0.030) * generationScale)
        visual.generationBeacon.scale = SIMD3<Float>(
            0.010 + offspringProgress * 0.010,
            0.052 + offspringProgress * 0.028,
            0.010 + offspringProgress * 0.010
        )

        let beamOpacity = 0.24 + offspringProgress * 0.34
        updateEvolutionBeam(
            visual.lineageA,
            from: parentAPosition,
            to: offspringPosition,
            radius: 0.004 + pulse * 0.0015,
            opacity: beamOpacity
        )
        updateEvolutionBeam(
            visual.lineageB,
            from: parentBPosition,
            to: offspringPosition,
            radius: 0.004 + (1.0 - pulse) * 0.0015,
            opacity: beamOpacity
        )

        setEvolutionMaterial(
            visual.parentA,
            color: FlyWorldEntityFactory.color(0.22, 0.88, 1.0),
            opacity: 0.50 + pulse * 0.18
        )
        setEvolutionMaterial(
            visual.parentB,
            color: FlyWorldEntityFactory.color(1.0, 0.46, 0.86),
            opacity: 0.50 + (1.0 - pulse) * 0.18
        )
        setEvolutionMaterial(
            visual.offspring,
            color: FlyWorldEntityFactory.color(0.74, 1.0, 0.30),
            opacity: 0.58 + offspringProgress * 0.30
        )
        setEvolutionMaterial(
            visual.generationBeacon,
            color: FlyWorldEntityFactory.color(1.0, 0.94, 0.28),
            opacity: 0.40 + offspringProgress * 0.36
        )
    }

    private func selectedMatingPair(
        packet: FlyWorldPosePacket,
        renderedAgents: [FlyWorldRenderedAgentState]
    ) -> FlyWorldMatingPair? {
        guard renderedAgents.count >= 2 else { return nil }
        let statesByID = Dictionary(uniqueKeysWithValues: renderedAgents.map { ($0.id, $0) })

        if let event = packet.matingEvents?.reversed().first,
           let parentIDs = event.parentIds,
           parentIDs.count >= 2,
           let parentA = statesByID[parentIDs[0]],
           let parentB = statesByID[parentIDs[1]] {
            let offspring = event.offspringId.flatMap { statesByID[$0] }
            return FlyWorldMatingPair(
                id: event.id ?? "\(parentA.id)-\(parentB.id)-\(event.offspringId ?? "offspring")",
                parentA: parentA,
                parentB: parentB,
                offspring: offspring,
                offspringID: event.offspringId,
                offspringGeneration: event.generation ?? inferredOffspringGeneration(parentA: parentA, parentB: parentB)
            )
        }

        return inferredMatingPair(from: renderedAgents)
    }

    private func inferredMatingPair(
        from renderedAgents: [FlyWorldRenderedAgentState]
    ) -> FlyWorldMatingPair? {
        let viableAgents = renderedAgents.filter { !$0.isDead }
        let ranked = viableAgents.sorted { lhs, rhs in
            let lhsScore = lhs.score ?? -Float.greatestFiniteMagnitude
            let rhsScore = rhs.score ?? -Float.greatestFiniteMagnitude
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            return (lhs.generation ?? 0) > (rhs.generation ?? 0)
        }
        guard ranked.count >= 2 else { return nil }

        let parentA = ranked[0]
        let parentB = ranked[1]
        let generation = inferredOffspringGeneration(parentA: parentA, parentB: parentB)
        return FlyWorldMatingPair(
            id: "inferred-\(parentA.id)-\(parentB.id)-gen-\(generation)",
            parentA: parentA,
            parentB: parentB,
            offspring: nil,
            offspringID: "offspring-gen-\(generation)",
            offspringGeneration: generation
        )
    }

    private func inferredOffspringGeneration(
        parentA: FlyWorldRenderedAgentState,
        parentB: FlyWorldRenderedAgentState
    ) -> Int {
        max(parentA.generation ?? 0, parentB.generation ?? 0) + 1
    }

    private func ensureEvolutionVisual() -> FlyWorldEvolutionVisual {
        if let evolutionVisual {
            return evolutionVisual
        }

        let visual = makeEvolutionVisual()
        evolutionRoot.addChild(visual.root)
        evolutionVisual = visual
        return visual
    }

    private func makeEvolutionVisual() -> FlyWorldEvolutionVisual {
        let root = Entity()
        root.name = "GeneticEvolutionOverlay"

        let parentA = ModelEntity(
            mesh: .generateSphere(radius: 1.0),
            materials: [UnlitMaterial(color: FlyWorldEntityFactory.color(0.22, 0.88, 1.0))]
        )
        parentA.name = "MatingParentA"

        let parentB = ModelEntity(
            mesh: .generateSphere(radius: 1.0),
            materials: [UnlitMaterial(color: FlyWorldEntityFactory.color(1.0, 0.46, 0.86))]
        )
        parentB.name = "MatingParentB"

        let offspring = ModelEntity(
            mesh: .generateSphere(radius: 1.0),
            materials: [UnlitMaterial(color: FlyWorldEntityFactory.color(0.74, 1.0, 0.30))]
        )
        offspring.name = "OffspringMarker"

        let generationBeacon = ModelEntity(
            mesh: .generateCylinder(height: 1.0, radius: 1.0),
            materials: [UnlitMaterial(color: FlyWorldEntityFactory.color(1.0, 0.94, 0.28))]
        )
        generationBeacon.name = "OffspringGenerationBeacon"

        let lineageA = ModelEntity(
            mesh: .generateCylinder(height: 1.0, radius: 1.0),
            materials: [UnlitMaterial(color: FlyWorldEntityFactory.color(0.22, 0.88, 1.0))]
        )
        lineageA.name = "LineageBeamA"

        let lineageB = ModelEntity(
            mesh: .generateCylinder(height: 1.0, radius: 1.0),
            materials: [UnlitMaterial(color: FlyWorldEntityFactory.color(1.0, 0.46, 0.86))]
        )
        lineageB.name = "LineageBeamB"

        for entity in [lineageA, lineageB, parentA, parentB, offspring, generationBeacon] {
            root.addChild(entity)
        }

        return FlyWorldEvolutionVisual(
            root: root,
            parentA: parentA,
            parentB: parentB,
            offspring: offspring,
            generationBeacon: generationBeacon,
            lineageA: lineageA,
            lineageB: lineageB
        )
    }

    private func updateEvolutionBeam(
        _ beam: ModelEntity,
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        radius: Float,
        opacity: Float
    ) {
        FlyWorldEntityFactory.retargetBone(beam, from: start, to: end, radius: radius)
        beam.components.set(OpacityComponent(opacity: opacity))
    }

    private func setEvolutionMaterial(
        _ entity: ModelEntity,
        color: PlatformColor,
        opacity: Float
    ) {
        entity.model?.materials = [UnlitMaterial(color: color)]
        entity.components.set(OpacityComponent(opacity: opacity))
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

    #if os(macOS)
    private func updatePoseServerStatus(_ status: String) {
        poseServerStatus = status
        NSLog("FlyWorld pose server: %@", status)
    }

    private func isRunningUnderXCTest() -> Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") } ||
            NSClassFromString("XCTest.XCTestCase") != nil
    }

    private func isDefaultLocalPoseURL(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        let host = (url.host ?? "").lowercased()
        return url.scheme == "http" &&
            (host == "127.0.0.1" || host == "localhost" || host == "::1") &&
            (url.port ?? 80) == 8765
    }

    private func resolveSimulationDirectory() -> URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        var seeds: [URL] = []

        if let configuredRoot = environment["LEARNING_TO_FLY_ROOT"], !configuredRoot.isEmpty {
            seeds.append(URL(fileURLWithPath: configuredRoot, isDirectory: true))
        }
        seeds.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))
        seeds.append(Bundle.main.bundleURL)
        let homeLearningToFly = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("dev", isDirectory: true)
            .appendingPathComponent("advatar", isDirectory: true)
            .appendingPathComponent("LearningToFly", isDirectory: true)
        seeds.append(homeLearningToFly)

        var checked = Set<String>()
        for seed in seeds {
            for candidateRoot in candidateRoots(from: seed) {
                guard checked.insert(candidateRoot.path).inserted else { continue }
                let simulationDirectory = candidateRoot.appendingPathComponent("simulation", isDirectory: true)
                let scriptURL = simulationDirectory.appendingPathComponent("run_live_multi_fly.py")
                if fileManager.isReadableFile(atPath: scriptURL.path) {
                    return simulationDirectory
                }
            }
        }
        return nil
    }

    private func candidateRoots(from seed: URL) -> [URL] {
        var result: [URL] = []
        var current = seed.standardizedFileURL
        for _ in 0..<14 {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return result
    }

    private func localPythonLauncher(for repositoryRoot: URL) -> (executableURL: URL, arguments: [String]) {
        let venvPython = repositoryRoot
            .appendingPathComponent(".venv311/bin/python")
        if FileManager.default.isExecutableFile(atPath: venvPython.path) {
            return (venvPython, [])
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["python3"])
    }
    #endif

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

private struct FlyWorldRenderedAgentState {
    let id: String
    let label: String?
    let generation: Int?
    let score: Float?
    let genomeSummary: String?
    let positionMm: SIMD3<Float>
    let scenePosition: SIMD3<Float>
    let behavior: String
    let isDead: Bool
}

private struct FlyWorldDeathAnimation {
    let startedAt: TimeInterval
    let initialPositionMm: SIMD3<Float>
    let initialQuaternion: simd_quatf
    let fallSign: Float
}

private struct FlyWorldMatingPair {
    let id: String
    let parentA: FlyWorldRenderedAgentState
    let parentB: FlyWorldRenderedAgentState
    let offspring: FlyWorldRenderedAgentState?
    let offspringID: String?
    let offspringGeneration: Int?
}

private struct FlyWorldEvolutionVisual {
    let root: Entity
    let parentA: ModelEntity
    let parentB: ModelEntity
    let offspring: ModelEntity
    let generationBeacon: ModelEntity
    let lineageA: ModelEntity
    let lineageB: ModelEntity
}

private enum FlyWorldGeneticVisualization {
    static func phase(for time: TimeInterval) -> Float {
        let cycleDuration: TimeInterval = 8.0
        let remainder = time.truncatingRemainder(dividingBy: cycleDuration)
        return Float(remainder / cycleDuration)
    }

    static func offspringProgress(forPhase phase: Float) -> Float {
        let rawProgress = (phase - Float(0.18)) / Float(0.64)
        let normalized = Swift.min(Swift.max(rawProgress, Float(0.0)), Float(1.0))
        return normalized * normalized * (Float(3.0) - Float(2.0) * normalized)
    }
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
