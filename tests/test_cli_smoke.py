import json
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def run_cli(*args):
    return subprocess.run(
        [sys.executable, str(REPO_ROOT / "main.py"), *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def test_main_help_smoke():
    result = run_cli("--help")

    assert result.returncode == 0
    assert "Drosophila brain model benchmark" in result.stdout
    assert "--validate" in result.stdout


def test_embodied_validate_surrogate_mock_smoke():
    result = run_cli("--embodied", "--validate", "--brain", "surrogate", "--world", "mock")

    assert result.returncode == 0
    assert "Embodied runtime validation" in result.stdout
    assert "Embodied brain runtime" in result.stdout
    assert "Embodied world runtime" in result.stdout


def test_embodied_mock_cli_writes_pose_packet(tmp_path):
    packet_path = tmp_path / "vision_pro_pose_packet.json"

    result = run_cli(
        "--embodied",
        "--brain",
        "surrogate",
        "--world",
        "mock",
        "--steps",
        "3",
        "--packet-path",
        str(packet_path),
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(packet_path.read_text(encoding="utf-8"))
    assert "root_position_mm" in payload
    assert "brain_state" in payload
    assert "joint_angles_rad" in payload
    assert "world_objects" in payload
