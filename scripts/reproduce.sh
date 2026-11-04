#!/usr/bin/env bash
# Level 1: every table and figure of the paper from the shipped results, on
# CPU, without the subject sources.
#   1. recompute SM, IFN, ICP, NED, Score, #MS and #Cls of every configuration
#      from the shipped graphs, and compare with results/v2_phase1_summary.json;
#   2. regenerate the table fragments and both figures from the summary
#      (scripts/regen_tables_figs.py), into build/ or $1;
#   3. compare each fragment with the paper's rows (results/paper_tables/).
# Exit status 1 on any difference.
set -uo pipefail
cd "$(dirname "$0")/.."
PY="${PYTHON:-python3}"
BUILD="${1:-build}"
export PYTHONDONTWRITEBYTECODE=1
FAIL=0
echo "[1/3] metrics from the graphs"
"$PY" scripts/check_summary.py | grep -v 'not recomputed' || FAIL=1
echo "[2/3] tables and figures -> $BUILD/"
"$PY" scripts/regen_tables_figs.py "$BUILD" > /dev/null || FAIL=1
ls "$BUILD"/tab_*.tex "$BUILD"/assets/*.pdf | sed 's/^/  /'
echo "[3/3] fragments against the paper"
"$PY" scripts/check_tables.py "$BUILD" || FAIL=1
exit $FAIL
