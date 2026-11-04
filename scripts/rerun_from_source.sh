#!/usr/bin/env bash
# Level 2: rerun the resolver and the clustering from the subject sources
# (scripts/fetch_subjects.sh first) and compare the metrics with the shipped
# summary. Runs on a temporary copy, so results/ is not overwritten.
#   bash scripts/rerun_from_source.sh                  # every fetched subject
#   bash scripts/rerun_from_source.sh astuto-main      # one
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"
W="$(mktemp -d "${TMPDIR:-/tmp}/ror-msi-rerun.XXXXXX")"
trap 'rm -rf "$W"' EXIT
(cd "$REPO" && tar cf - --exclude=./.git --exclude=./datasets --exclude=./build .) | (cd "$W" && tar xf -)
ln -s "$REPO/datasets" "$W/datasets"
cd "$W"
APPS=("$@"); [[ ${#APPS[@]} -gt 0 ]] || APPS=($(ls "$REPO/datasets"))
for a in "${APPS[@]}"; do rm -f "results/$a"/exp_a*_n8_v2.json; done
PYTHONDONTWRITEBYTECODE=1 "$PY" run_v2_phase1.py "${APPS[@]}"
PYTHONDONTWRITEBYTECODE=1 "$PY" - "$REPO/results/v2_phase1_summary.json" results/v2_phase1_summary.json <<'PYEOF'
import json, sys
ref = {(r["app"], r["alpha"]): r["v2"] for r in json.load(open(sys.argv[1]))}
new = json.load(open(sys.argv[2])); bad = 0
for r in new:
    same = r["v2"] == ref[(r["app"], r["alpha"])]
    bad += not same
    print(f"  {'same    ' if same else 'DIFFERS '} {r['app']} a={r['alpha']}")
print("rerun: " + ("every rerun configuration equals the shipped summary" if not bad else f"{bad} configurations differ"))
sys.exit(1 if bad else 0)
PYEOF
