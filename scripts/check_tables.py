#!/usr/bin/env python3
"""Compare the table fragments written by regen_tables_figs.py (BUILD/tab_*.tex)
with the rows of the paper's tables (results/paper_tables/tab_*.tex), ignoring
whitespace, and rebuild the RoR-MSI rows of tab:context from tab:best.
Usage: python3 scripts/check_tables.py BUILD. Exit status 1 on any difference."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build")
norm = lambda s: re.sub(r"\s+", " ", s.strip())
rows = lambda p: [norm(l) for l in p.read_text().splitlines() if "&" in l]
bad = 0
for t in ("tab_sweep", "tab_best", "tab_layers", "tab_subjects"):
    paper, gen = rows(ROOT / "results/paper_tables" / f"{t}.tex"), rows(BUILD / f"{t}.tex")
    diff = [(a, b) for a, b in zip(paper, gen) if a != b] + ([("row count", f"{len(paper)} vs {len(gen)}")] if len(paper) != len(gen) else [])
    print(f"  {t:13s} {len(paper)} rows, {'identical' if not diff else str(len(diff)) + ' differ'}")
    for a, b in diff:
        print(f"      paper: {a}\n      built: {b}")
    bad += bool(diff)
# tab:context: our rows are tab:best's SM/IFN/ICP/NED rounded to two places
best = {r.split("&")[0].strip(): [c.strip() for c in r.split("&")] for r in rows(BUILD / "tab_best.tex")}
ctx = [r for r in rows(ROOT / "results/paper_tables/tab_context.tex") if r.startswith("\\tool{}")]
for r in ctx:
    c = [x.strip().rstrip("\\").strip() for x in r.split("&")]
    b = best[c[1]]
    want = [f"{float(b[4]):.2f}", f"{float(b[5]):.2f}", f"{float(b[6]):.2f}", f"{float(b[7]):.2f}"]
    if c[2:6] != want:
        bad += 1; print(f"      context {c[1]}: paper {c[2:6]} vs tab:best {want}")
print(f"  tab_context   {len(ctx)} RoR-MSI rows checked against tab_best")
print("check_tables: " + ("every fragment equals the paper" if not bad else "DIFFERENCES above"))
sys.exit(1 if bad else 0)
