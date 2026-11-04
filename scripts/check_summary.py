#!/usr/bin/env python3
"""Recompute the v2 metrics of results/v2_phase1_summary.json from the shipped
graphs (results/<app>/exp_a*_n8_v2.json), with the same function that wrote
them (run_v2_phase1.metrics_from_exp), and compare.

The commercial subject px4 (Pyx4) ships no graph: its rows carry only the
aggregate numbers the paper prints, so they are reported and not recomputed.
Exit status 1 on any mismatch."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from run_v2_phase1 import metrics_from_exp  # noqa: E402

rows = json.loads((ROOT / "results" / "v2_phase1_summary.json").read_text())
bad = checked = 0
for r in rows:
    app, a = r["app"], r["alpha"]
    p = ROOT / "results" / app / f"exp_a{a}_b{round(1 - a, 1)}_n8_v2.json"
    if not p.is_file():
        print(f"  not recomputed  {app} a={a} (no shipped graph)")
        continue
    m = metrics_from_exp(p)
    checked += 1
    if m != r["v2"]:
        bad += 1
        print(f"  MISMATCH        {app} a={a}: " + ", ".join(k for k in m if m[k] != r["v2"].get(k)))
print(f"check_summary: {checked} rows recomputed, {bad} mismatches")
sys.exit(1 if bad else 0)
