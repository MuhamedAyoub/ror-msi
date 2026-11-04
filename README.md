# RoR-MSI: replication package

This is the replication package of the paper *Conventions as Types* (ICSA 2027 submission).
It contains RoR-MSI's static call resolver for Ruby on Rails and its dual-objective
clustering, together with the results on the eight Rails applications of the paper:

- `experiment_v2.rb` builds the dependency graph and clusters it.
- `tools/v2/` holds the resolver: the layered cascade L0 to L4
  (`ResolverV2.rb`), the convention oracle (`ConventionOracleV2.rb`), the
  inflector, AST facts and graph builder.
- `tools/*.rb` holds the clustering engine.
- `evaluate.py` holds the metrics: SM, IFN, ICP, NED and the composite Score.
- `run_v2_phase1.py` runs the sweep over α ∈ {0.2, 0.5, 0.8, 0.9} and writes
  `results/v2_phase1_summary.json`.
- `scripts/regen_tables_figs.py` builds every table and figure of the paper
  from that summary.

## Requirements

- Ruby ≥ 3.0 with the `parser` gem (`bundle install`, see `Gemfile`; tested with Ruby 3.2.3 and parser 3.3.11.1).
- Python ≥ 3.10 with `pip install -r requirements.txt` (matplotlib 3.10.7, for the figures only).

## Subjects

`bash scripts/fetch_subjects.sh` clones the seven open-source subjects into `datasets/`, at the commits below.

The paper gives a snapshot date for each subject, and the Canvas commit. For
the other six, the commit is the last commit on the default branch on or
before the snapshot date. These six were resolved after the analysis, not
recorded at analysis time. Sampled model files of the analysed copies are
byte-identical to them.

Pyx4 is a commercial platform and cannot be redistributed. Its graph and
outputs are not included. Its rows in `results/v2_phase1_summary.json` keep
only the aggregate numbers the paper prints: the metrics, and the resolver
counts behind `tab:layers` and the polymorphic totals.

| subject | repository | snapshot | commit |
|---|---|---|---|
| Astuto | https://github.com/riggraz/astuto | 2026-01-09 | `ac6ad92f7ec3f2961c37f17fb090c1fe4184f194` |
| Huginn | https://github.com/huginn/huginn | 2026-04-05 | `7869e400a7c6025b12206a164ce44e824f077e22` |
| Feedbin | https://github.com/feedbin/feedbin | 2026-03-16 | `3706c52c924c7c3d287149f4452d09507d02b331` |
| Chatwoot | https://github.com/chatwoot/chatwoot | 2026-04-02 | `6f5ad8f3724b68fec3780b22047c539c06520fb2` |
| Mastodon | https://github.com/mastodon/mastodon | 2026-04-03 | `8fa91b4b81951f884a773d0aa56fc4f1a48da03e` |
| Discourse | https://github.com/discourse/discourse | 2026-06-04 | `2a3f79b3ebe4bb939d86e728b564863fb6f0a1cd` |
| Canvas | https://github.com/instructure/canvas-lms | 2026-06-06 | `1c9f0bb8013ed69c4f2efe11fd483025469b7e6c` |

## Reproduction

**Level 1, from the shipped results (seconds, no subjects):**

    bash scripts/reproduce.sh

This recomputes every metric from the shipped graphs
(`results/<app>/exp_a*_n8_v2.json`) and compares it with the summary. It
then regenerates the table fragments and both figures into `build/`, and
compares each fragment with the rows of the paper (`results/paper_tables/`).

**Level 2, from the subject sources:**

    bash scripts/fetch_subjects.sh
    bash scripts/rerun_from_source.sh                 # or name one subject, e.g. astuto-main

This reruns `experiment_v2.rb` for every α on a temporary copy, then compares
the metrics with the shipped summary. Canvas, the largest subject, took
about 35 min per α (from the output timestamps).

**Tests:** `ruby tools/v2/test_v2.rb` runs the resolver fixture tests (26 checks).

## Where each table and figure comes from

| paper | produced by | data |
|---|---|---|
| `tab:subjects` | `scripts/regen_tables_figs.py` → `tab_subjects.tex` | classes and call sites from `results/v2_phase1_summary.json` |
| `tab:layers` (resolution provenance) | `regen_tables_figs.py` → `tab_layers.tex` | `resolver_report` in the summary |
| `tab:sweep` | `regen_tables_figs.py` → `tab_sweep.tex` | summary, key `v2` |
| `tab:best` | `regen_tables_figs.py` → `tab_best.tex` | summary |
| `tab:context` | `scripts/check_tables.py` rebuilds the RoR-MSI rows from `tab:best`; the Java rows are copied from Weerasinghe et al. | summary |
| `fig:metric-comparison` | `regen_tables_figs.py` → `assets/metric_comparison_v5.pdf` | summary |
| `fig:sensitivity` | `regen_tables_figs.py` → `assets/alpha_sensitivity_v5.pdf` | summary |
| `tab:rules`, `tab:frameworks`, `fig:cascade`, `fig:example`, `fig:pipeline` | text and diagrams, no data | none |

Each subject's graph and clustering is in `results/<app>/exp_a<α>_b<β>_n8_v2.json`,
which holds the parameters, the dependency graph, the data associations, the
clusters, the per-cluster metrics, the isolated classes and the resolver
report.

The paper prints its figures in greyscale (`*_bw.pdf`). The script draws the
same data in colour.

## License

MIT (`LICENSE`).
