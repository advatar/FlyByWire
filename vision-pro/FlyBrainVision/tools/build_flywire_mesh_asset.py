#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from cloudvolume import CloudVolume


SEG_PATH = "precomputed://gs://flywire_v141_m783"
DEFAULT_ROOT_IDS = [
    720575940603464672,
    720575940604088288,
    720575940604470240,
]
DEFAULT_COLORS = [
    [0.96, 0.66, 0.28, 1.0],
    [0.37, 0.82, 0.77, 1.0],
    [0.91, 0.84, 0.72, 1.0],
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fetch and simplify a small set of public FlyWire neuron meshes."
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("FlyBrainVision/Resources/FlyWireMeshes.json"),
        help="Output JSON asset path.",
    )
    parser.add_argument(
        "--cell-size",
        type=float,
        default=1500.0,
        help="Vertex clustering cell size in nanometers.",
    )
    parser.add_argument(
        "root_ids",
        nargs="*",
        type=int,
        default=DEFAULT_ROOT_IDS,
        help="FlyWire root IDs to fetch.",
    )
    return parser.parse_args()


def fetch_mesh(cv: CloudVolume, root_id: int):
    for lod in range(4, -2, -1):
        try:
            mesh = cv.mesh.get(root_id, lod=lod)
            if isinstance(mesh, dict):
                mesh = mesh[root_id]
            return mesh.vertices.astype(np.float32), mesh.faces.astype(np.int32), lod
        except Exception:
            continue
    raise RuntimeError(f"Could not fetch mesh for root ID {root_id}")


def simplify(vertices: np.ndarray, faces: np.ndarray, cell_size: float) -> tuple[np.ndarray, np.ndarray]:
    quantized = np.floor(vertices / cell_size).astype(np.int64)
    _, inverse = np.unique(quantized, axis=0, return_inverse=True)

    sums = np.zeros((inverse.max() + 1, 3), dtype=np.float64)
    counts = np.zeros(inverse.max() + 1, dtype=np.int64)
    np.add.at(sums, inverse, vertices)
    np.add.at(counts, inverse, 1)

    simplified_vertices = sums / counts[:, None]
    simplified_faces = inverse[faces]
    valid = (
        (simplified_faces[:, 0] != simplified_faces[:, 1])
        & (simplified_faces[:, 1] != simplified_faces[:, 2])
        & (simplified_faces[:, 0] != simplified_faces[:, 2])
    )
    return simplified_vertices.astype(np.float32), simplified_faces[valid].astype(np.int32)


def normalize_parts(parts: list[dict]) -> list[dict]:
    all_vertices = np.concatenate([np.asarray(part["vertices"], dtype=np.float32) for part in parts], axis=0)
    center = all_vertices.mean(axis=0, keepdims=True)
    scale = np.abs(all_vertices - center).max()
    normalized_parts = []
    for part in parts:
        vertices = (np.asarray(part["vertices"], dtype=np.float32) - center) / scale
        normalized_parts.append(
            {
                **part,
                "vertices": [[round(float(value), 6) for value in vertex] for vertex in vertices],
            }
        )
    return normalized_parts


def main() -> None:
    args = parse_args()
    cv = CloudVolume(SEG_PATH, use_https=True, fill_missing=True)

    parts = []
    for color, root_id in zip(DEFAULT_COLORS, args.root_ids):
        vertices, faces, lod = fetch_mesh(cv, root_id)
        vertices, faces = simplify(vertices, faces, args.cell_size)
        parts.append(
            {
                "name": str(root_id),
                "color": color,
                "lod": lod,
                "vertices": vertices.tolist(),
                "faces": faces.tolist(),
            }
        )
        print(f"Fetched {root_id} at LOD {lod}: {vertices.shape[0]} vertices, {faces.shape[0]} faces after simplification")

    payload = {
        "metadata": {
            "title": "FlyWire Sample Meshes",
            "description": "Real neuron meshes fetched from the public FlyWire v783 segmentation.",
            "source": SEG_PATH,
            "rootIDs": [str(root_id) for root_id in args.root_ids],
            "cellSizeNm": args.cell_size,
        },
        "parts": normalize_parts(parts),
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, separators=(",", ":")))
    print(f"Wrote FlyWire mesh asset to {args.output}")


if __name__ == "__main__":
    main()
