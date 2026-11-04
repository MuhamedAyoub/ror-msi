#!/usr/bin/env python3
"""run_v2_phase1.py — Phase-1 benchmark on the v2 resolver pipe.

For each app and alpha in the published sweep, runs experiment_v2.rb
(tools/v2 layered resolver), scores the decomposition with the SAME
evaluate.py metric functions used for the published Table II, and writes
an old-vs-new comparison:

  results/{app}/exp_a{a}_b{b}_n8_v2.json      raw v2 experiment output
  results/v2_phase1_summary.json               all rows, both pipes
  results/v2_phase1_summary.md                 side-by-side tables

The published v1 numbers are re-read from results/{app}/exp_a*_rails_aware.json
(not re-run) so the baseline is exactly the artifact behind the paper.
"""
from __future__ import annotations
import json
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO))
from evaluate import (  # noqa: E402
    compute_sm, compute_ifn, compute_icp, compute_ned, compute_composite_score,
)

APPS = [
    ("astuto-main",      "datasets/astuto-main/app"),
    ("huginn-master",    "datasets/huginn-master/app"),
    ("px4",              "datasets/px4/app"),
    ("feedbin-main",     "datasets/feedbin-main/app"),
    ("chatwoot-develop", "datasets/chatwoot-develop/app"),
    ("mastodon-main",    "datasets/mastodon-main/app"),
    ("discourse",        "datasets/discourse/app"),
    ("canvas-lms",       "datasets/canvas-lms/app"),
]
ALPHAS = [0.2, 0.5, 0.8, 0.9]


def metrics_from_exp(path: Path) -> dict | None:
    if not path.is_file():
        return None
    d = json.loads(path.read_text())
    parts = [c["classes"] for c in d.get("clusters", []) if c.get("classes")]
    graph = d.get("dependency_graph", {})
    if not parts:
        return None
    sm = compute_sm(parts, graph)
    ifn = compute_ifn(parts, graph)
    icp = compute_icp(parts, graph)
    ned = compute_ned(parts)
    n_ms = len(parts)
    return {
        "SM": round(sm, 4), "IFN": round(ifn, 4),
        "ICP": round(icp, 4), "NED": round(ned, 4),
        "Score": round(compute_composite_score(sm, ifn, icp, ned, n_ms), 4),
        "num_ms": n_ms,
        "num_classes": sum(len(p) for p in parts),
        "resolver_report": d.get("resolver_report"),
    }


def run_v2(app_root: str, alpha: float, out: Path) -> bool:
    beta = round(1 - alpha, 1)
    cmd = ["ruby", str(REPO / "experiment_v2.rb"), str(alpha), str(beta), "8",
           "./input/classes", "./input/data", str(out), "3", "0.1",
           "--rails-aware", str(REPO / app_root)]
    t0 = time.time()
    proc = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                          timeout=3600)
    dt = time.time() - t0
    ok = proc.returncode == 0 and out.is_file()
    tag = "ok" if ok else "FAILED"
    print(f"    v2 a={alpha}: {tag} in {dt:.0f}s", flush=True)
    if not ok:
        print("      " + (proc.stderr or "")[-400:].replace("\n", "\n      "))
    return ok


def main() -> None:
    only = sys.argv[1:] or None
    rows = []
    for app, app_root in APPS:
        if only and app not in only:
            continue
        print(f"[{app}]", flush=True)
        for alpha in ALPHAS:
            beta = round(1 - alpha, 1)
            v1_path = REPO / f"results/{app}/exp_a{alpha}_b{beta}_n8_rails_aware.json"
            v2_path = REPO / f"results/{app}/exp_a{alpha}_b{beta}_n8_v2.json"
            if not v2_path.is_file():
                if not run_v2(app_root, alpha, v2_path):
                    continue
            m1 = metrics_from_exp(v1_path)
            m2 = metrics_from_exp(v2_path)
            rows.append({"app": app, "alpha": alpha, "v1": m1, "v2": m2})
            if m1 and m2:
                print(f"    a={alpha}: SM {m1['SM']:.3f}->{m2['SM']:.3f}  "
                      f"ICP {m1['ICP']:.3f}->{m2['ICP']:.3f}  "
                      f"Score {m1['Score']:+.3f}->{m2['Score']:+.3f}", flush=True)

    (REPO / "results/v2_phase1_summary.json").write_text(json.dumps(rows, indent=2))

    md = ["# Phase-1: v1 (name+arity) vs v2 (layered resolver)\n",
          "Same clustering engine, same metric code (evaluate.py); only the graph differs.\n"]
    for app, _ in APPS:
        app_rows = [r for r in rows if r["app"] == app]
        if not app_rows:
            continue
        md.append(f"\n## {app}\n")
        md.append("| α | pipe | #MS | SM↑ | IFN↓ | ICP↓ | NED↓ | Score↑ |")
        md.append("|---|------|-----|-----|------|------|------|--------|")
        for r in app_rows:
            for tag in ("v1", "v2"):
                m = r[tag]
                if not m:
                    md.append(f"| {r['alpha']} | {tag} | - | - | - | - | - | missing |")
                    continue
                md.append(f"| {r['alpha']} | {tag} | {m['num_ms']} | {m['SM']:.3f} | "
                          f"{m['IFN']:.2f} | {m['ICP']:.3f} | {m['NED']:.2f} | "
                          f"{m['Score']:+.3f} |")
    (REPO / "results/v2_phase1_summary.md").write_text("\n".join(md))
    print("\nWrote results/v2_phase1_summary.{json,md}")


if __name__ == "__main__":
    main()
