import XCTest
@testable import FlyBrainWorldMac

final class FlyWorldPosePacketTests: XCTestCase {
    @MainActor
    func testDefaultPoseStreamUsesLocalhostForAutoStartedServer() throws {
        XCTAssertEqual(FlyWorldSceneController.defaultPacketURLString, "http://127.0.0.1:8765/pose")
        let controller = FlyWorldSceneController()
        XCTAssertEqual(controller.packetURLString, FlyWorldSceneController.defaultPacketURLString)
    }

    func testLegacyPacketExposesSingleDisplayAgent() throws {
        let packet = FlyWorldPosePacket(
            timestamp: 0.0,
            rootPositionMm: [1.0, 2.0, 0.3],
            rootQuaternionXyzw: [0.0, 0.0, 0.0, 1.0],
            jointAnglesRad: [
                "LFCoxa": 0.10,
                "LFFemur": -0.20,
                "LFTibia": 0.30
            ],
            brainState: [
                "oDN1": 0.45
            ],
            behavior: "walk",
            worldObjects: []
        )

        XCTAssertEqual(packet.displayAgents.count, 1)
        let agent = try XCTUnwrap(packet.displayAgents.first)
        XCTAssertEqual(agent.id, "primary")
        XCTAssertEqual(agent.rootPositionMm, [1.0, 2.0, 0.3])
        XCTAssertNotNil(agent.directLegAngles(for: .leftFront))

        let agentPacket = packet.packet(for: agent)
        XCTAssertEqual(agentPacket.rootPositionMm, packet.rootPositionMm)
        XCTAssertEqual(agentPacket.behavior, packet.behavior)
    }

    func testMultiAgentPacketDecodesExplicitAgents() throws {
        let payload = """
        {
          "timestamp": 12.5,
          "root_position_mm": [1.0, 2.0, 0.3],
          "root_quaternion_xyzw": [0.0, 0.0, 0.0, 1.0],
          "joint_angles_rad": {
            "LFCoxa": 0.1,
            "LFFemur": -0.2,
            "LFTibia": 0.3
          },
          "brain_state": {
            "oDN1": 0.4
          },
          "behavior": "walk",
          "agents": [
            {
              "id": "generation-0",
              "label": "Gen 0",
              "generation": 0,
              "score": 1.2,
              "root_position_mm": [1.0, 2.0, 0.3],
              "root_quaternion_xyzw": [0.0, 0.0, 0.0, 1.0],
              "joint_angles_rad": {
                "LFCoxa": 0.1,
                "LFFemur": -0.2,
                "LFTibia": 0.3
              },
              "brain_state": {
                "oDN1": 0.4
              },
              "behavior": "walk"
            },
            {
              "id": "generation-4",
              "label": "Gen 4",
              "generation": 4,
              "score": 1.8,
              "root_position_mm": [-8.0, 6.0, 0.3],
              "root_quaternion_xyzw": [0.0, 0.0, 0.2, 0.98],
              "joint_angles_rad": {
                "RFCoxa": -0.1,
                "RFFemur": -0.2,
                "RFTibia": 0.25
              },
              "brain_state": {
                "oDN1": 0.6
              },
              "behavior": "dead",
              "life_state": "dead",
              "death_reason": "terminated",
              "death_time": 1234.5
            }
          ]
        }
        """

        let packet = try JSONDecoder.flyWorld.decode(FlyWorldPosePacket.self, from: Data(payload.utf8))

        XCTAssertEqual(packet.displayAgents.count, 2)
        XCTAssertEqual(packet.displayAgents.map(\.id), ["generation-0", "generation-4"])
        XCTAssertEqual(packet.displayAgents[1].generation, 4)
        XCTAssertTrue(packet.displayAgents[1].isDead)
        XCTAssertEqual(packet.displayAgents[1].deathReason, "terminated")

        let agentPacket = packet.packet(for: packet.displayAgents[1])
        XCTAssertEqual(agentPacket.rootPositionMm, [-8.0, 6.0, 0.3])
        XCTAssertEqual(agentPacket.behavior, "dead")
        XCTAssertTrue(agentPacket.isDead)
        XCTAssertEqual(agentPacket.deathTime, 1234.5)
        XCTAssertNil(agentPacket.agents)
    }
}
