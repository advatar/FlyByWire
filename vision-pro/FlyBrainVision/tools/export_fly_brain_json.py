#!/usr/bin/env python3
"""
Build an abstract 3D connectome layout for the Whole Fly mode.

Inputs expected from the repo:
  - data/2025_Completeness_783.csv
  - data/2025_Connectivity_783.parquet

Output:
  - JSON consumable by the integrated whole-fly RealityKit scene.

This exporter intentionally creates an abstract graph layout, not an anatomical
mesh. The current fly-brain repo contains connectivity and simulation data, but
not a packaged full-fly body mesh.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.sparse import coo_matrix, diags
from scipy.sparse.linalg import eigsh


PRESYN_COL = "Presynaptic_Index"
POSTSYN_COL = "Postsynaptic_Index"
WEIGHT_COL = "Excitatory x Connectivity"


@dataclass(frozen=True)
class Paths:
    completeness: Path
    connectivity: Path
    output: Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export an abstract fly-brain graph for the Whole Fly visionOS mode."
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path("."),
        help="Path to the cloned fly-brain repository. Default: current directory.",
    )
    parser.add_argument(
        "--completeness-file",
        type=Path,
        default=None,
        help="Override path to 2025_Completeness_783.csv.",
    )
    parser.add_argument(
        "--connectivity-file",
        type=Path,
        default=None,
        help="Override path to 2025_Connectivity_783.parquet.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("FlyBrainVision/Resources/flybrain_for_vision_pro.json"),
        help="Output JSON path.",
    )
    parser.add_argument(
        "--max-nodes",
        type=int,
        default=420,
        help="Maximum number of nodes to keep. Lower values run faster.",
    )
    parser.add_argument(
        "--max-edges",
        type=int,
        default=1200,
        help="Maximum number of edges to keep after filtering to selected nodes.",
    )
    parser.add_argument(
        "--focus-ids-file",
        type=Path,
        default=None,
        help="Optional text file with one FlyWire root ID per line to highlight.",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=7,
        help="Random seed used for deterministic fallbacks.",
    )
    return parser.parse_args()


def resolve_paths(args: argparse.Namespace) -> Paths:
    repo_root = args.repo_root.resolve()
    completeness = (
        args.completeness_file.resolve()
        if args.completeness_file
        else (repo_root / "data" / "2025_Completeness_783.csv").resolve()
    )
    connectivity = (
        args.connectivity_file.resolve()
        if args.connectivity_file
        else (repo_root / "data" / "2025_Connectivity_783.parquet").resolve()
    )
    output = args.output.resolve()
    return Paths(completeness=completeness, connectivity=connectivity, output=output)


def read_focus_ids(path: Path | None) -> set[int]:
    if path is None:
        return set()
    ids: set[int] = set()
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        ids.add(int(line))
    return ids


def fibonacci_sphere(n: int, rng: np.random.Generator | None = None) -> np.ndarray:
    if n <= 0:
        return np.zeros((0, 3), dtype=np.float32)
    if n == 1:
        return np.array([[0.0, 0.0, 0.0]], dtype=np.float32)

    rng = rng or np.random.default_rng(0)
    points = np.zeros((n, 3), dtype=np.float64)
    golden_angle = math.pi * (3.0 - math.sqrt(5.0))

    for i in range(n):
        y = 1.0 - (2.0 * i) / (n - 1)
        radius = math.sqrt(max(0.0, 1.0 - y * y))
        theta = golden_angle * i
        x = math.cos(theta) * radius
        z = math.sin(theta) * radius
        points[i] = (x, y, z)

    jitter = rng.normal(0.0, 0.015, size=points.shape)
    points += jitter
    points -= points.mean(axis=0, keepdims=True)
    scale = np.linalg.norm(points, axis=1).max()
    if scale > 0:
        points /= scale
    return points.astype(np.float32)


def normalize_coords(coords: np.ndarray) -> np.ndarray:
    coords = np.asarray(coords, dtype=np.float64)
    if coords.size == 0:
        return coords.astype(np.float32)
    coords -= coords.mean(axis=0, keepdims=True)
    radius = np.linalg.norm(coords, axis=1).max()
    if radius > 0:
        coords /= radius
    return coords.astype(np.float32)


def spectral_layout(
    num_nodes: int,
    sources: np.ndarray,
    targets: np.ndarray,
    weights: np.ndarray,
    seed: int,
) -> np.ndarray:
    rng = np.random.default_rng(seed)

    if num_nodes < 4 or len(weights) == 0:
        return fibonacci_sphere(num_nodes, rng=rng)

    try:
        adjacency = coo_matrix(
            (weights, (sources, targets)),
            shape=(num_nodes, num_nodes),
            dtype=np.float64,
        ).tocsr()
        adjacency = adjacency + adjacency.transpose()
        adjacency.sum_duplicates()

        if adjacency.nnz == 0:
            return fibonacci_sphere(num_nodes, rng=rng)

        degree = np.asarray(adjacency.sum(axis=1)).ravel()
        laplacian = diags(degree) - adjacency

        k = min(4, num_nodes - 1)
        eigenvalues, eigenvectors = eigsh(laplacian, k=k, which="SM")
        order = np.argsort(eigenvalues)
        eigenvectors = eigenvectors[:, order]

        if eigenvectors.shape[1] >= 4:
            coords = eigenvectors[:, 1:4]
        elif eigenvectors.shape[1] == 3:
            coords = eigenvectors[:, :3]
        else:
            coords = fibonacci_sphere(num_nodes, rng=rng)

        coords = normalize_coords(coords)

        deg_norm = np.log1p(degree)
        if deg_norm.max() > deg_norm.min():
            deg_norm = (deg_norm - deg_norm.min()) / (deg_norm.max() - deg_norm.min())
            radial_scale = 0.6 + 0.6 * deg_norm[:, None]
            coords = normalize_coords(coords * radial_scale)

        return coords.astype(np.float32)
    except Exception as exc:  # pragma: no cover
        print(
            f"[warn] Spectral layout failed ({exc!r}); falling back to spherical layout.",
            file=sys.stderr,
        )
        return fibonacci_sphere(num_nodes, rng=rng)


def color_gradient(t: float) -> list[float]:
    t = max(0.0, min(1.0, float(t)))
    if t < 0.5:
        u = t / 0.5
        r = 0.1 * (1.0 - u) + 0.0 * u
        g = 0.35 * (1.0 - u) + 0.9 * u
        b = 0.95
    else:
        u = (t - 0.5) / 0.5
        r = 1.0 * u
        g = 0.9 * (1.0 - u) + 0.85 * u
        b = 0.95 * (1.0 - u) + 0.2 * u
    return [round(r, 4), round(g, 4), round(b, 4)]


def ensure_columns(conn: pd.DataFrame) -> None:
    required = {PRESYN_COL, POSTSYN_COL, WEIGHT_COL}
    missing = required.difference(conn.columns)
    if missing:
        raise ValueError(
            "Connectivity file is missing required columns: "
            + ", ".join(sorted(missing))
        )


def weighted_degree_from_edges(conn: pd.DataFrame) -> pd.Series:
    presyn = conn.groupby(PRESYN_COL, sort=False)[WEIGHT_COL].sum()
    postsyn = conn.groupby(POSTSYN_COL, sort=False)[WEIGHT_COL].sum()
    degree = presyn.add(postsyn, fill_value=0.0)
    return degree.sort_values(ascending=False)


def pick_nodes(
    degree: pd.Series,
    flywire_ids: np.ndarray,
    max_nodes: int,
    focus_ids: set[int],
) -> tuple[np.ndarray, set[int]]:
    max_nodes = max(1, max_nodes)

    flywire_to_index = {int(fid): idx for idx, fid in enumerate(flywire_ids.tolist())}
    focus_indices = {flywire_to_index[fid] for fid in focus_ids if fid in flywire_to_index}

    ranked_indices = degree.index.to_numpy(dtype=np.int64, copy=False)
    selected: list[int] = []
    seen: set[int] = set()

    for idx in focus_indices:
        if idx not in seen:
            selected.append(int(idx))
            seen.add(int(idx))

    for idx in ranked_indices:
        idx = int(idx)
        if idx not in seen:
            selected.append(idx)
            seen.add(idx)
        if len(selected) >= max_nodes:
            break

    return np.array(selected[:max_nodes], dtype=np.int64), focus_indices


def build_export(
    conn: pd.DataFrame,
    flywire_ids: np.ndarray,
    selected_indices: np.ndarray,
    focus_indices: set[int],
    max_edges: int,
    seed: int,
    source_paths: Paths,
) -> dict:
    selection_set = set(selected_indices.tolist())
    subset = conn[
        conn[PRESYN_COL].isin(selection_set) & conn[POSTSYN_COL].isin(selection_set)
    ][[PRESYN_COL, POSTSYN_COL, WEIGHT_COL]].copy()

    if subset.empty:
        raise ValueError(
            "No edges survived filtering. Try increasing --max-nodes or relax any focus selection."
        )

    subset.sort_values(WEIGHT_COL, ascending=False, inplace=True)
    if len(subset) > max_edges:
        subset = subset.head(max_edges).copy()

    remap = {old_idx: new_idx for new_idx, old_idx in enumerate(selected_indices.tolist())}
    subset["source"] = subset[PRESYN_COL].map(remap)
    subset["target"] = subset[POSTSYN_COL].map(remap)

    sources = subset["source"].to_numpy(dtype=np.int64, copy=False)
    targets = subset["target"].to_numpy(dtype=np.int64, copy=False)
    weights = subset[WEIGHT_COL].to_numpy(dtype=np.float64, copy=False)

    num_nodes = len(selected_indices)
    coords = spectral_layout(num_nodes, sources, targets, weights, seed=seed)

    filtered_degree = np.zeros(num_nodes, dtype=np.float64)
    np.add.at(filtered_degree, sources, weights)
    np.add.at(filtered_degree, targets, weights)
    deg_log = np.log1p(filtered_degree)
    if deg_log.max() > deg_log.min():
        deg_norm = (deg_log - deg_log.min()) / (deg_log.max() - deg_log.min())
    else:
        deg_norm = np.zeros_like(deg_log)

    nodes: list[dict] = []
    for new_idx, old_idx in enumerate(selected_indices.tolist()):
        is_focus = old_idx in focus_indices
        size = 0.012 + 0.03 * float(deg_norm[new_idx])
        color = [1.0, 0.25, 0.2] if is_focus else color_gradient(float(deg_norm[new_idx]))
        x, y, z = coords[new_idx].tolist()
        nodes.append(
            {
                "source_index": int(new_idx),
                "connectome_index": int(old_idx),
                "flywire_id": int(flywire_ids[old_idx]),
                "x": round(float(x), 6),
                "y": round(float(y), 6),
                "z": round(float(z), 6),
                "size": round(float(size), 6),
                "color": color,
                "is_focus": bool(is_focus),
                "degree": round(float(filtered_degree[new_idx]), 6),
            }
        )

    edge_weight = np.log1p(weights)
    if edge_weight.max() > edge_weight.min():
        edge_norm = (edge_weight - edge_weight.min()) / (edge_weight.max() - edge_weight.min())
    else:
        edge_norm = np.zeros_like(edge_weight)

    edges = [
        {
            "source": int(s),
            "target": int(t),
            "weight": round(float(w), 6),
            "strength": round(float(n), 6),
        }
        for s, t, w, n in zip(sources.tolist(), targets.tolist(), weights.tolist(), edge_norm.tolist())
    ]

    return {
        "meta": {
            "generator": "export_fly_brain_json.py",
            "layout": "spectral_with_spherical_fallback",
            "node_count": len(nodes),
            "edge_count": len(edges),
            "source_completeness": str(source_paths.completeness),
            "source_connectivity": str(source_paths.connectivity),
            "notes": (
                "Abstract graph layout derived from connectivity; not an anatomical "
                "mesh. The full fly body is procedural."
            ),
        },
        "nodes": nodes,
        "edges": edges,
    }


def main() -> int:
    args = parse_args()
    paths = resolve_paths(args)

    for file_path in (paths.completeness, paths.connectivity):
        if not file_path.exists():
            print(f"[error] Missing input file: {file_path}", file=sys.stderr)
            return 1

    if args.max_nodes < 2:
        print("[error] --max-nodes must be at least 2.", file=sys.stderr)
        return 1
    if args.max_edges < 1:
        print("[error] --max-edges must be at least 1.", file=sys.stderr)
        return 1

    focus_ids = read_focus_ids(args.focus_ids_file)

    print(f"[info] Reading completeness file: {paths.completeness}")
    completeness = pd.read_csv(paths.completeness, index_col=0)
    flywire_ids = completeness.index.to_numpy(dtype=np.int64, copy=False)

    print(f"[info] Reading connectivity file: {paths.connectivity}")
    conn = pd.read_parquet(paths.connectivity, columns=[PRESYN_COL, POSTSYN_COL, WEIGHT_COL])
    ensure_columns(conn)

    print("[info] Computing weighted degree ranking...")
    degree = weighted_degree_from_edges(conn)

    selected_indices, focus_indices = pick_nodes(
        degree=degree,
        flywire_ids=flywire_ids,
        max_nodes=args.max_nodes,
        focus_ids=focus_ids,
    )

    print(
        f"[info] Selected {len(selected_indices):,} nodes "
        f"({len(focus_indices):,} focus nodes matched)."
    )

    export_payload = build_export(
        conn=conn,
        flywire_ids=flywire_ids,
        selected_indices=selected_indices,
        focus_indices=focus_indices,
        max_edges=args.max_edges,
        seed=args.seed,
        source_paths=paths,
    )

    paths.output.parent.mkdir(parents=True, exist_ok=True)
    with paths.output.open("w", encoding="utf-8") as handle:
        json.dump(export_payload, handle, separators=(",", ":"))

    print(f"[ok] Wrote {paths.output}")
    print(
        "[tip] Bundle the output as flybrain_for_vision_pro.json to override the whole-fly fallback graph."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
