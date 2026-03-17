import Foundation
import simd

struct FlyWorldDescendingSignals: Equatable {
    let forwardDrive: Float
    let leftTurnDrive: Float
    let rightTurnDrive: Float
    let groomDrive: Float
    let feedDrive: Float
    let escapeDrive: Float

    init(brainState: [String: Float]) {
        forwardDrive = Self.drive(from: brainState, keys: ["oDN1", "P9_oDN1", "forward_drive", "locomotion_drive", "walk_drive"])
        leftTurnDrive = Self.drive(from: brainState, keys: ["DNa01", "turn_left_drive", "left_drive"])
        rightTurnDrive = Self.drive(from: brainState, keys: ["DNa02", "turn_right_drive", "right_drive"])
        groomDrive = Self.drive(from: brainState, keys: ["aDN1", "groom_drive", "instinct_groom"])
        feedDrive = Self.drive(from: brainState, keys: ["MN9", "feed_drive", "instinct_feed", "sugar_contact"])
        escapeDrive = Self.drive(from: brainState, keys: ["loom_escape", "escape_drive", "instinct_escape", "MDN"])
    }

    var locomotionDrive: Float {
        max(forwardDrive, max(leftTurnDrive, rightTurnDrive))
    }

    var maxDrive: Float {
        max(
            locomotionDrive,
            max(groomDrive, max(feedDrive, escapeDrive))
        )
    }

    private static func drive(from brainState: [String: Float], keys: [String]) -> Float {
        let value = keys.compactMap { brainState[$0] }.max() ?? 0.0
        return clamp(value, min: 0.0, max: 1.5)
    }
}

enum FlyWorldBehaviorResolver {
    static func resolvedBehavior(
        packetBehavior: String,
        descending: FlyWorldDescendingSignals
    ) -> String {
        let normalized = packetBehavior
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if descending.escapeDrive > 0.5 || normalized == "escape" {
            return "escape"
        }
        if descending.groomDrive > 0.5 || normalized == "groom" {
            return "groom"
        }
        if descending.feedDrive > 0.5 || normalized == "feed" {
            return "feed"
        }
        if descending.forwardDrive > 0.18 || normalized == "walk" {
            return "walk"
        }
        if normalized.isEmpty {
            return "idle"
        }
        return normalized
    }
}

enum FlyWorldLegID: CaseIterable, Hashable {
    case leftFront
    case rightFront
    case leftMid
    case rightMid
    case leftHind
    case rightHind

    var prefix: String {
        switch self {
        case .leftFront:
            return "LF"
        case .rightFront:
            return "RF"
        case .leftMid:
            return "LM"
        case .rightMid:
            return "RM"
        case .leftHind:
            return "LH"
        case .rightHind:
            return "RH"
        }
    }

    var phaseOffset: Float {
        switch self {
        case .leftFront, .rightMid, .leftHind:
            return 0.0
        case .rightFront, .leftMid, .rightHind:
            return .pi
        }
    }

    var strideScale: Float {
        switch self {
        case .leftFront, .rightFront:
            return 1.0
        case .leftMid, .rightMid:
            return 0.88
        case .leftHind, .rightHind:
            return 0.94
        }
    }

    var isLeftSide: Bool {
        switch self {
        case .leftFront, .leftMid, .leftHind:
            return true
        case .rightFront, .rightMid, .rightHind:
            return false
        }
    }
}

struct FlyWorldLegGeometry {
    let shoulder: SIMD3<Float>
    let knee: SIMD3<Float>
    let ankle: SIMD3<Float>
    let tip: SIMD3<Float>
}

struct FlyWorldLegPose {
    let id: FlyWorldLegID
    let shoulder: SIMD3<Float>
    let knee: SIMD3<Float>
    let ankle: SIMD3<Float>
    let tip: SIMD3<Float>
    let contactAmount: Float

    var isInContact: Bool {
        contactAmount >= 0.5
    }

    var planarTipMm: SIMD2<Float> {
        SIMD2<Float>(
            tip.x / FlyWorldLegKinematics.sceneMillimeterScale,
            -tip.z / FlyWorldLegKinematics.sceneMillimeterScale
        )
    }
}

enum FlyWorldLegKinematics {
    static let sceneMillimeterScale: Float = 0.12
    static let flyRootVerticalBiasScene: Float = 0.02
    static let arenaFloorSceneY: Float = -0.34

    private static let arenaFloorMm = arenaFloorSceneY / sceneMillimeterScale
    private static let flyRootVerticalBiasMm = flyRootVerticalBiasScene / sceneMillimeterScale

    static func geometry(for leg: FlyWorldLegID) -> FlyWorldLegGeometry {
        switch leg {
        case .leftFront:
            return FlyWorldLegGeometry(
                shoulder: SIMD3<Float>(-0.03, -0.01, -0.085),
                knee: SIMD3<Float>(-0.11, -0.12, -0.17),
                ankle: SIMD3<Float>(-0.06, -0.30, -0.24),
                tip: SIMD3<Float>(0.0, -0.32, -0.25)
            )
        case .rightFront:
            return FlyWorldLegGeometry(
                shoulder: SIMD3<Float>(-0.03, -0.01, 0.085),
                knee: SIMD3<Float>(-0.11, -0.12, 0.17),
                ankle: SIMD3<Float>(-0.06, -0.30, 0.24),
                tip: SIMD3<Float>(0.0, -0.32, 0.25)
            )
        case .leftMid:
            return FlyWorldLegGeometry(
                shoulder: SIMD3<Float>(0.045, -0.02, -0.095),
                knee: SIMD3<Float>(0.02, -0.15, -0.22),
                ankle: SIMD3<Float>(0.11, -0.32, -0.26),
                tip: SIMD3<Float>(0.17, -0.34, -0.27)
            )
        case .rightMid:
            return FlyWorldLegGeometry(
                shoulder: SIMD3<Float>(0.045, -0.02, 0.095),
                knee: SIMD3<Float>(0.02, -0.15, 0.22),
                ankle: SIMD3<Float>(0.11, -0.32, 0.26),
                tip: SIMD3<Float>(0.17, -0.34, 0.27)
            )
        case .leftHind:
            return FlyWorldLegGeometry(
                shoulder: SIMD3<Float>(0.13, -0.02, -0.085),
                knee: SIMD3<Float>(0.20, -0.16, -0.18),
                ankle: SIMD3<Float>(0.31, -0.31, -0.24),
                tip: SIMD3<Float>(0.37, -0.33, -0.25)
            )
        case .rightHind:
            return FlyWorldLegGeometry(
                shoulder: SIMD3<Float>(0.13, -0.02, 0.085),
                knee: SIMD3<Float>(0.20, -0.16, 0.18),
                ankle: SIMD3<Float>(0.31, -0.31, 0.24),
                tip: SIMD3<Float>(0.37, -0.33, 0.25)
            )
        }
    }

    static func radii(for leg: FlyWorldLegID) -> (Float, Float, Float) {
        switch leg {
        case .leftFront, .rightFront:
            return (0.0065, 0.0045, 0.0026)
        case .leftMid, .rightMid:
            return (0.0060, 0.0042, 0.0025)
        case .leftHind, .rightHind:
            return (0.0060, 0.0040, 0.0025)
        }
    }

    static func pose(
        leg: FlyWorldLegID,
        packet: FlyWorldPosePacket,
        gaitPhase: Float,
        leftStrideDrive: Float,
        rightStrideDrive: Float,
        behavior: String
    ) -> FlyWorldLegPose {
        let prefix = leg.prefix
        let neutralCoxa = packet.jointAnglesRad["\(prefix)Coxa"] ?? 0.0
        let neutralFemur = packet.jointAnglesRad["\(prefix)Femur"] ?? 0.0
        let neutralTibia = packet.jointAnglesRad["\(prefix)Tibia"] ?? 0.0
        let strideDrive = strideDrive(for: leg, leftStrideDrive: leftStrideDrive, rightStrideDrive: rightStrideDrive)
        let clampedStride = clamp(strideDrive, min: 0.0, max: 1.4)
        let sideDirection: Float = leg.isLeftSide ? 1.0 : -1.0

        let coxaBase: Float
        let femurBase: Float
        let tibiaBase: Float

        switch behavior {
        case "groom":
            coxaBase = sideDirection * 0.52
            femurBase = -0.94
            tibiaBase = 1.08
        case "feed":
            coxaBase = neutralCoxa + sideDirection * 0.06
            femurBase = neutralFemur - 0.12
            tibiaBase = neutralTibia + 0.18
        default:
            coxaBase = neutralCoxa
            femurBase = neutralFemur
            tibiaBase = neutralTibia
        }

        let strideScale: Float
        switch behavior {
        case "groom":
            strideScale = 0.08
        case "feed":
            strideScale = min(clampedStride, 0.18)
        default:
            strideScale = clampedStride * leg.strideScale
        }

        let legPhase = wrapAngle(gaitPhase + leg.phaseOffset)
        let coxa = coxaBase + sin(legPhase) * strideScale * 0.36
        let femur = femurBase + cos(legPhase) * strideScale * 0.44
        let tibia = tibiaBase + sin(legPhase + .pi / 2) * strideScale * 0.62

        let geometry = geometry(for: leg)
        let shoulder = geometry.shoulder
        let upperVector = rotateOnZ(geometry.knee - geometry.shoulder, angle: coxa)
        let knee = shoulder + upperVector

        let lowerVector = rotateOnZ(geometry.ankle - geometry.knee, angle: coxa + femur)
        let ankle = knee + lowerVector

        let tipVector = rotateOnZ(geometry.tip - geometry.ankle, angle: coxa + femur + tibia)
        let tip = ankle + tipVector

        return FlyWorldLegPose(
            id: leg,
            shoulder: shoulder,
            knee: knee,
            ankle: ankle,
            tip: tip,
            contactAmount: supportContactAmount(
                behavior: behavior,
                legPhase: legPhase,
                strideDrive: clampedStride
            )
        )
    }

    static func supportRootHeightMm(for poses: [FlyWorldLegPose]) -> Float {
        let supportingPoses = poses.filter(\.isInContact)
        let effectivePoses = supportingPoses.isEmpty ? poses : supportingPoses
        guard !effectivePoses.isEmpty else { return 0.0 }

        let averageTipSceneY =
            effectivePoses.reduce(0.0) { partialResult, pose in
                partialResult + pose.tip.y
            } / Float(effectivePoses.count)

        return arenaFloorMm - flyRootVerticalBiasMm - averageTipSceneY / sceneMillimeterScale
    }

    private static func strideDrive(
        for leg: FlyWorldLegID,
        leftStrideDrive: Float,
        rightStrideDrive: Float
    ) -> Float {
        leg.isLeftSide ? leftStrideDrive : rightStrideDrive
    }

    private static func supportContactAmount(
        behavior: String,
        legPhase: Float,
        strideDrive: Float
    ) -> Float {
        switch behavior {
        case "idle", "groom":
            return 1.0
        default:
            let stanceThreshold: Float
            switch behavior {
            case "feed":
                stanceThreshold = 0.16
            case "escape":
                stanceThreshold = -0.14
            default:
                stanceThreshold = 0.0
            }

            let softness = 0.16 + min(strideDrive, 1.0) * 0.06
            let normalized = (stanceThreshold - cos(legPhase)) / softness
            return clamp(0.5 + normalized * 0.5, min: 0.0, max: 1.0)
        }
    }

    private static func rotateOnZ(_ vector: SIMD3<Float>, angle: Float) -> SIMD3<Float> {
        simd_quatf(angle: angle, axis: SIMD3<Float>(0.0, 0.0, 1.0)).act(vector)
    }
}

struct FlyWorldMotionFrame {
    let rootPositionMm: SIMD3<Float>
    let rootQuaternion: simd_quatf
    let leftStrideDrive: Float
    let rightStrideDrive: Float
    let gaitPhase: Float
    let behavior: String
    let feedDrive: Float
    let escapeDrive: Float
    let brainDrive: Float

    static func directPose(
        packet: FlyWorldPosePacket,
        time: TimeInterval
    ) -> FlyWorldMotionFrame {
        let descending = FlyWorldDescendingSignals(brainState: packet.brainState)
        let behavior = FlyWorldBehaviorResolver.resolvedBehavior(
            packetBehavior: packet.behavior,
            descending: descending
        )
        let heading = headingFromSimulationQuaternion(packet.rootQuaternion)
        let command = FlyWorldLowLevelController.command(
            packet: packet,
            descending: descending,
            behavior: behavior,
            currentPositionMm: packet.rootPositionVector,
            currentHeading: heading
        )

        return FlyWorldMotionFrame(
            rootPositionMm: packet.rootPositionVector,
            rootQuaternion: packet.rootQuaternion,
            leftStrideDrive: command.leftStrideDrive,
            rightStrideDrive: command.rightStrideDrive,
            gaitPhase: Float(time) * command.gaitAngularSpeed,
            behavior: behavior,
            feedDrive: command.feedDrive,
            escapeDrive: command.escapeDrive,
            brainDrive: command.brainDrive
        )
    }
}

struct FlyWorldBrainDrivenMotionController {
    private let arenaRadiusMm: Float = 3.8

    private var positionMm = SIMD3<Float>(0.0, 0.0, 0.2)
    private var heading: Float = 0.0
    private var gaitPhase: Float = 0.0
    private var lastStepTime: TimeInterval?
    private var footholdAnchorsMm: [FlyWorldLegID: SIMD2<Float>] = [:]
    private var supportState: [FlyWorldLegID: Bool] = [:]
    private var isSeeded = false

    mutating func reset(
        using packet: FlyWorldPosePacket,
        referenceTime: TimeInterval
    ) {
        positionMm = packet.rootPositionVector
        heading = headingFromSimulationQuaternion(packet.rootQuaternion)
        gaitPhase = 0.0
        lastStepTime = referenceTime
        footholdAnchorsMm.removeAll(keepingCapacity: true)
        supportState.removeAll(keepingCapacity: true)
        seedSupportState(using: packet)
        isSeeded = true
    }

    mutating func synthesize(
        packet: FlyWorldPosePacket,
        time: TimeInterval
    ) -> FlyWorldMotionFrame {
        if !isSeeded {
            reset(using: packet, referenceTime: time)
        }

        let dt = resolvedStepDuration(currentTime: time)
        let descending = FlyWorldDescendingSignals(brainState: packet.brainState)
        let behavior = FlyWorldBehaviorResolver.resolvedBehavior(
            packetBehavior: packet.behavior,
            descending: descending
        )
        let command = FlyWorldLowLevelController.command(
            packet: packet,
            descending: descending,
            behavior: behavior,
            currentPositionMm: positionMm,
            currentHeading: heading
        )

        heading = wrapAngle(heading + command.turnVelocityRadPerSecond * dt)
        gaitPhase = wrapAngle(gaitPhase + command.gaitAngularSpeed * dt)

        let poses = currentLegPoses(
            packet: packet,
            behavior: behavior,
            leftStrideDrive: command.leftStrideDrive,
            rightStrideDrive: command.rightStrideDrive
        )

        var planarPosition = SIMD2<Float>(positionMm.x, positionMm.y)
        var supportCandidates: [SIMD2<Float>] = []

        for pose in poses {
            if pose.isInContact {
                if footholdAnchorsMm[pose.id] == nil || supportState[pose.id] != true {
                    footholdAnchorsMm[pose.id] = planarPosition + rotatePlanar(pose.planarTipMm, angle: heading)
                }
                if let anchor = footholdAnchorsMm[pose.id] {
                    supportCandidates.append(anchor - rotatePlanar(pose.planarTipMm, angle: heading))
                }
            } else {
                footholdAnchorsMm.removeValue(forKey: pose.id)
            }
        }

        if !supportCandidates.isEmpty {
            planarPosition = supportCandidates.reduce(into: SIMD2<Float>(repeating: 0.0)) { partialResult, candidate in
                partialResult += candidate
            } / Float(supportCandidates.count)
        }

        let unclampedPlanarPosition = planarPosition
        planarPosition = clampedToArena(planarPosition)
        if simd_distance_squared(unclampedPlanarPosition, planarPosition) > 0.0001 {
            for pose in poses where pose.isInContact {
                footholdAnchorsMm[pose.id] = planarPosition + rotatePlanar(pose.planarTipMm, angle: heading)
            }
        }

        let targetHeightMm = FlyWorldLegKinematics.supportRootHeightMm(for: poses)
        let heightBlend = clamp(dt * 12.0, min: 0.0, max: 1.0)
        let rootHeightMm = positionMm.z + (targetHeightMm - positionMm.z) * heightBlend

        for pose in poses {
            supportState[pose.id] = pose.isInContact
        }

        positionMm = SIMD3<Float>(planarPosition.x, planarPosition.y, rootHeightMm)

        return FlyWorldMotionFrame(
            rootPositionMm: positionMm,
            rootQuaternion: simd_quatf(angle: heading, axis: SIMD3<Float>(0.0, 0.0, 1.0)),
            leftStrideDrive: command.leftStrideDrive,
            rightStrideDrive: command.rightStrideDrive,
            gaitPhase: gaitPhase,
            behavior: behavior,
            feedDrive: command.feedDrive,
            escapeDrive: command.escapeDrive,
            brainDrive: command.brainDrive
        )
    }

    private mutating func seedSupportState(using packet: FlyWorldPosePacket) {
        let descending = FlyWorldDescendingSignals(brainState: packet.brainState)
        let behavior = FlyWorldBehaviorResolver.resolvedBehavior(
            packetBehavior: packet.behavior,
            descending: descending
        )
        let command = FlyWorldLowLevelController.command(
            packet: packet,
            descending: descending,
            behavior: behavior,
            currentPositionMm: positionMm,
            currentHeading: heading
        )
        let poses = currentLegPoses(
            packet: packet,
            behavior: behavior,
            leftStrideDrive: command.leftStrideDrive,
            rightStrideDrive: command.rightStrideDrive
        )
        let planarPosition = SIMD2<Float>(positionMm.x, positionMm.y)

        for pose in poses where pose.isInContact {
            footholdAnchorsMm[pose.id] = planarPosition + rotatePlanar(pose.planarTipMm, angle: heading)
            supportState[pose.id] = true
        }
        for pose in poses where supportState[pose.id] == nil {
            supportState[pose.id] = false
        }

        positionMm.z = FlyWorldLegKinematics.supportRootHeightMm(for: poses)
    }

    private func currentLegPoses(
        packet: FlyWorldPosePacket,
        behavior: String,
        leftStrideDrive: Float,
        rightStrideDrive: Float
    ) -> [FlyWorldLegPose] {
        FlyWorldLegID.allCases.map { leg in
            FlyWorldLegKinematics.pose(
                leg: leg,
                packet: packet,
                gaitPhase: gaitPhase,
                leftStrideDrive: leftStrideDrive,
                rightStrideDrive: rightStrideDrive,
                behavior: behavior
            )
        }
    }

    private mutating func resolvedStepDuration(currentTime: TimeInterval) -> Float {
        guard let lastStepTime else {
            lastStepTime = currentTime
            return 1.0 / 30.0
        }

        let dt = clamp(Float(currentTime - lastStepTime), min: 1.0 / 120.0, max: 0.15)
        self.lastStepTime = currentTime
        return dt
    }

    private func clampedToArena(_ planarPosition: SIMD2<Float>) -> SIMD2<Float> {
        let distance = simd_length(planarPosition)
        guard distance > arenaRadiusMm else { return planarPosition }
        return simd_normalize(planarPosition) * arenaRadiusMm
    }
}

private struct FlyWorldLowLevelCommand {
    let forwardVelocityMmPerSecond: Float
    let turnVelocityRadPerSecond: Float
    let gaitAngularSpeed: Float
    let leftStrideDrive: Float
    let rightStrideDrive: Float
    let feedDrive: Float
    let escapeDrive: Float
    let brainDrive: Float
}

private enum FlyWorldLowLevelController {
    static func command(
        packet: FlyWorldPosePacket,
        descending: FlyWorldDescendingSignals,
        behavior: String,
        currentPositionMm: SIMD3<Float>,
        currentHeading: Float
    ) -> FlyWorldLowLevelCommand {
        let locomotionBase = clamp(
            descending.forwardDrive + descending.escapeDrive * 0.45 - descending.groomDrive * 0.35,
            min: 0.0,
            max: 1.3
        )
        var locomotionDrive = locomotionBase
        var turnIntent = descending.leftTurnDrive - descending.rightTurnDrive

        switch behavior {
        case "feed":
            if let target = nearestWorldObject(
                matching: ["drink", "food"],
                from: currentPositionMm,
                objects: packet.worldObjectsOrDefault
            ) {
                let targetVector = SIMD2<Float>(
                    target.positionVector.x - currentPositionMm.x,
                    target.positionVector.y - currentPositionMm.y
                )
                let distance = simd_length(targetVector)
                if distance > 0.001 {
                    let desiredHeading = atan2(targetVector.y, targetVector.x)
                    let headingError = wrapAngle(desiredHeading - currentHeading)
                    turnIntent += clamp(headingError * 0.85, min: -1.0, max: 1.0)
                }

                let approachScale = clamp(distance / 2.6, min: 0.0, max: 1.0)
                let minimumApproach: Float = distance > 0.6 ? 0.12 : 0.0
                let feedLocomotionCap: Float = 0.72
                locomotionDrive = max(
                    minimumApproach,
                    min(locomotionDrive * 0.45 + descending.feedDrive * 0.32, feedLocomotionCap)
                )
                locomotionDrive *= max(approachScale, Float(0.16))
            } else {
                locomotionDrive *= 0.25
            }

        case "groom":
            locomotionDrive *= 0.04
            turnIntent *= 0.25

        case "escape":
            locomotionDrive = max(locomotionDrive, 0.92 + descending.escapeDrive * 0.28)
            if let threat = nearestWorldObject(
                matching: ["visual_target", "visualtarget"],
                from: currentPositionMm,
                objects: packet.worldObjectsOrDefault
            ) {
                let threatVector = SIMD2<Float>(
                    currentPositionMm.x - threat.positionVector.x,
                    currentPositionMm.y - threat.positionVector.y
                )
                if simd_length_squared(threatVector) > 0.0001 {
                    let desiredHeading = atan2(threatVector.y, threatVector.x)
                    let headingError = wrapAngle(desiredHeading - currentHeading)
                    turnIntent += clamp(headingError, min: -1.2, max: 1.2)
                }
            }

        default:
            break
        }

        let leftStrideDrive = clamp(locomotionDrive + turnIntent * 0.32, min: 0.0, max: 1.4)
        let rightStrideDrive = clamp(locomotionDrive - turnIntent * 0.32, min: 0.0, max: 1.4)
        let strideAverage = (leftStrideDrive + rightStrideDrive) * 0.5

        let turnVelocity: Float
        if behavior == "escape" {
            turnVelocity = turnIntent * 1.8
        } else {
            turnVelocity = turnIntent * 1.2
        }

        let forwardVelocity: Float
        switch behavior {
        case "idle", "groom":
            forwardVelocity = 0.0
        case "feed":
            forwardVelocity = 0.08 + strideAverage * 0.95
        case "escape":
            forwardVelocity = 0.45 + strideAverage * 1.9
        default:
            forwardVelocity = 0.16 + strideAverage * 1.25
        }

        let gaitAngularSpeed: Float
        switch behavior {
        case "idle":
            gaitAngularSpeed = 0.0
        case "groom":
            gaitAngularSpeed = 1.4
        case "escape":
            gaitAngularSpeed = 7.8 + strideAverage * 3.4
        default:
            gaitAngularSpeed = 4.8 + strideAverage * 2.2
        }

        return FlyWorldLowLevelCommand(
            forwardVelocityMmPerSecond: forwardVelocity,
            turnVelocityRadPerSecond: turnVelocity,
            gaitAngularSpeed: gaitAngularSpeed,
            leftStrideDrive: leftStrideDrive,
            rightStrideDrive: rightStrideDrive,
            feedDrive: max(descending.feedDrive, behavior == "feed" ? 1.0 : 0.0),
            escapeDrive: max(descending.escapeDrive, behavior == "escape" ? 1.0 : 0.0),
            brainDrive: max(descending.maxDrive, strideAverage)
        )
    }

    private static func nearestWorldObject(
        matching kinds: Set<String>,
        from position: SIMD3<Float>,
        objects: [FlyWorldPosePacket.WorldObject]
    ) -> FlyWorldPosePacket.WorldObject? {
        objects
            .filter { kinds.contains(normalizedKind(for: $0.kind)) }
            .min { lhs, rhs in
                distanceSquared(lhs.positionVector, position) < distanceSquared(rhs.positionVector, position)
            }
    }

    private static func normalizedKind(for kind: String) -> String {
        kind
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }

    private static func distanceSquared(
        _ lhs: SIMD3<Float>,
        _ rhs: SIMD3<Float>
    ) -> Float {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

private func headingFromSimulationQuaternion(_ quaternion: simd_quatf) -> Float {
    let forward = quaternion.act(SIMD3<Float>(1.0, 0.0, 0.0))
    return atan2(forward.y, forward.x)
}

private func clamp(
    _ value: Float,
    min lowerBound: Float,
    max upperBound: Float
) -> Float {
    Swift.min(Swift.max(value, lowerBound), upperBound)
}

private func wrapAngle(_ angle: Float) -> Float {
    let twoPi = Float.pi * 2.0
    var wrapped = angle.truncatingRemainder(dividingBy: twoPi)
    if wrapped <= -.pi {
        wrapped += twoPi
    }
    if wrapped > .pi {
        wrapped -= twoPi
    }
    return wrapped
}

private func rotatePlanar(_ vector: SIMD2<Float>, angle: Float) -> SIMD2<Float> {
    let cosine = cos(angle)
    let sine = sin(angle)
    return SIMD2<Float>(
        vector.x * cosine - vector.y * sine,
        vector.x * sine + vector.y * cosine
    )
}
