#!/usr/bin/env bash
# Clone the seven open-source Rails subjects into datasets/<app>/, the layout
# run_v2_phase1.py reads (datasets/<app>/app). Pyx4 is commercial and not available.
#
#   bash scripts/fetch_subjects.sh                 # all seven (Discourse and Canvas are large)
#   bash scripts/fetch_subjects.sh astuto-main     # one, by folder name
#
# Commits. The paper gives the snapshot date of each subject (Table II) and the
# Canvas commit (Data Availability). For the other six, the commit below is
# the last commit on the default branch on or before the snapshot date
# (GitHub commits API, until=<date>T23:59:59Z), resolved after the analysis,
# not recorded at analysis time. Sampled files of the analysed copies (2 to 3
# app/models files per subject) are byte-identical to these commits; for
# Canvas the same query returns the paper's 1c9f0bb.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${SUBJECTS_DIR:-datasets}"
mkdir -p "$DEST"

# folder            repository                                    branch   snapshot    commit
SUBJECTS=(
  "astuto-main       https://github.com/riggraz/astuto              main     2026-01-09  ac6ad92f7ec3f2961c37f17fb090c1fe4184f194"
  "huginn-master     https://github.com/huginn/huginn               master   2026-04-05  7869e400a7c6025b12206a164ce44e824f077e22"
  "feedbin-main      https://github.com/feedbin/feedbin             main     2026-03-16  3706c52c924c7c3d287149f4452d09507d02b331"
  "chatwoot-develop  https://github.com/chatwoot/chatwoot           develop  2026-04-02  6f5ad8f3724b68fec3780b22047c539c06520fb2"
  "mastodon-main     https://github.com/mastodon/mastodon           main     2026-04-03  8fa91b4b81951f884a773d0aa56fc4f1a48da03e"
  "discourse         https://github.com/discourse/discourse         main     2026-06-04  2a3f79b3ebe4bb939d86e728b564863fb6f0a1cd"
  "canvas-lms        https://github.com/instructure/canvas-lms      master   2026-06-06  1c9f0bb8013ed69c4f2efe11fd483025469b7e6c"
)

for line in "${SUBJECTS[@]}"; do
  read -r dir url branch snap commit <<<"$line"
  [[ $# -gt 0 && ! " $* " =~ " $dir " ]] && continue
  if [[ ! -d "$DEST/$dir/.git" ]]; then
    echo "[fetch] $dir <- $url ($branch, snapshot $snap)"
    # a shallow fetch of the one commit keeps Discourse and Canvas small
    git init --quiet "$DEST/$dir"
    git -C "$DEST/$dir" remote add origin "$url"
  fi
  git -C "$DEST/$dir" fetch --quiet --depth 1 origin "$commit"
  git -C "$DEST/$dir" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
  [[ "$(git -C "$DEST/$dir" rev-parse HEAD)" == "$commit" ]] || { echo "[fetch] $dir: wrong commit" >&2; exit 1; }
  echo "[fetch] $dir @ ${commit:0:7} ok"
done
