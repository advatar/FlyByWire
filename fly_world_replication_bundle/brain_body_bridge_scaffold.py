"""Minimal scaffold for a public approximation of the embodied fly stack.

This is intentionally a skeleton rather than a drop-in executable system.
It shows where FlyGym / MuJoCo, the connectome-based brain model, and a
Vision Pro pose stream would connect.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, Iterable, Mapping
import json
import time


@dataclass
class SensoryDrive:
    vision: float = 0.0
    odor_left: float = 0.0
    odor_right: float = 0.0
    sugar_contact: float = 0.0
    antennal_touch: float = 0.0


@dataclass
class DescendingState:
    forward_drive: float = 0.0
    left_drive: float = 0.0
    right_drive: float = 0.0
    groom_drive: float = 0.0
    feed_drive: float = 0.0
    escape_drive: float = 0.0


class BrainAdapter:
    """Wrap the public fly-brain model or a surrogate.

    Replace `step` with:
      - calls into eonsystemspbc/fly-brain, or
      - a simplified bridge to selected neuron groups / ROIs.
    """

    def __init__(self) -> None:
        self.state: Dict[str, float] = {}

    def step(self, sensory: SensoryDrive, dt: float) -> Mapping[str, float]:
        # Placeholder logic. Replace with the actual connectome/LIF model.
        odor_bias = sensory.odor_left - sensory.odor_right
        return {
            "DNa01": max(0.0, odor_bias),
            "DNa02": max(0.0, -odor_bias),
            "oDN1": max(0.0, (sensory.odor_left + sensory.odor_right) * 0.5),
            "aDN1": sensory.antennal_touch,
            "MN9": sensory.sugar_contact,
            "loom_escape": sensory.vision,
        }


class DescendingDecoder:
    """Map brain outputs into a small behavior/control interface."""

    def decode(self, brain_state: Mapping[str, float]) -> DescendingState:
        return DescendingState(
            forward_drive=float(brain_state.get("oDN1", 0.0)),
            left_drive=float(brain_state.get("DNa01", 0.0)),
            right_drive=float(brain_state.get("DNa02", 0.0)),
            groom_drive=float(brain_state.get("aDN1", 0.0)),
            feed_drive=float(brain_state.get("MN9", 0.0)),
            escape_drive=float(brain_state.get("loom_escape", 0.0)),
        )


class LowLevelController:
    """Bridge descending state into FlyGym/FlyBody actions.

    For a first version, map left/right drive into a 2D turning controller:
      action = [left_gain, right_gain]
    and use mode switches for grooming / feeding.
    """

    def action_from_descending(
        self,
        descending: DescendingState,
        obs: Mapping[str, Any],
    ) -> Mapping[str, Any]:
        # Example 2-D steering handle compatible with a turning controller.
        left = max(0.2, min(1.0, descending.forward_drive + descending.left_drive))
        right = max(0.2, min(1.0, descending.forward_drive + descending.right_drive))
        return {
            "locomotion_drive": [left, right],
            "groom": descending.groom_drive > 0.5,
            "feed": descending.feed_drive > 0.5,
            "escape": descending.escape_drive > 0.5,
        }


class PoseStreamer:
    """Write a very simple JSON packet stream for a Vision Pro client."""

    def __init__(self, path: str) -> None:
        self.path = path

    def emit(
        self,
        obs: Mapping[str, Any],
        brain_state: Mapping[str, float],
        behavior: str,
    ) -> None:
        packet = {
            "timestamp": time.time(),
            "root_position_mm": obs.get("root_position_mm", [0.0, 0.0, 0.0]),
            "root_quaternion_xyzw": obs.get(
                "root_quaternion_xyzw", [0.0, 0.0, 0.0, 1.0]
            ),
            "joint_angles_rad": obs.get("joint_angles_rad", {}),
            "brain_state": dict(brain_state),
            "behavior": behavior,
        }
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(packet, f, indent=2)


class WorldAdapter:
    """Placeholder for a FlyGym / MuJoCo world wrapper."""

    def reset(self) -> Mapping[str, Any]:
        return {
            "root_position_mm": [0.0, 0.0, 0.2],
            "root_quaternion_xyzw": [0.0, 0.0, 0.0, 1.0],
            "joint_angles_rad": {},
        }

    def observe(self) -> Mapping[str, Any]:
        return {
            "odor_intensity": [0.2, 0.4],
            "sugar_contact": 0.0,
            "vision_signal": 0.0,
            "antennal_touch": 0.0,
            "root_position_mm": [0.0, 0.0, 0.2],
            "root_quaternion_xyzw": [0.0, 0.0, 0.0, 1.0],
            "joint_angles_rad": {},
        }

    def step(self, action: Mapping[str, Any]) -> Mapping[str, Any]:
        # Replace with env.step(action) from FlyGym.
        return self.observe()


def encode_sensory(obs: Mapping[str, Any]) -> SensoryDrive:
    odor = obs.get("odor_intensity", [0.0, 0.0])
    return SensoryDrive(
        vision=float(obs.get("vision_signal", 0.0)),
        odor_left=float(odor[0]),
        odor_right=float(odor[1]),
        sugar_contact=float(obs.get("sugar_contact", 0.0)),
        antennal_touch=float(obs.get("antennal_touch", 0.0)),
    )


def classify_behavior(descending: DescendingState) -> str:
    if descending.escape_drive > 0.5:
        return "escape"
    if descending.groom_drive > 0.5:
        return "groom"
    if descending.feed_drive > 0.5:
        return "feed"
    if descending.forward_drive > 0.2:
        return "walk"
    return "idle"


def main(num_steps: int = 300, dt: float = 0.015) -> None:
    world = WorldAdapter()
    brain = BrainAdapter()
    decoder = DescendingDecoder()
    controller = LowLevelController()
    streamer = PoseStreamer("vision_pro_pose_packet.json")

    obs = world.reset()
    for _ in range(num_steps):
        obs = world.observe()
        sensory = encode_sensory(obs)
        brain_state = brain.step(sensory, dt=dt)
        descending = decoder.decode(brain_state)
        action = controller.action_from_descending(descending, obs)
        obs = world.step(action)
        behavior = classify_behavior(descending)
        streamer.emit(obs, brain_state, behavior)
        time.sleep(dt)


if __name__ == "__main__":
    main()
