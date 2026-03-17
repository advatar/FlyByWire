#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import struct
import urllib.request
from pathlib import Path

import numpy as np


DEFAULT_URL = (
    "https://github.com/schlegelp/navis-flybrains/raw/main/flybrains/meshes/JRC2018U.ply"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download and convert a public atlas PLY mesh into a bundled JSON asset."
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_URL,
        help="Source URL for the atlas PLY mesh.",
    )
    parser.add_argument(
        "--ply-cache",
        type=Path,
        default=Path("/tmp/JRC2018U.ply"),
        help="Temporary local PLY path.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("FlyBrainVision/Resources/AtlasMesh.json"),
        help="Output JSON asset path.",
    )
    return parser.parse_args()


def download(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    urllib.request.urlretrieve(url, destination)


def load_binary_ply(path: Path) -> tuple[np.ndarray, np.ndarray]:
    with path.open("rb") as handle:
        header_lines = []
        while True:
            line = handle.readline()
            header_lines.append(line)
            if line == b"end_header\n":
                break

        header = b"".join(header_lines).decode("ascii")
        vertex_count = int(
            next(line.split()[-1] for line in header.splitlines() if line.startswith("element vertex"))
        )
        face_count = int(
            next(line.split()[-1] for line in header.splitlines() if line.startswith("element face"))
        )

        vertices = np.frombuffer(handle.read(vertex_count * 12), dtype="<f4").reshape(vertex_count, 3)
        faces = np.empty((face_count, 3), dtype=np.int32)
        for face_index in range(face_count):
            list_size = struct.unpack("<B", handle.read(1))[0]
            if list_size != 3:
                raise ValueError(f"Expected triangular faces, got list size {list_size}")
            faces[face_index] = struct.unpack("<iii", handle.read(12))

    return vertices, faces


def normalize_vertices(vertices: np.ndarray) -> np.ndarray:
    centered = vertices - vertices.mean(axis=0, keepdims=True)
    scale = np.abs(centered).max()
    return centered / scale if scale else centered


def main() -> None:
    args = parse_args()
    download(args.url, args.ply_cache)
    vertices, faces = load_binary_ply(args.ply_cache)
    vertices = normalize_vertices(vertices)

    payload = {
        "metadata": {
            "title": "JRC2018U Atlas",
            "description": "Public whole-brain anatomical atlas mesh.",
            "sourceURL": args.url,
        },
        "parts": [
            {
                "name": "Atlas",
                "color": [0.56, 0.76, 0.90, 1.0],
                "vertices": [[round(float(value), 6) for value in vertex] for vertex in vertices],
                "faces": faces.tolist(),
            }
        ],
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, separators=(",", ":")))
    print(
        f"Wrote atlas asset with {vertices.shape[0]} vertices and {faces.shape[0]} faces to {args.output}"
    )


if __name__ == "__main__":
    main()
