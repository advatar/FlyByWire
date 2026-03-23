"""Embodied FlyGym/MuJoCo simulation bridge.

This module adds a real closed loop on top of the existing connectome model:

1. Sense a simple task arena around the fly.
2. Drive the connectome model from sensory neuron groups.
3. Decode descending-neuron readouts into low-level locomotion commands.
4. Step a FlyGym / NeuroMechFly body in MuJoCo.
5. Stream pose packets to the existing RealityKit viewers.

The heavy runtime dependencies (`flygym`, `torch`, `pandas`, `pyarrow`) are
imported lazily so the light-weight unit tests can exercise the bridge logic
without requiring the full simulation stack.
"""

from __future__ import annotations

import argparse
import ast
import importlib
import inspect
import json
import math
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Protocol, Sequence, Tuple

from runtime_validation import (
    RuntimeDependencyError,
    evaluate_runtime,
    format_runtime_report,
    ready_runtime_check,
    require_runtime,
)


REPO_ROOT = Path(__file__).resolve().parent.parent
NOTEBOOK_PATH = REPO_ROOT / "code" / "paper-phil-drosophila" / "example.ipynb"
DEFAULT_PACKET_PATH = REPO_ROOT / "vision_pro_pose_packet.json"


def clamp(value: float, min_value: float, max_value: float) -> float:
    return max(min_value, min(max_value, value))


def wrap_angle(angle: float) -> float:
    wrapped = math.fmod(angle + math.pi, math.tau)
    if wrapped < 0:
        wrapped += math.tau
    return wrapped - math.pi


def planar_distance(a: Sequence[float], b: Sequence[float]) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])


def heading_to_object(root_position_mm: Sequence[float], heading_rad: float, target_mm: Sequence[float]) -> float:
    dx = target_mm[0] - root_position_mm[0]
    dy = target_mm[1] - root_position_mm[1]
    desired_heading = math.atan2(dy, dx)
    return wrap_angle(desired_heading - heading_rad)


def quaternion_xyzw_from_yaw(yaw_rad: float) -> List[float]:
    half = yaw_rad * 0.5
    return [0.0, 0.0, math.sin(half), math.cos(half)]


def yaw_from_quaternion_xyzw(quaternion_xyzw: Sequence[float]) -> float:
    if len(quaternion_xyzw) < 4:
        return 0.0
    x, y, z, w = quaternion_xyzw[:4]
    siny_cosp = 2.0 * (w * z + x * y)
    cosy_cosp = 1.0 - 2.0 * (y * y + z * z)
    return math.atan2(siny_cosp, cosy_cosp)


def filtered_kwargs(callable_obj: Any, kwargs: Mapping[str, Any]) -> Dict[str, Any]:
    signature = inspect.signature(callable_obj)
    accepted = {}
    for key, value in kwargs.items():
        if key in signature.parameters:
            accepted[key] = value
    return accepted


def mean_or_zero(values: Iterable[float]) -> float:
    values_list = list(values)
    if not values_list:
        return 0.0
    return sum(values_list) / len(values_list)


class EmbodiedRuntimeDependencyError(RuntimeDependencyError):
    """Raised when the embodied simulation runtime is not installed."""


def validate_connectome_runtime() -> None:
    require_runtime(
        ("torch", "pandas", "pyarrow"),
        install_hint=(
            "Embodied connectome mode needs a Python env with torch, pandas, pyarrow, "
            "and NumPy 1.x-compatible wheels. Use `conda env create -f environment.yml` "
            "or install `python3.11 -m pip install \"numpy<2\" pandas pyarrow torch`."
        ),
        error_type=EmbodiedRuntimeDependencyError,
    )


def validate_flygym_runtime() -> None:
    require_runtime(
        ("flygym", "mujoco"),
        install_hint=(
            "Embodied world mode needs FlyGym and MuJoCo. Use "
            "`conda env create -f environment.yml` or install "
            "`python3.11 -m pip install flygym`."
        ),
        error_type=EmbodiedRuntimeDependencyError,
    )


@dataclass(frozen=True)
class SensoryDrive:
    vision: float = 0.0
    odor_left: float = 0.0
    odor_right: float = 0.0
    sugar_contact: float = 0.0
    antennal_touch: float = 0.0


@dataclass(frozen=True)
class DescendingReadout:
    forward_drive: float = 0.0
    left_drive: float = 0.0
    right_drive: float = 0.0
    groom_drive: float = 0.0
    feed_drive: float = 0.0
    escape_drive: float = 0.0
    raw_rates_hz: Mapping[str, float] = field(default_factory=dict)

    def as_brain_state(self) -> Dict[str, float]:
        return {
            "oDN1": self.forward_drive,
            "DNa01": self.left_drive,
            "DNa02": self.right_drive,
            "aDN1": self.groom_drive,
            "MN9": self.feed_drive,
            "loom_escape": self.escape_drive,
        }


@dataclass(frozen=True)
class LowLevelCommand:
    left_drive: float
    right_drive: float
    behavior: str


@dataclass(frozen=True)
class PacketWorldObject:
    id: str
    kind: str
    label: str
    position_mm: Tuple[float, float, float]
    size_mm: Tuple[float, float, float]
    color: Tuple[float, float, float]
    opacity: float
    motion_mode: str = "static"
    orbit_center_mm: Tuple[float, float, float] = (0.0, 0.0, 0.0)
    orbit_radius_mm: float = 0.0
    orbit_speed_hz: float = 0.0
    orbit_phase_rad: float = 0.0

    def at_time(self, time_s: float) -> "PacketWorldObject":
        if self.motion_mode != "orbit":
            return self

        angle = self.orbit_phase_rad + time_s * math.tau * self.orbit_speed_hz
        new_position = (
            self.orbit_center_mm[0] + math.cos(angle) * self.orbit_radius_mm,
            self.orbit_center_mm[1] + math.sin(angle) * self.orbit_radius_mm,
            self.position_mm[2],
        )
        return PacketWorldObject(
            id=self.id,
            kind=self.kind,
            label=self.label,
            position_mm=new_position,
            size_mm=self.size_mm,
            color=self.color,
            opacity=self.opacity,
            motion_mode=self.motion_mode,
            orbit_center_mm=self.orbit_center_mm,
            orbit_radius_mm=self.orbit_radius_mm,
            orbit_speed_hz=self.orbit_speed_hz,
            orbit_phase_rad=self.orbit_phase_rad,
        )

    def to_packet(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind,
            "label": self.label,
            "position_mm": [round(v, 4) for v in self.position_mm],
            "size_mm": [round(v, 4) for v in self.size_mm],
            "color": [round(v, 4) for v in self.color],
            "opacity": round(self.opacity, 4),
        }


@dataclass(frozen=True)
class WorldObservation:
    root_position_mm: Tuple[float, float, float]
    root_quaternion_xyzw: Tuple[float, float, float, float]
    joint_angles_rad: Dict[str, float]
    heading_rad: float
    raw_observation: Optional[Mapping[str, Any]] = None


class BrainBridge(Protocol):
    def reset(self, seed: Optional[int] = None) -> None:
        ...

    def step(self, sensory: SensoryDrive, control_dt_ms: float) -> DescendingReadout:
        ...


class WorldBridge(Protocol):
    def reset(self) -> WorldObservation:
        ...

    def step(self, command: LowLevelCommand) -> WorldObservation:
        ...


class NotebookNeuronRegistry:
    """Extract neuron groups from the paper notebook shipped in the repo."""

    def __init__(self, symbols: Mapping[str, Any]):
        self.symbols = dict(symbols)

    @classmethod
    def load_default(cls, notebook_path: Path = NOTEBOOK_PATH) -> "NotebookNeuronRegistry":
        with notebook_path.open("r", encoding="utf-8") as handle:
            notebook = json.load(handle)

        namespace: Dict[str, Any] = {}
        for cell in notebook.get("cells", []):
            if cell.get("cell_type") != "code":
                continue
            source = "".join(cell.get("source", []))
            if not source.strip():
                continue

            tree = ast.parse(source)
            for node in tree.body:
                if not isinstance(node, ast.Assign):
                    continue
                if not all(isinstance(target, (ast.Name, ast.Tuple)) for target in node.targets):
                    continue
                if not cls._targets_are_name_only(node.targets):
                    continue

                try:
                    value = eval(
                        compile(ast.Expression(node.value), str(notebook_path), "eval"),
                        {"__builtins__": {}},
                        namespace,
                    )
                except Exception:
                    continue

                for target in node.targets:
                    cls._assign_target(target, value, namespace)

        return cls(namespace)

    @staticmethod
    def _targets_are_name_only(targets: Sequence[ast.expr]) -> bool:
        def is_name_only(target: ast.expr) -> bool:
            if isinstance(target, ast.Name):
                return True
            if isinstance(target, ast.Tuple):
                return all(isinstance(element, ast.Name) for element in target.elts)
            return False

        return all(is_name_only(target) for target in targets)

    @staticmethod
    def _assign_target(target: ast.expr, value: Any, namespace: Dict[str, Any]) -> None:
        if isinstance(target, ast.Name):
            namespace[target.id] = value
            return
        if isinstance(target, ast.Tuple):
            if not isinstance(value, (list, tuple)) or len(value) != len(target.elts):
                return
            for element, element_value in zip(target.elts, value):
                if isinstance(element, ast.Name):
                    namespace[element.id] = element_value

    def get_ids(self, *names: str) -> Tuple[int, ...]:
        flattened: List[int] = []
        for name in names:
            value = self.symbols[name]
            if isinstance(value, int):
                flattened.append(value)
            elif isinstance(value, (list, tuple)):
                flattened.extend(int(item) for item in value)
            else:
                raise TypeError(f"Unsupported symbol type for {name}: {type(value)!r}")
        return tuple(flattened)


INPUT_GROUPS = {
    "baseline_walk": ("P9s",),
    "sugar": ("sugar_GRNs",),
    "bitter": ("bitter_GRNs",),
    "visual_loom": ("LC_4s",),
    "touch": ("all_JOs",),
    "odor_aversive": ("Or56a",),
}


OUTPUT_GROUPS = {
    "forward": ("P9_oDN1_left", "P9_oDN1_right"),
    "turn_left": ("DNa01_left", "DNa01_right"),
    "turn_right": ("DNa02_left", "DNa02_right"),
    "escape": ("MDN_1", "MDN_2", "MDN_3", "MDN_4"),
    "escape_fast": ("Giant_Fiber_1", "Giant_Fiber_2"),
    "feed": ("MN9_left", "MN9_right"),
    "groom": ("aDN1_left", "aDN1_right"),
}


class ConnectomeBrainModel:
    """Online PyTorch connectome wrapper for the embodied simulation."""

    def __init__(
        self,
        registry: Optional[NotebookNeuronRegistry] = None,
        device: Optional[str] = None,
        exploration_rate_hz: float = 40.0,
        random_seed: Optional[int] = 0,
    ) -> None:
        import pyarrow  # noqa: F401  - import before torch to avoid libarrow conflicts
        import torch
        from run_pytorch import DT, MODEL_PARAMS, TorchModel, get_hash_tables, get_weights
        from benchmark import path_comp, path_con, path_wt

        self._torch = torch
        self._model_dt_ms = float(DT)
        self._model_params = MODEL_PARAMS
        self._path_comp = path_comp
        self._path_con = path_con
        self._path_wt = path_wt
        self.registry = registry or NotebookNeuronRegistry.load_default()
        self.exploration_rate_hz = exploration_rate_hz

        if device is None:
            device = "cuda" if torch.cuda.is_available() else "cpu"
        self.device = device

        flyid2i, _ = get_hash_tables(str(path_comp))
        self._id_to_index = flyid2i

        self.input_indices = {
            key: self._indices_for_symbols(symbol_names)
            for key, symbol_names in INPUT_GROUPS.items()
        }
        self.output_indices = {
            key: self._indices_for_symbols(symbol_names)
            for key, symbol_names in OUTPUT_GROUPS.items()
        }

        weights = get_weights(str(path_con), str(path_comp), str(path_wt), csr=True)
        self.weights = weights.to(device=device)
        self.num_neurons = int(self.weights.shape[0])
        self.model = TorchModel(
            batch=1,
            size=self.num_neurons,
            dt=self._model_dt_ms,
            params=self._model_params,
            weights=self.weights,
            device=device,
        )
        self._state = self.model.state_init()
        self._rates = torch.zeros(1, self.num_neurons, device=device)
        self._generator = torch.Generator(device=device if device == "cuda" else "cpu")
        if random_seed is not None:
            self._generator.manual_seed(random_seed)

    def _indices_for_symbols(self, symbol_names: Sequence[str]) -> Tuple[int, ...]:
        ids = self.registry.get_ids(*symbol_names)
        missing = [fly_id for fly_id in ids if fly_id not in self._id_to_index]
        if missing:
            raise ValueError(f"Neuron IDs missing from completeness file: {missing[:5]}")
        return tuple(self._id_to_index[fly_id] for fly_id in ids)

    def reset(self, seed: Optional[int] = None) -> None:
        self._state = self.model.state_init()
        self._rates.zero_()
        if seed is not None:
            self._generator.manual_seed(seed)

    def _set_group_rate(self, group: str, rate_hz: float) -> None:
        clamped_rate = max(rate_hz, 0.0)
        if not self.input_indices[group]:
            return
        self._rates[:, list(self.input_indices[group])] = clamped_rate

    def _normalize_rate(self, rate_hz: float, reference_hz: float) -> float:
        return clamp(rate_hz / max(reference_hz, 1e-6), 0.0, 1.5)

    def step(self, sensory: SensoryDrive, control_dt_ms: float) -> DescendingReadout:
        steps = max(1, int(round(control_dt_ms / self._model_dt_ms)))
        duration_s = steps * self._model_dt_ms / 1000.0
        spike_counts = {key: 0.0 for key in self.output_indices}

        self._rates.zero_()
        exploration_scale = 1.0 - clamp(
            max(sensory.vision * 0.8, sensory.antennal_touch * 0.75, sensory.sugar_contact * 0.6),
            0.0,
            0.92,
        )
        self._set_group_rate("baseline_walk", self.exploration_rate_hz * exploration_scale)
        self._set_group_rate("sugar", 250.0 * clamp(sensory.sugar_contact, 0.0, 1.0))
        self._set_group_rate("visual_loom", 220.0 * clamp(sensory.vision, 0.0, 1.0))
        self._set_group_rate("touch", 260.0 * clamp(sensory.antennal_touch, 0.0, 1.0))
        self._set_group_rate(
            "odor_aversive",
            240.0 * clamp(max(sensory.odor_left, sensory.odor_right), 0.0, 1.0),
        )
        self._set_group_rate(
            "bitter",
            220.0 * clamp((sensory.odor_left + sensory.odor_right) * 0.5, 0.0, 1.0),
        )

        for _ in range(steps):
            self._state = self.model.forward(
                self._rates,
                *self._state,
                generator=self._generator,
            )
            spikes = self._state[2]
            for key, indices in self.output_indices.items():
                if not indices:
                    continue
                spike_counts[key] += float(spikes[0, list(indices)].sum().item())

        rates_hz = {}
        for key, count in spike_counts.items():
            index_count = max(len(self.output_indices[key]), 1)
            rates_hz[key] = count / index_count / duration_s

        escape_rate = max(rates_hz["escape"], rates_hz["escape_fast"])
        return DescendingReadout(
            forward_drive=self._normalize_rate(rates_hz["forward"], 70.0),
            left_drive=self._normalize_rate(rates_hz["turn_left"], 45.0),
            right_drive=self._normalize_rate(rates_hz["turn_right"], 45.0),
            groom_drive=self._normalize_rate(rates_hz["groom"], 35.0),
            feed_drive=self._normalize_rate(rates_hz["feed"], 35.0),
            escape_drive=self._normalize_rate(escape_rate, 40.0),
            raw_rates_hz=rates_hz,
        )


class SurrogateBrainModel:
    """Lightweight embodied bridge for development outside the full conda env."""

    def reset(self, seed: Optional[int] = None) -> None:
        _ = seed

    def step(self, sensory: SensoryDrive, control_dt_ms: float) -> DescendingReadout:
        _ = control_dt_ms
        forward = clamp(0.22 + sensory.sugar_contact * 0.24 - sensory.vision * 0.18, 0.0, 1.2)
        lateral_bias = sensory.odor_left - sensory.odor_right
        return DescendingReadout(
            forward_drive=forward,
            left_drive=clamp(max(lateral_bias, 0.0) + sensory.antennal_touch * 0.18, 0.0, 1.0),
            right_drive=clamp(max(-lateral_bias, 0.0) + sensory.vision * 0.12, 0.0, 1.0),
            groom_drive=clamp(sensory.antennal_touch * 0.95, 0.0, 1.0),
            feed_drive=clamp(sensory.sugar_contact * 1.05, 0.0, 1.0),
            escape_drive=clamp(sensory.vision * 1.1, 0.0, 1.2),
            raw_rates_hz={},
        )


class TaskArena:
    """Small virtual task arena overlaid on the MuJoCo body simulation."""

    def __init__(self) -> None:
        self.objects = [
            PacketWorldObject(
                id="sugar-bowl",
                kind="food",
                label="Sugar",
                position_mm=(4.8, -1.8, 0.0),
                size_mm=(1.8, 0.8, 1.8),
                color=(0.98, 0.78, 0.26),
                opacity=0.82,
            ),
            PacketWorldObject(
                id="odor-source",
                kind="odor",
                label="Aversive Odor",
                position_mm=(-4.2, 2.0, 0.4),
                size_mm=(2.4, 2.4, 2.4),
                color=(0.24, 0.84, 0.74),
                opacity=0.18,
            ),
            PacketWorldObject(
                id="visual-target",
                kind="visual_target",
                label="Threat",
                position_mm=(0.0, 4.3, 1.2),
                size_mm=(1.4, 1.4, 1.4),
                color=(1.0, 0.22, 0.18),
                opacity=0.92,
                motion_mode="orbit",
                orbit_center_mm=(0.0, 0.0, 1.2),
                orbit_radius_mm=4.5,
                orbit_speed_hz=0.035,
                orbit_phase_rad=0.25,
            ),
            PacketWorldObject(
                id="obstacle",
                kind="obstacle",
                label="Brush",
                position_mm=(-1.8, -3.8, 0.0),
                size_mm=(2.4, 1.2, 1.8),
                color=(0.46, 0.50, 0.56),
                opacity=0.76,
            ),
        ]

    def snapshot(self, time_s: float) -> List[PacketWorldObject]:
        return [world_object.at_time(time_s) for world_object in self.objects]

    def encode(self, root_position_mm: Sequence[float], heading_rad: float, time_s: float) -> Tuple[SensoryDrive, List[PacketWorldObject]]:
        objects = self.snapshot(time_s)
        sensory = SensoryDrive()
        food_signal = 0.0
        odor_left = 0.0
        odor_right = 0.0
        looming_signal = 0.0
        touch_signal = 0.0

        for world_object in objects:
            distance = planar_distance(root_position_mm, world_object.position_mm)
            bearing = heading_to_object(root_position_mm, heading_rad, world_object.position_mm)
            lateral_left = clamp(-math.sin(bearing), 0.0, 1.0)
            lateral_right = clamp(math.sin(bearing), 0.0, 1.0)

            if world_object.kind == "food":
                food_signal = max(food_signal, clamp(1.0 - distance / 7.0, 0.0, 1.0))
            elif world_object.kind == "odor":
                intensity = clamp(1.0 - distance / 9.5, 0.0, 1.0)
                odor_left = max(odor_left, intensity * max(0.15, lateral_left))
                odor_right = max(odor_right, intensity * max(0.15, lateral_right))
            elif world_object.kind in {"visual_target", "visualtarget"}:
                frontal_weight = clamp(math.cos(bearing), 0.0, 1.0)
                looming_signal = max(
                    looming_signal,
                    clamp(1.25 - distance / 5.5, 0.0, 1.0) * frontal_weight,
                )
            elif world_object.kind == "obstacle":
                ahead_weight = clamp(math.cos(bearing), 0.0, 1.0)
                touch_signal = max(
                    touch_signal,
                    clamp(1.0 - distance / 4.2, 0.0, 1.0) * ahead_weight,
                )

        sensory = SensoryDrive(
            vision=looming_signal,
            odor_left=odor_left,
            odor_right=odor_right,
            sugar_contact=food_signal,
            antennal_touch=touch_signal,
        )
        return sensory, objects


class LowLevelController:
    """Translate descending readouts into a 2-channel turning command."""

    def classify_behavior(self, descending: DescendingReadout) -> str:
        if descending.escape_drive > 0.52:
            return "escape"
        if descending.groom_drive > 0.45:
            return "groom"
        if descending.feed_drive > 0.42:
            return "feed"
        if descending.forward_drive > 0.15:
            return "walk"
        return "idle"

    def command(
        self,
        descending: DescendingReadout,
        root_position_mm: Sequence[float],
        heading_rad: float,
        world_objects: Sequence[PacketWorldObject],
    ) -> LowLevelCommand:
        behavior = self.classify_behavior(descending)
        locomotion = descending.forward_drive
        turn_intent = descending.left_drive - descending.right_drive

        nearest_food = next((obj for obj in world_objects if obj.kind == "food"), None)
        threat = next((obj for obj in world_objects if obj.kind in {"visual_target", "visualtarget"}), None)
        obstacle = next((obj for obj in world_objects if obj.kind == "obstacle"), None)

        if behavior == "feed" and nearest_food is not None:
            turn_intent += clamp(
                heading_to_object(root_position_mm, heading_rad, nearest_food.position_mm) * 0.85,
                -1.0,
                1.0,
            )
            locomotion = max(0.12, min(0.88, locomotion * 0.55 + descending.feed_drive * 0.35))
        elif behavior == "groom":
            locomotion *= 0.08
            turn_intent *= 0.3
        elif behavior == "escape" and threat is not None:
            turn_intent -= clamp(
                heading_to_object(root_position_mm, heading_rad, threat.position_mm),
                -1.2,
                1.2,
            )
            locomotion = max(locomotion, 0.95)

        if obstacle is not None and behavior not in {"idle", "groom"}:
            obstacle_error = heading_to_object(root_position_mm, heading_rad, obstacle.position_mm)
            obstacle_distance = planar_distance(root_position_mm, obstacle.position_mm)
            avoidance_strength = clamp(1.0 - obstacle_distance / 4.0, 0.0, 1.0)
            turn_intent -= clamp(obstacle_error * 0.65, -1.0, 1.0) * avoidance_strength
            locomotion *= 1.0 - avoidance_strength * 0.35

        if behavior == "idle":
            locomotion = 0.0

        left_drive = clamp(locomotion + turn_intent * 0.35, 0.0, 1.4)
        right_drive = clamp(locomotion - turn_intent * 0.35, 0.0, 1.4)
        return LowLevelCommand(left_drive=left_drive, right_drive=right_drive, behavior=behavior)


def canonical_leg_joint_name(raw_name: str) -> Optional[str]:
    normalized = raw_name.replace("_", "").replace("-", "").lower()
    leg_mappings = {
        "lf": "LF",
        "rf": "RF",
        "lm": "LM",
        "rm": "RM",
        "lh": "LH",
        "rh": "RH",
        "leftfront": "LF",
        "rightfront": "RF",
        "leftmiddle": "LM",
        "rightmiddle": "RM",
        "leftmid": "LM",
        "rightmid": "RM",
        "lefthind": "LH",
        "righthind": "RH",
    }
    joint_mappings = {
        "coxa": "Coxa",
        "femur": "Femur",
        "tibia": "Tibia",
    }

    leg_prefix = None
    for token, canonical in leg_mappings.items():
        if token in normalized:
            leg_prefix = canonical
            break

    joint_suffix = None
    for token, canonical in joint_mappings.items():
        if token in normalized:
            joint_suffix = canonical
            break

    if leg_prefix is None or joint_suffix is None:
        return None
    return f"{leg_prefix}{joint_suffix}"


class PosePacketWriter:
    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def write(
        self,
        observation: WorldObservation,
        descending: DescendingReadout,
        behavior: str,
        world_objects: Sequence[PacketWorldObject],
        timestamp: Optional[float] = None,
    ) -> None:
        payload = {
            "timestamp": float(timestamp if timestamp is not None else time.time()),
            "root_position_mm": [round(v, 4) for v in observation.root_position_mm],
            "root_quaternion_xyzw": [round(v, 6) for v in observation.root_quaternion_xyzw],
            "joint_angles_rad": {
                key: round(value, 6)
                for key, value in sorted(observation.joint_angles_rad.items())
            },
            "brain_state": {
                key: round(value, 6)
                for key, value in descending.as_brain_state().items()
            },
            "behavior": behavior,
            "world_objects": [world_object.to_packet() for world_object in world_objects],
        }

        temp_path = self.path.with_suffix(self.path.suffix + ".tmp")
        temp_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        temp_path.replace(self.path)


class MockWorldAdapter:
    """Test-friendly world adapter that mimics the FlyGym bridge surface."""

    def __init__(self, control_dt_s: float):
        self.control_dt_s = control_dt_s
        self.position_mm = [0.0, 0.0, 0.2]
        self.heading_rad = 0.0
        self.phase = 0.0

    def reset(self) -> WorldObservation:
        self.position_mm = [0.0, 0.0, 0.2]
        self.heading_rad = 0.0
        self.phase = 0.0
        return self._observation()

    def step(self, command: LowLevelCommand) -> WorldObservation:
        turn_velocity = (command.left_drive - command.right_drive) * 0.9
        forward_velocity = (command.left_drive + command.right_drive) * 1.2
        self.heading_rad = wrap_angle(self.heading_rad + turn_velocity * self.control_dt_s)
        self.position_mm[0] += math.cos(self.heading_rad) * forward_velocity * self.control_dt_s
        self.position_mm[1] += math.sin(self.heading_rad) * forward_velocity * self.control_dt_s
        self.phase += self.control_dt_s * (command.left_drive + command.right_drive + 0.2) * 4.0
        return self._observation()

    def _observation(self) -> WorldObservation:
        joint_angles = {
            "LFCoxa": 0.22 * math.sin(self.phase),
            "LFFemur": -0.34 + 0.28 * math.sin(self.phase + math.pi * 0.5),
            "LFTibia": 0.44 + 0.18 * math.sin(self.phase + math.pi),
            "RFCoxa": -0.22 * math.sin(self.phase),
            "RFFemur": -0.34 + 0.28 * math.sin(self.phase + math.pi * 1.5),
            "RFTibia": 0.44 + 0.18 * math.sin(self.phase),
            "LMCoxa": 0.18 * math.sin(self.phase + math.pi),
            "LMFemur": -0.28 + 0.24 * math.sin(self.phase + math.pi * 1.5),
            "LMTibia": 0.36 + 0.16 * math.sin(self.phase),
            "RMCoxa": -0.18 * math.sin(self.phase + math.pi),
            "RMFemur": -0.28 + 0.24 * math.sin(self.phase + math.pi * 0.5),
            "RMTibia": 0.36 + 0.16 * math.sin(self.phase + math.pi),
            "LHCoxa": 0.14 * math.sin(self.phase + math.pi * 0.4),
            "LHFemur": -0.24 + 0.22 * math.sin(self.phase + math.pi * 0.9),
            "LHTibia": 0.31 + 0.15 * math.sin(self.phase + math.pi * 1.3),
            "RHCoxa": -0.14 * math.sin(self.phase + math.pi * 0.4),
            "RHFemur": -0.24 + 0.22 * math.sin(self.phase + math.pi * 1.9),
            "RHTibia": 0.31 + 0.15 * math.sin(self.phase + math.pi * 0.3),
        }
        return WorldObservation(
            root_position_mm=(self.position_mm[0], self.position_mm[1], self.position_mm[2]),
            root_quaternion_xyzw=tuple(quaternion_xyzw_from_yaw(self.heading_rad)),  # type: ignore[arg-type]
            joint_angles_rad=joint_angles,
            heading_rad=self.heading_rad,
            raw_observation=None,
        )


class FlyGymWorldAdapter:
    """Real NeuroMechFly/FlyGym world wrapper with a MuJoCo body."""

    def __init__(
        self,
        control_dt_s: float,
        physics_dt_s: float = 1e-4,
        position_scale_mm: float = 1000.0,
    ) -> None:
        self.control_dt_s = control_dt_s
        self.physics_dt_s = physics_dt_s
        self.steps_per_control = max(1, int(round(control_dt_s / physics_dt_s)))
        self.position_scale_mm = position_scale_mm

        self.env = self._make_default_env()
        self._joint_names = self._resolve_joint_names()

    def _import_hybrid_turning_controller(self) -> Any:
        import importlib

        candidates = [
            ("flygym.examples.locomotion", "HybridTurningController"),
            ("flygym.examples.locomotion.turning_controller", "HybridTurningController"),
            ("flygym.examples.locomotion.hybrid_controller", "HybridTurningController"),
        ]
        for module_name, class_name in candidates:
            try:
                module = importlib.import_module(module_name)
                return getattr(module, class_name)
            except Exception:
                continue
        raise ImportError(
            "Unable to import FlyGym HybridTurningController. "
            "Install flygym and verify the locomotion examples are available."
        )

    def _make_default_env(self) -> Any:
        import importlib

        flygym = importlib.import_module("flygym")
        Fly = getattr(flygym, "Fly")
        HybridTurningController = self._import_hybrid_turning_controller()

        contact_sensor_placements = [
            f"{leg}{segment}"
            for leg in ["LF", "LM", "LH", "RF", "RM", "RH"]
            for segment in ["Tibia", "Tarsus1", "Tarsus2", "Tarsus3", "Tarsus4", "Tarsus5"]
        ]

        fly_kwargs = filtered_kwargs(
            Fly,
            {
                "enable_adhesion": True,
                "draw_adhesion": False,
                "enable_vision": True,
                "enable_olfaction": True,
                "contact_sensor_placements": contact_sensor_placements,
                "spawn_pos": (0.0, 0.0, 0.25),
            },
        )
        fly = Fly(**fly_kwargs)
        env_kwargs = filtered_kwargs(
            HybridTurningController,
            {
                "fly": fly,
                "timestep": self.physics_dt_s,
            },
        )
        return HybridTurningController(**env_kwargs)

    def _resolve_joint_names(self) -> List[str]:
        if hasattr(self.env, "fly") and hasattr(self.env.fly, "actuated_joints"):
            return list(self.env.fly.actuated_joints)
        if hasattr(self.env, "actuated_joints"):
            return list(self.env.actuated_joints)
        return []

    def _unpack_reset(self, result: Any) -> Mapping[str, Any]:
        if isinstance(result, tuple) and len(result) >= 1:
            return result[0]
        return result

    def _unpack_step(self, result: Any) -> Mapping[str, Any]:
        if isinstance(result, tuple):
            if len(result) == 5:
                obs, terminated, truncated = result[0], result[2], result[3]
                if terminated or truncated:
                    reset_result = self.env.reset()
                    return self._unpack_reset(reset_result)
                return obs
            if len(result) == 4:
                obs, _, done, _ = result
                if done:
                    reset_result = self.env.reset()
                    return self._unpack_reset(reset_result)
                return obs
        return result

    def reset(self) -> WorldObservation:
        result = self.env.reset()
        obs = self._unpack_reset(result)
        return self._extract_observation(obs)

    def step(self, command: LowLevelCommand) -> WorldObservation:
        try:
            import numpy as np

            action = np.asarray([command.left_drive, command.right_drive], dtype=np.float32)
        except Exception:
            action = [command.left_drive, command.right_drive]

        obs = None
        for _ in range(self.steps_per_control):
            obs = self._unpack_step(self.env.step(action))
        return self._extract_observation(obs)

    def _extract_observation(self, obs: Mapping[str, Any]) -> WorldObservation:
        root_position_mm, root_quaternion_xyzw = self._extract_root_pose(obs)
        heading_rad = yaw_from_quaternion_xyzw(root_quaternion_xyzw)
        joint_angles_rad = self._extract_joint_angles(obs)
        return WorldObservation(
            root_position_mm=root_position_mm,
            root_quaternion_xyzw=root_quaternion_xyzw,
            joint_angles_rad=joint_angles_rad,
            heading_rad=heading_rad,
            raw_observation=obs,
        )

    def _extract_root_pose(self, obs: Mapping[str, Any]) -> Tuple[Tuple[float, float, float], Tuple[float, float, float, float]]:
        physics = getattr(self.env, "physics", None)
        if physics is not None and hasattr(physics, "data"):
            qpos = getattr(physics.data, "qpos", None)
            if qpos is not None and len(qpos) >= 7:
                position = (
                    float(qpos[0]) * self.position_scale_mm,
                    float(qpos[1]) * self.position_scale_mm,
                    float(qpos[2]) * self.position_scale_mm,
                )
                qw, qx, qy, qz = [float(v) for v in qpos[3:7]]
                quaternion = (qx, qy, qz, qw)
                return position, quaternion

        fly_obs = obs.get("fly")
        if fly_obs is not None:
            fly_rows = fly_obs.tolist() if hasattr(fly_obs, "tolist") else fly_obs
            if fly_rows and len(fly_rows[0]) >= 3:
                position = tuple(float(v) * self.position_scale_mm for v in fly_rows[0][:3])  # type: ignore[assignment]
                return position, (0.0, 0.0, 0.0, 1.0)

        return (0.0, 0.0, 0.2), (0.0, 0.0, 0.0, 1.0)

    def _extract_joint_angles(self, obs: Mapping[str, Any]) -> Dict[str, float]:
        joints = obs.get("joints")
        if joints is None:
            return {}

        joint_rows = joints.tolist() if hasattr(joints, "tolist") else joints
        if not joint_rows:
            return {}

        angle_row = joint_rows[0]
        joint_map: Dict[str, float] = {}
        for raw_name, raw_angle in zip(self._joint_names, angle_row):
            canonical = canonical_leg_joint_name(raw_name)
            if canonical is None:
                continue
            joint_map[canonical] = float(raw_angle)
        return joint_map


class EmbodiedSimulation:
    def __init__(
        self,
        brain: BrainBridge,
        world: WorldBridge,
        packet_writer: PosePacketWriter,
        arena: Optional[TaskArena] = None,
        controller: Optional[LowLevelController] = None,
        control_dt_s: float = 0.015,
    ) -> None:
        self.brain = brain
        self.world = world
        self.packet_writer = packet_writer
        self.arena = arena or TaskArena()
        self.controller = controller or LowLevelController()
        self.control_dt_s = control_dt_s

    def run(self, steps: int, real_time: bool = False) -> None:
        self.brain.reset()
        observation = self.world.reset()

        for step_index in range(steps):
            tick_time_s = step_index * self.control_dt_s
            sensory, world_objects = self.arena.encode(
                root_position_mm=observation.root_position_mm,
                heading_rad=observation.heading_rad,
                time_s=tick_time_s,
            )
            descending = self.brain.step(sensory, control_dt_ms=self.control_dt_s * 1000.0)
            command = self.controller.command(
                descending=descending,
                root_position_mm=observation.root_position_mm,
                heading_rad=observation.heading_rad,
                world_objects=world_objects,
            )
            observation = self.world.step(command)
            self.packet_writer.write(
                observation=observation,
                descending=descending,
                behavior=command.behavior,
                world_objects=world_objects,
            )
            if real_time:
                time.sleep(self.control_dt_s)


def collect_embodied_runtime_checks(args: argparse.Namespace):
    from benchmark import path_comp, path_con

    checks = []
    if args.brain == "surrogate":
        checks.append(
            ready_runtime_check(
                name="Embodied brain runtime",
                detail="Using surrogate brain mode; no heavy connectome dependencies required.",
            )
        )
    else:
        checks.append(
            evaluate_runtime(
                name="Embodied brain runtime",
                module_names=("torch", "pandas", "pyarrow"),
                install_hint=(
                    "Embodied connectome mode needs a Python env with torch, pandas, pyarrow, "
                    "and NumPy 1.x-compatible wheels. Use `conda env create -f environment.yml`."
                ),
                required_paths=(
                    (NOTEBOOK_PATH, "Notebook neuron registry"),
                    (path_comp, "Completeness CSV"),
                    (path_con, "Connectivity parquet"),
                ),
            )
        )

    if args.world == "mock":
        checks.append(
            ready_runtime_check(
                name="Embodied world runtime",
                detail="Using mock world mode; FlyGym and MuJoCo are not required.",
            )
        )
    else:
        checks.append(
            evaluate_runtime(
                name="Embodied world runtime",
                module_names=("flygym", "mujoco"),
                install_hint=(
                    "Embodied world mode needs FlyGym and MuJoCo. Use "
                    "`conda env create -f environment.yml` or install "
                    "`python3.11 -m pip install flygym`."
                ),
            )
        )
    return checks


def format_embodied_runtime_report(args: argparse.Namespace) -> str:
    return format_runtime_report(
        title="Embodied runtime validation",
        checks=collect_embodied_runtime_checks(args),
    )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the embodied MuJoCo/FlyGym fly simulation")
    parser.add_argument(
        "--packet-path",
        type=Path,
        default=DEFAULT_PACKET_PATH,
        help=f"Path to write the viewer pose packet. Default: {DEFAULT_PACKET_PATH}",
    )
    parser.add_argument(
        "--steps",
        type=int,
        default=240,
        help="Number of brain/body control steps to run. Default: 240",
    )
    parser.add_argument(
        "--control-dt-ms",
        type=float,
        default=15.0,
        help="Brain/body control interval in milliseconds. Default: 15.0",
    )
    parser.add_argument(
        "--physics-dt-ms",
        type=float,
        default=0.1,
        help="MuJoCo physics timestep in milliseconds. Default: 0.1",
    )
    parser.add_argument(
        "--world",
        choices=["flygym", "mock"],
        default="flygym",
        help="World backend. Use 'mock' for tests or without FlyGym. Default: flygym",
    )
    parser.add_argument(
        "--brain",
        choices=["connectome", "surrogate"],
        default="connectome",
        help="Brain backend. Use 'surrogate' when the full torch/pandas stack is unavailable. Default: connectome",
    )
    parser.add_argument(
        "--device",
        type=str,
        default=None,
        help="Torch device for the connectome model. Default: auto",
    )
    parser.add_argument(
        "--real-time",
        action="store_true",
        help="Sleep between control steps so the packet stream advances in wall-clock time.",
    )
    parser.add_argument(
        "--validate",
        action="store_true",
        help="Validate the selected embodied runtime dependencies, then exit.",
    )
    return parser


def run_from_args(args: argparse.Namespace) -> int:
    if args.validate:
        print(format_embodied_runtime_report(args))
        checks = collect_embodied_runtime_checks(args)
        return 0 if all(check.available for check in checks) else 1

    control_dt_s = args.control_dt_ms / 1000.0
    packet_writer = PosePacketWriter(args.packet_path)
    if args.brain == "surrogate":
        brain: BrainBridge = SurrogateBrainModel()
    else:
        validate_connectome_runtime()
        brain = ConnectomeBrainModel(device=args.device)

    if args.world == "mock":
        world: WorldBridge = MockWorldAdapter(control_dt_s=control_dt_s)
    else:
        validate_flygym_runtime()
        world = FlyGymWorldAdapter(
            control_dt_s=control_dt_s,
            physics_dt_s=args.physics_dt_ms / 1000.0,
        )

    simulation = EmbodiedSimulation(
        brain=brain,
        world=world,
        packet_writer=packet_writer,
        control_dt_s=control_dt_s,
    )
    simulation.run(steps=args.steps, real_time=args.real_time)
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    try:
        return run_from_args(args)
    except EmbodiedRuntimeDependencyError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
