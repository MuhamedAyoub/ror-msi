#!/usr/bin/env python3
"""
evaluate.py — Compute standard M2M decomposition evaluation metrics.

Implements the metrics from:
  Weerasinghe et al., "From Monolith to Microservices: A Comparative
  Evaluation of Decomposition Frameworks", arXiv:2601.23141v1 (2026).

Metrics computed:
  - SM  (Structural Modularity)     — Eq. 1, higher is better
  - IFN (Interface Number)          — Eq. 2, lower is better
  - ICP (Inter-partition Communication) — Eq. 3, lower is better
  - NED (Non-Extreme Distribution)  — Eq. 4, lower is better
  - Score(T) composite              — Eq. 5, higher is better

Usage:
  python3 evaluate.py <experiment_result.json>
  python3 evaluate.py --json <experiment_result.json>   # machine-readable output
"""

import json
import sys
import math
from collections import defaultdict


def load_experiment(path):
    with open(path) as f:
        return json.load(f)


def compute_sm(partitions, graph):
    """
    Structural Modularity (SM) — Eq. 1 in Weerasinghe et al.

    SM = (1/M) * sum_i(scoh_i) - (1/((M*(M-1))/2)) * sum_{i!=j}(scop_{i,j})

    where:
      scoh_i = mu_i / m_i^2
        mu_i = number of intra-partition calls in partition i
        m_i  = number of classes in partition i
      scop_{i,j} = gamma_{i,j} / (2 * m_i * m_j)
        gamma_{i,j} = number of calls between partitions i and j
    """
    M = len(partitions)
    if M == 0:
        return 0.0

    # Build class-to-partition mapping
    class_to_partition = {}
    for idx, partition in enumerate(partitions):
        for cls in partition:
            class_to_partition[cls] = idx

    # Compute scoh_i for each partition
    scoh = []
    for idx, partition in enumerate(partitions):
        m_i = len(partition)
        mu_i = 0  # intra-partition calls
        for cls in partition:
            if cls in graph:
                for target, count in graph[cls].items():
                    if target in class_to_partition and class_to_partition[target] == idx and target != cls:
                        mu_i += count
        scoh_val = mu_i / (m_i ** 2) if m_i > 0 else 0.0
        scoh.append(scoh_val)

    # Compute scop_{i,j} for each pair
    # gamma_{i,j} = calls from partition i to partition j + calls from j to i
    gamma = defaultdict(int)
    for cls, deps in graph.items():
        if cls not in class_to_partition:
            continue
        src_part = class_to_partition[cls]
        for target, count in deps.items():
            if target not in class_to_partition:
                continue
            tgt_part = class_to_partition[target]
            if src_part != tgt_part:
                key = (min(src_part, tgt_part), max(src_part, tgt_part))
                gamma[key] += count

    scop_sum = 0.0
    for (i, j), gamma_ij in gamma.items():
        m_i = len(partitions[i])
        m_j = len(partitions[j])
        scop_ij = gamma_ij / (2 * m_i * m_j) if (m_i > 0 and m_j > 0) else 0.0
        scop_sum += scop_ij

    avg_scoh = sum(scoh) / M
    denom_scop = (M * (M - 1)) / 2 if M > 1 else 1.0
    sm = avg_scoh - scop_sum / denom_scop

    return sm


def compute_ifn(partitions, graph):
    """
    Interface Number (IFN) — Eq. 2 in Weerasinghe et al.

    IFN = (1/N) * sum_i(ifn_i)

    ifn_i = number of interfaces (classes called from outside) in microservice i.
    A class is an interface of partition i if it is called by any class in another partition.
    """
    N = len(partitions)
    if N == 0:
        return 0.0

    class_to_partition = {}
    for idx, partition in enumerate(partitions):
        for cls in partition:
            class_to_partition[cls] = idx

    ifn_per_partition = []
    for idx, partition in enumerate(partitions):
        interfaces = set()
        partition_set = set(partition)
        # A class in this partition is an interface if called from outside
        for cls, deps in graph.items():
            if cls not in class_to_partition:
                continue
            src_part = class_to_partition[cls]
            if src_part == idx:
                continue  # same partition
            for target, count in deps.items():
                if target in partition_set and count > 0:
                    interfaces.add(target)
        ifn_per_partition.append(len(interfaces))

    return sum(ifn_per_partition) / N


def compute_icp(partitions, graph):
    """
    Inter-partition Communication (ICP) — Eq. 3 in Weerasinghe et al.

    ICP_{i,j} = c_{i,j} / sum_all_cross_partition_calls

    We return the total ICP as the ratio of cross-partition calls to total calls.
    This represents the overall inter-partition communication overhead.
    """
    class_to_partition = {}
    for idx, partition in enumerate(partitions):
        for cls in partition:
            class_to_partition[cls] = idx

    total_cross = 0
    total_all = 0
    for cls, deps in graph.items():
        if cls not in class_to_partition:
            continue
        src_part = class_to_partition[cls]
        for target, count in deps.items():
            if target not in class_to_partition:
                continue
            if target == cls:
                continue  # skip self-calls
            total_all += count
            if class_to_partition[target] != src_part:
                total_cross += count

    return total_cross / total_all if total_all > 0 else 0.0


def compute_ned(partitions, min_size=5, max_size=20):
    """
    Non-Extreme Distribution (NED) — Eq. 4 in Weerasinghe et al.

    NED = 1 - (sum_k(n_k) / |N|)

    where N = total number of microservices,
    n_k = 1 if microservice k is "non-extreme" (min_size <= |k| <= max_size), else 0.

    Lower NED = more balanced. NED=0 means all services are in [5,20] range.
    """
    N = len(partitions)
    if N == 0:
        return 1.0

    non_extreme_count = sum(
        1 for p in partitions
        if min_size <= len(p) <= max_size
    )

    return 1.0 - non_extreme_count / N


def compute_composite_score(sm, ifn, icp, ned, num_ms):
    """LEGACY single-tool Score (kept for backward compat with old reports).

    Use `compute_weerasinghe_scores` for the benchmark-aligned Eq. 5 Score.
    """
    ifn_norm = ifn / num_ms if num_ms > 0 else 0.0
    score = (3 * sm - ifn_norm - icp - ned) / 6
    return score


def compute_weerasinghe_scores(metrics_by_tool):
    """Eq. 5 Score from Weerasinghe et al. 2026.

      Score(T) = sum_m w_m * z(x_{m,T}) / sum_m |w_m|
      W = {SM:+3, IFN:-1, ICP:-1, NED:-1},  sum |w| = 6

    z is computed across ALL TOOLS on the SAME BENCHMARK. That is, for one
    app, we standardize each metric column over the tools, then take the
    weighted z-sum per tool.

    Args:
      metrics_by_tool: {tool_name: {"SM": float, "IFN": float, "ICP": float,
                                    "NED": float}}
    Returns:
      {tool_name: score_float}    (NaN if std == 0 across tools)
    """
    import math
    if not metrics_by_tool:
        return {}
    tools = list(metrics_by_tool.keys())
    weights = {"SM": 3.0, "IFN": -1.0, "ICP": -1.0, "NED": -1.0}
    sum_abs_w = sum(abs(w) for w in weights.values())  # 6.0

    def col(metric):
        return [metrics_by_tool[t].get(metric, float("nan")) for t in tools]

    means = {}
    stds = {}
    for m in weights:
        vals = [v for v in col(m) if v is not None and not (isinstance(v, float) and math.isnan(v))]
        if not vals:
            means[m] = float("nan"); stds[m] = float("nan"); continue
        mu = sum(vals) / len(vals)
        var = sum((v - mu) ** 2 for v in vals) / len(vals)
        means[m] = mu
        stds[m] = math.sqrt(var)

    out = {}
    for t in tools:
        score = 0.0
        valid = True
        for m, w in weights.items():
            x = metrics_by_tool[t].get(m, float("nan"))
            sigma = stds[m]
            if sigma is None or sigma == 0 or math.isnan(sigma) or math.isnan(x):
                valid = False
                break
            z = (x - means[m]) / sigma
            score += w * z
        out[t] = (score / sum_abs_w) if valid else float("nan")
    return out


def evaluate(experiment_data):
    """Compute all metrics from experiment JSON data."""
    graph = experiment_data["dependency_graph"]
    clusters = experiment_data["clusters"]

    # Extract partition class lists
    partitions = [c["classes"] for c in clusters]

    # Compute all metrics
    sm = compute_sm(partitions, graph)
    ifn = compute_ifn(partitions, graph)
    icp = compute_icp(partitions, graph)
    ned = compute_ned(partitions)

    # Composite score (with IFN normalized to [0,1])
    num_ms = len(partitions)
    score = compute_composite_score(sm, ifn, icp, ned, num_ms)

    return {
        "SM": round(sm, 4),
        "IFN": round(ifn, 4),
        "ICP": round(icp, 4),
        "NED": round(ned, 4),
        "Score": round(score, 4),
        "num_microservices": len(partitions),
        "num_classes_assigned": sum(len(p) for p in partitions),
        "partition_sizes": [len(p) for p in partitions],
        "parameters": experiment_data.get("parameters", {})
    }


def evaluate_from_file(path):
    data = load_experiment(path)
    return evaluate(data)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    json_mode = "--json" in sys.argv
    path = [a for a in sys.argv[1:] if a != "--json"][0]

    result = evaluate_from_file(path)

    if json_mode:
        print(json.dumps(result, indent=2))
    else:
        params = result["parameters"]
        mode = params.get("mode", "unknown")
        alpha = params.get("alpha", "?")
        beta = params.get("beta", "?")

        print(f"\n{'='*60}")
        print(f" Microservice Decomposition Evaluation")
        print(f" Mode: {mode} | alpha={alpha}, beta={beta}")
        print(f"{'='*60}")
        print(f" Microservices:  {result['num_microservices']}")
        print(f" Classes assigned: {result['num_classes_assigned']}")
        print(f" Partition sizes: {result['partition_sizes']}")
        print(f"{'─'*60}")
        print(f" SM  (Structural Modularity)  = {result['SM']:>8.4f}  (↑ better)")
        print(f" IFN (Interface Number)       = {result['IFN']:>8.4f}  (↓ better)")
        print(f" ICP (Inter-partition Comm.)  = {result['ICP']:>8.4f}  (↓ better)")
        print(f" NED (Non-Extreme Distrib.)   = {result['NED']:>8.4f}  (↓ better)")
        print(f"{'─'*60}")
        print(f" Composite Score              = {result['Score']:>8.4f}  (↑ better)")
        print(f"{'='*60}\n")
