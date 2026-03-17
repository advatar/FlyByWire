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
    private var isSeeded = false

    mutating func reset(
        using packet: FlyWorldPosePacket,
        referenceTime: TimeInterval
    ) {
        positionMm = packet.rootPositionVector
        heading = headingFromSimulationQuaternion(packet.rootQuaternion)
        gaitPhase = 0.0
        lastStepTime = referenceTime
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

        let planarDirection = SIMD2<Float>(cos(heading), sin(heading))
        var planarPosition = SIMD2<Float>(positionMm.x, positionMm.y)
        planarPosition += planarDirection * (command.forwardVelocityMmPerSecond * dt)
        planarPosition = clampedToArena(planarPosition)

        gaitPhase = wrapAngle(gaitPhase + command.gaitAngularSpeed * dt)
        positionMm = SIMD3<Float>(planarPosition.x, planarPosition.y, packet.rootPositionVector.z)

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
        case "groom":
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
