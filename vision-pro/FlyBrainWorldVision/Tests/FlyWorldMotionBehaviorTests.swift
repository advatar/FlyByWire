import Foundation
import simd

@main
enum FlyWorldMotionBehaviorTests {
    static func main() {
        testCollisionResolverSeparatesOverlappingAgents()
        testCollisionResolverLeavesClearAgentsAlone()
        testFlightRandomizerVariesTurnVelocity()
        testFlightArenaDoesNotUseWalkingEdgeRadius()

        print("FlyWorldMotionBehaviorTests passed")
    }

    private static func testCollisionResolverSeparatesOverlappingAgents() {
        let neighbor = SIMD2<Float>(4.0, 0.0)
        let result = FlyWorldAgentCollisionResolver.resolvedPlanarPosition(
            proposedPosition: SIMD2<Float>(0.0, 0.0),
            neighbors: [neighbor],
            phaseSeed: 0.8,
            collisionRadiusMm: 10.0
        )

        precondition(result.collisionCount > 0, "Expected an overlap to be detected")
        precondition(
            simd_distance(result.position, neighbor) >= 19.99,
            "Expected overlapping agents to be separated to the minimum distance"
        )
    }

    private static func testCollisionResolverLeavesClearAgentsAlone() {
        let proposed = SIMD2<Float>(0.0, 0.0)
        let result = FlyWorldAgentCollisionResolver.resolvedPlanarPosition(
            proposedPosition: proposed,
            neighbors: [SIMD2<Float>(42.0, 0.0)],
            phaseSeed: 0.8,
            collisionRadiusMm: 10.0
        )

        precondition(result.collisionCount == 0, "Expected no collision when agents are clear")
        precondition(
            simd_distance(result.position, proposed) < 0.001,
            "Expected clear agents to keep their proposed position"
        )
    }

    private static func testFlightRandomizerVariesTurnVelocity() {
        let first = FlyWorldFlightRandomizer.turnVelocity(time: 1.0, phaseSeed: 1.7, drive: 0.8)
        let second = FlyWorldFlightRandomizer.turnVelocity(time: 5.0, phaseSeed: 1.7, drive: 0.8)

        precondition(abs(first - second) > 0.01, "Expected seeded flight wander to vary over time")
        precondition(abs(first) < 0.75, "Expected flight wander to remain bounded")
        precondition(abs(second) < 0.75, "Expected flight wander to remain bounded")
    }

    private static func testFlightArenaDoesNotUseWalkingEdgeRadius() {
        let position = SIMD3<Float>(20.0, 0.0, 0.0)
        let walkingEdge = FlyWorldArenaEdgeSignals.sensing(
            currentPositionMm: position,
            currentHeading: 0.0
        )
        let flightEdge = FlyWorldArenaEdgeSignals.sensing(
            currentPositionMm: position,
            currentHeading: 0.0,
            arenaRadiusMm: FlyWorldFlightTuning.arenaRadiusMm
        )

        precondition(walkingEdge.edgeDrive > 0.0, "Expected the walking arena edge to trigger at 20 mm")
        precondition(flightEdge.edgeDrive == 0.0, "Expected the flight arena to avoid premature edge steering")
    }
}
