import json
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "code"))

from embodied_simulation import (  # noqa: E402
    DescendingReadout,
    EmbodiedSimulation,
    LowLevelController,
    MockWorldAdapter,
    NotebookNeuronRegistry,
    PacketWorldObject,
    PosePacketWriter,
    SensoryDrive,
    TaskArena,
    canonical_leg_joint_name,
)


class StaticBrain:
    def reset(self, seed=None):
        self.seed = seed

    def step(self, sensory: SensoryDrive, control_dt_ms: float) -> DescendingReadout:
        return DescendingReadout(
            forward_drive=max(0.2, sensory.sugar_contact * 0.6),
            left_drive=sensory.odor_left * 0.4,
            right_drive=sensory.odor_right * 0.4,
            groom_drive=sensory.antennal_touch * 0.7,
            feed_drive=sensory.sugar_contact * 0.8,
            escape_drive=sensory.vision * 0.9,
        )


class EmbodiedSimulationTests(unittest.TestCase):
    def test_notebook_registry_loads_known_groups(self):
        registry = NotebookNeuronRegistry.load_default()

        self.assertEqual(len(registry.get_ids("P9s")), 2)
        self.assertGreater(len(registry.get_ids("sugar_GRNs")), 10)
        self.assertGreater(len(registry.get_ids("all_JOs")), 20)
        self.assertEqual(len(registry.get_ids("P9_oDN1_left", "P9_oDN1_right")), 2)

    def test_canonical_leg_joint_name_normalizes_common_tokens(self):
        self.assertEqual(canonical_leg_joint_name("joint_LFCoxa"), "LFCoxa")
        self.assertEqual(canonical_leg_joint_name("right_mid_femur"), "RMFemur")
        self.assertEqual(canonical_leg_joint_name("LeftHindTibia"), "LHTibia")
        self.assertIsNone(canonical_leg_joint_name("neck_yaw"))

    def test_task_arena_increases_food_signal_near_sugar(self):
        arena = TaskArena()

        far_sensory, _ = arena.encode((0.0, 0.0, 0.2), 0.0, time_s=0.0)
        near_sensory, _ = arena.encode((4.5, -1.7, 0.2), 0.0, time_s=0.0)

        self.assertGreater(near_sensory.sugar_contact, far_sensory.sugar_contact)
        self.assertGreaterEqual(far_sensory.vision, 0.0)

    def test_low_level_controller_biases_toward_food_during_feed(self):
        controller = LowLevelController()
        command = controller.command(
            descending=DescendingReadout(
                forward_drive=0.3,
                left_drive=0.0,
                right_drive=0.0,
                groom_drive=0.0,
                feed_drive=0.9,
                escape_drive=0.0,
            ),
            root_position_mm=(0.0, 0.0, 0.2),
            heading_rad=0.0,
            world_objects=[
                PacketWorldObject(
                    id="food",
                    kind="food",
                    label="Sugar",
                    position_mm=(0.0, 3.0, 0.0),
                    size_mm=(1.0, 1.0, 1.0),
                    color=(1.0, 0.8, 0.2),
                    opacity=0.8,
                )
            ],
        )

        self.assertEqual(command.behavior, "feed")
        self.assertNotEqual(command.left_drive, command.right_drive)

    def test_embodied_simulation_writes_pose_packet(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            packet_path = Path(temp_dir) / "vision_pro_pose_packet.json"
            writer = PosePacketWriter(packet_path)
            simulation = EmbodiedSimulation(
                brain=StaticBrain(),
                world=MockWorldAdapter(control_dt_s=0.015),
                packet_writer=writer,
                control_dt_s=0.015,
            )

            simulation.run(steps=4, real_time=False)

            payload = json.loads(packet_path.read_text(encoding="utf-8"))
            self.assertIn("root_position_mm", payload)
            self.assertIn("brain_state", payload)
            self.assertIn("joint_angles_rad", payload)
            self.assertIn("world_objects", payload)
            self.assertIn("LFCoxa", payload["joint_angles_rad"])
            self.assertIn("RHTibia", payload["joint_angles_rad"])
            self.assertEqual(set(payload["brain_state"].keys()), {"DNa01", "DNa02", "oDN1", "aDN1", "MN9", "loom_escape"})


if __name__ == "__main__":
    unittest.main()
