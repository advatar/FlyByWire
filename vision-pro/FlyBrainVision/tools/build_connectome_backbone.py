#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path

import networkx as nx
import numpy as np
import pandas as pd


@dataclass
class BackboneMetadata:
    source_node_count: int
    source_edge_count: int
    selected_node_count: int
    selected_edge_count: int
    reduced_edge_count: int
    selection_rule: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a compact graph backbone from the FlyWire connectome."
    )
    parser.add_argument(
        "--connectivity",
        type=Path,
        default=Path("../../data/2025_Connectivity_783.parquet"),
        help="Path to the connectivity parquet file.",
    )
    parser.add_argument(
        "--completeness",
        type=Path,
        default=Path("../../data/2025_Completeness_783.csv"),
        help="Path to the completeness CSV file.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("FlyBrainVision/Resources/ConnectivityBackbone.json"),
        help="Output JSON asset path.",
    )
    parser.add_argument(
        "--node-limit",
        type=int,
        default=600,
        help="Number of high-degree neurons to keep in the backbone.",
    )
    parser.add_argument(
        "--top-outgoing",
        type=int,
        default=8,
        help="Maximum number of strongest outgoing synapses to keep per selected neuron.",
    )
    parser.add_argument(
        "--layout-iterations",
        type=int,
        default=250,
        help="Iterations for the spring layout pass.",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for deterministic layout.",
    )
    return parser.parse_args()


def build_backbone(
    connectivity_path: Path,
    completeness_path: Path,
    output_path: Path,
    node_limit: int,
    top_outgoing: int,
    layout_iterations: int,
    seed: int,
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)

    neuron_ids = pd.read_csv(completeness_path)["Unnamed: 0"].astype(str).to_numpy()
    connectivity = pd.read_parquet(
        connectivity_path,
        columns=["Presynaptic_Index", "Postsynaptic_Index", "Excitatory x Connectivity"],
    )

    presyn = connectivity["Presynaptic_Index"].to_numpy(dtype=np.int32)
    postsyn = connectivity["Postsynaptic_Index"].to_numpy(dtype=np.int32)
    signed_weight = connectivity["Excitatory x Connectivity"].to_numpy(dtype=np.float32)
    abs_weight = np.abs(signed_weight)

    node_count = len(neuron_ids)
    source_edge_count = int(len(connectivity))

    weighted_degree = (
        np.bincount(presyn, weights=abs_weight, minlength=node_count)
        + np.bincount(postsyn, weights=abs_weight, minlength=node_count)
    )
    signed_balance = (
        np.bincount(presyn, weights=signed_weight, minlength=node_count)
        + np.bincount(postsyn, weights=signed_weight, minlength=node_count)
    )

    selected_nodes = np.argpartition(weighted_degree, -node_limit)[-node_limit:]
    selected_nodes = selected_nodes[np.argsort(weighted_degree[selected_nodes])[::-1]]

    selected_mask = np.zeros(node_count, dtype=np.bool_)
    selected_mask[selected_nodes] = True

    induced_mask = selected_mask[presyn] & selected_mask[postsyn] & (presyn != postsyn)
    induced_pre = presyn[induced_mask]
    induced_post = postsyn[induced_mask]
    induced_weight = signed_weight[induced_mask]

    keep_mask = np.zeros(induced_pre.shape[0], dtype=np.bool_)
    for node in selected_nodes:
        outgoing_idx = np.flatnonzero(induced_pre == node)
        if outgoing_idx.size == 0:
            continue
        strongest_idx = outgoing_idx[np.argsort(np.abs(induced_weight[outgoing_idx]))[::-1][:top_outgoing]]
        keep_mask[strongest_idx] = True

    reduced_pre = induced_pre[keep_mask]
    reduced_post = induced_post[keep_mask]
    reduced_weight = induced_weight[keep_mask]

    graph = nx.Graph()
    for src, dst, weight in zip(
        reduced_pre.tolist(), reduced_post.tolist(), np.abs(reduced_weight).tolist()
    ):
        if graph.has_edge(src, dst):
            graph[src][dst]["weight"] += weight
        else:
            graph.add_edge(src, dst, weight=weight)

    positions = nx.spring_layout(
        graph,
        dim=3,
        iterations=layout_iterations,
        seed=seed,
        weight="weight",
        scale=1.0,
    )

    ordered_nodes = np.array(sorted(graph.nodes()), dtype=np.int32)
    node_lookup = {int(node): idx for idx, node in enumerate(ordered_nodes)}
    coords = np.array([positions[int(node)] for node in ordered_nodes], dtype=np.float32)

    coords -= coords.mean(axis=0, keepdims=True)
    scale = float(np.abs(coords).max())
    if scale > 0:
        coords /= scale

    node_degree = weighted_degree[ordered_nodes]
    degree_min = float(node_degree.min())
    degree_max = float(node_degree.max())

    nodes = []
    for local_index, node in enumerate(ordered_nodes.tolist()):
        degree_value = float(weighted_degree[node])
        balance_value = float(signed_balance[node] / max(weighted_degree[node], 1.0))
        normalized_degree = (
            0.0
            if degree_max == degree_min
            else (degree_value - degree_min) / (degree_max - degree_min)
        )
        nodes.append(
            {
                "rootID": neuron_ids[node],
                "sourceIndex": int(node),
                "degree": round(degree_value, 3),
                "degreeNorm": round(float(normalized_degree), 6),
                "balance": round(balance_value, 6),
                "position": [round(float(value), 6) for value in coords[local_index].tolist()],
            }
        )

    edges = [
        {
            "source": node_lookup[int(src)],
            "target": node_lookup[int(dst)],
            "weight": round(float(weight), 3),
            "sign": 1 if weight > 0 else -1,
        }
        for src, dst, weight in zip(
            reduced_pre.tolist(), reduced_post.tolist(), reduced_weight.tolist()
        )
    ]

    metadata = BackboneMetadata(
        source_node_count=node_count,
        source_edge_count=source_edge_count,
        selected_node_count=node_limit,
        selected_edge_count=int(induced_pre.shape[0]),
        reduced_edge_count=len(edges),
        selection_rule=(
            f"Top {node_limit} neurons by weighted degree with the strongest "
            f"{top_outgoing} outgoing synapses kept per selected neuron."
        ),
    )

    payload = {
        "metadata": asdict(metadata),
        "nodes": nodes,
        "edges": edges,
    }

    output_path.write_text(json.dumps(payload, separators=(",", ":")))
    print(f"Wrote {len(nodes)} nodes and {len(edges)} directed edges to {output_path}")


def main() -> None:
    args = parse_args()
    build_backbone(
        connectivity_path=args.connectivity,
        completeness_path=args.completeness,
        output_path=args.output,
        node_limit=args.node_limit,
        top_outgoing=args.top_outgoing,
        layout_iterations=args.layout_iterations,
        seed=args.seed,
    )


if __name__ == "__main__":
    main()
