import XCTest
@testable import FlyBrainWorldMac

final class FlyWorldBrainDrivenMotionTests: XCTestCase {
    func testDescendingSignalsSupportAliasKeys() {
        let signals = FlyWorldDescendingSignals(
            brainState: [
                "forward_drive": 0.42,
                "turn_left_drive": 0.20,
                "turn_right_drive": 0.31,
                "instinct_groom": 0.61,
                "instinct_feed": 0.73,
                "instinct_escape": 0.44
            ]
        )

        XCTAssertEqual(signals.forwardDrive, 0.42, accuracy: 0.0001)
        XCTAssertEqual(signals.leftTurnDrive, 0.20, accuracy: 0.0001)
        XCTAssertEqual(signals.rightTurnDrive, 0.31, accuracy: 0.0001)
        XCTAssertEqual(signals.groomDrive, 0.61, accuracy: 0.0001)
        XCTAssertEqual(signals.feedDrive, 0.73, accuracy: 0.0001)
        XCTAssertEqual(signals.escapeDrive, 0.44, accuracy: 0.0001)
    }

    func testBehaviorResolutionPrioritizesEscapeThenFeedThenWalk() {
        let walkSignals = FlyWorldDescendingSignals(
            brainState: [
                "oDN1": 0.35
            ]
        )
        XCTAssertEqual(
            FlyWorldBehaviorResolver.resolvedBehavior(packetBehavior: "idle", descending: walkSignals),
            "walk"
        )

        let feedSignals = FlyWorldDescendingSignals(
            brainState: [
                "oDN1": 0.40,
                "MN9": 0.82
            ]
        )
        XCTAssertEqual(
            FlyWorldBehaviorResolver.resolvedBehavior(packetBehavior: "walk", descending: feedSignals),
            "feed"
        )

        let escapeSignals = FlyWorldDescendingSignals(
            brainState: [
                "oDN1": 0.40,
                "MN9": 0.82,
                "loom_escape": 0.93
            ]
        )
        XCTAssertEqual(
            FlyWorldBehaviorResolver.resolvedBehavior(packetBehavior: "feed", descending: escapeSignals),
            "escape"
        )
    }

    func testBrainDrivenMotionWalksForwardFromDescendingDrive() {
        var controller = FlyWorldBrainDrivenMotionController()
        let packet = makePacket(
            rootPosition: [0.0, 0.0, 0.2],
            brainState: [
                "oDN1": 0.78,
                "DNa01": 0.05,
                "DNa02": 0.02
            ],
            behavior: "walk"
        )

        controller.reset(using: packet, referenceTime: 0.0)
        let initial = controller.synthesize(packet: packet, time: 0.0)
        let advanced = controller.synthesize(packet: packet, time: 1.0)

        XCTAssertEqual(initial.behavior, "walk")
        XCTAssertEqual(advanced.behavior, "walk")
        XCTAssertGreaterThan(advanced.rootPositionMm.x, initial.rootPositionMm.x + 0.12)
        XCTAssertGreaterThan(advanced.leftStrideDrive, 0.6)
        XCTAssertGreaterThan(advanced.rightStrideDrive, 0.6)
    }

    func testFeedControllerSlowsAsFlyReachesDish() {
        let worldObjects = [
            FlyWorldPosePacket.WorldObject(
                id: "nectar",
                kind: "drink",
                label: "Nectar",
                positionMm: [2.0, 0.0, 0.0],
                sizeMm: [1.6, 0.3, 1.6],
                color: nil,
                opacity: nil
            )
        ]

        let farPacket = makePacket(
            rootPosition: [0.0, 0.0, 0.2],
            brainState: [
                "oDN1": 0.32,
                "MN9": 0.94
            ],
            behavior: "walk",
            worldObjects: worldObjects
        )
        let nearPacket = makePacket(
            rootPosition: [1.75, 0.0, 0.2],
            brainState: [
                "oDN1": 0.32,
                "MN9": 0.94
            ],
            behavior: "walk",
            worldObjects: worldObjects
        )

        var farController = FlyWorldBrainDrivenMotionController()
        farController.reset(using: farPacket, referenceTime: 0.0)
        let farStart = farController.synthesize(packet: farPacket, time: 0.0)
        let farNext = farController.synthesize(packet: farPacket, time: 1.0)

        var nearController = FlyWorldBrainDrivenMotionController()
        nearController.reset(using: nearPacket, referenceTime: 0.0)
        let nearStart = nearController.synthesize(packet: nearPacket, time: 0.0)
        let nearNext = nearController.synthesize(packet: nearPacket, time: 1.0)

        let farDisplacement = farNext.rootPositionMm.x - farStart.rootPositionMm.x
        let nearDisplacement = nearNext.rootPositionMm.x - nearStart.rootPositionMm.x

        XCTAssertEqual(farNext.behavior, "feed")
        XCTAssertEqual(nearNext.behavior, "feed")
        XCTAssertGreaterThan(farDisplacement, nearDisplacement * 2.0)
        XCTAssertGreaterThan(farNext.feedDrive, 0.9)
    }

    private func makePacket(
        rootPosition: [Float],
        brainState: [String: Float],
        behavior: String,
        worldObjects: [FlyWorldPosePacket.WorldObject] = []
    ) -> FlyWorldPosePacket {
        FlyWorldPosePacket(
            timestamp: 0.0,
            rootPositionMm: rootPosition,
            rootQuaternionXyzw: [0.0, 0.0, 0.0, 1.0],
            jointAnglesRad: [
                "LFCoxa": 0.16,
                "LFFemur": -0.22,
                "LFTibia": 0.28,
                "RFCoxa": -0.16,
                "RFFemur": -0.18,
                "RFTibia": 0.24
            ],
            brainState: brainState,
            behavior: behavior,
            worldObjects: worldObjects
        )
    }
}
