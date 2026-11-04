#!/usr/bin/env python3
"""Regenerate every table and figure in icsa2027.tex from the v2 run.

Source of truth:
  results/v2_phase1_summary.json
    - per-app, per-alpha SM/IFN/ICP/NED/Score and class counts (the "v2" key)
    - the per-app resolver_report embedded in each v2 record, which is what
      Table III (resolution provenance) is computed from.

Figures are written to assets/*_v5.pdf. Table fragments are written as
tab_*.tex; their contents are pasted into icsa2027.tex, so re-running this
script and diffing the fragments checks the paper against the data.
"""
import json, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

import os, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SRC = str(ROOT / "results" / "v2_phase1_summary.json")
# outputs (assets/*.pdf and tab_*.tex) go to the folder given as the first argument, default build/
OUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "build"
(OUT / "assets").mkdir(parents=True, exist_ok=True)
os.chdir(OUT)
rows = json.load(open(SRC))
by = {(r["app"], r["alpha"]): r["v2"] for r in rows}
APPS = [("astuto-main","Astuto"),("huginn-master","Huginn"),("px4","Pyx4"),
        ("feedbin-main","Feedbin"),("chatwoot-develop","Chatwoot"),
        ("mastodon-main","Mastodon"),("discourse","Discourse"),("canvas-lms","Canvas")]
ALPHAS = [0.2, 0.5, 0.8, 0.9]

# Okabe-Ito, colourblind-safe and legible in greyscale print
PAL = ["#0072B2","#E69F00","#009E73","#CC79A7","#56B4E9","#D55E00","#F0E442","#000000"]
plt.rcParams.update({"font.size": 8, "axes.grid": True, "grid.alpha": .25,
                     "grid.linewidth": .5, "axes.spines.top": False,
                     "axes.spines.right": False, "figure.dpi": 200})

best = {}
for a, disp in APPS:
    best[disp] = max((by[(a, al)] for al in ALPHAS), key=lambda m: m["Score"])

# ---- Fig 1: best configuration per application -------------------------
fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(3.4, 3.6), sharex=True,
                               gridspec_kw={"height_ratios": [2, 1.15]})
names = [d for _, d in APPS]
x = range(len(names))
w = 0.26
for i, (k, lab, col) in enumerate([("SM", "SM $\\uparrow$", PAL[0]),
                                   ("ICP", "ICP $\\downarrow$", PAL[1]),
                                   ("NED", "NED $\\downarrow$", PAL[2])]):
    ax1.bar([v + (i - 1) * w for v in x], [best[n][k] for n in names],
            width=w, label=lab, color=col, edgecolor="white", linewidth=.4)
ax1.set_ylabel("metric value")
ax1.set_ylim(0, 0.78)
ax1.legend(ncol=3, frameon=False, loc="upper center", bbox_to_anchor=(.5, 1.22),
           handlelength=1.1, columnspacing=1.0)

sc = [best[n]["Score"] for n in names]
ax2.axhline(0, color="black", linewidth=.6)
ax2.bar(x, sc, width=.55, color=[PAL[5] if v < 0 else PAL[0] for v in sc],
        edgecolor="white", linewidth=.4)
ax2.set_ylabel("Score $\\uparrow$")
ax2.set_xticks(list(x))
ax2.set_xticklabels(names, rotation=38, ha="right")
fig.tight_layout()
fig.savefig("assets/metric_comparison_v5.pdf", bbox_inches="tight")
plt.close(fig)

# ---- Fig 2: sensitivity to alpha ---------------------------------------
fig, axes = plt.subplots(1, 2, figsize=(3.4, 1.9), sharex=True)
for i, (a, disp) in enumerate(APPS):
    sm = [by[(a, al)]["SM"] for al in ALPHAS]
    sc = [by[(a, al)]["Score"] for al in ALPHAS]
    st = dict(color=PAL[i % len(PAL)], marker="o", markersize=2.4, linewidth=1.0)
    axes[0].plot(ALPHAS, sm, **st)
    axes[1].plot(ALPHAS, sc, label=disp, **st)
axes[0].set_ylabel("SM $\\uparrow$")
axes[1].set_ylabel("Score $\\uparrow$")
axes[1].axhline(0, color="black", linewidth=.5, zorder=0)
for ax in axes:
    ax.set_xlabel(r"$\alpha$")
    ax.set_xticks(ALPHAS)
fig.legend(ncol=4, frameon=False, loc="lower center", bbox_to_anchor=(.5, -.36),
           handlelength=1.1, columnspacing=.9, fontsize=6.5)
fig.tight_layout()
fig.savefig("assets/alpha_sensitivity_v5.pdf", bbox_inches="tight")
plt.close(fig)
print("figures written")
import json
R=SRC
rows=json.load(open(R))
by={(r["app"],r["alpha"]):r["v2"] for r in rows}
rep={}
for r in rows:
    if r["v2"] and r["v2"].get("resolver_report"): rep.setdefault(r["app"], r["v2"]["resolver_report"])
APPS=[("astuto-main","Astuto"),("huginn-master","Huginn"),("px4","Pyx4"),("feedbin-main","Feedbin"),
      ("chatwoot-develop","Chatwoot"),("mastodon-main","Mastodon"),("discourse","Discourse"),("canvas-lms","Canvas")]
AL=[0.2,0.5,0.8,0.9]
def sc(v): return ("$\\mathbf{%+.3f}$" % v) if False else ("$%+.3f$" % v)

# --- sweep table ---
out=[]
for a,disp in APPS:
    bestal=max(AL, key=lambda al: by[(a,al)]["Score"])
    for j,al in enumerate(AL):
        m=by[(a,al)]
        mode="DC" if m["num_ms"]==1 else "HC"
        first=disp if j==0 else ""
        cls=("%d"%m["num_classes"]).replace("1133","1{,}133") if j==0 else ""
        s="$\\mathbf{%+.3f}$"%m["Score"] if al==bestal else "$%+.3f$"%m["Score"]
        out.append(f"{first} & {mode} & {al} & {cls} & {m['num_ms']} & {m['SM']:.3f} & {m['IFN']:.2f} & {m['ICP']:.3f} & {m['NED']:.2f} & {s} \\\\")
    out.append("\\midrule" if a!="canvas-lms" else "")
open("tab_sweep.tex","w").write("\n".join(l for l in out if l!=""))

# --- best per app ---
out=[]
for a,disp in APPS:
    bestal=max(AL, key=lambda al: by[(a,al)]["Score"])
    m=by[(a,bestal)]
    cls=("%d"%m["num_classes"]).replace("1133","1{,}133")
    out.append(f"{disp} & {bestal} & {cls} & {m['num_ms']} & {m['SM']:.3f} & {m['IFN']:.2f} & {m['ICP']:.3f} & {m['NED']:.2f} & $%+.3f$ \\\\"%m["Score"])
open("tab_best.tex","w").write("\n".join(out))

# --- resolution provenance ---
SK=['noise_filtered','l0_const','l0_chain_base','l0_chain_typed','l0_internal_or_external','l1_var_typed',
    'l1_typed_no_method','l2_self_internal','l2_mixin','l2_self_unknown','l3_naming','l4_fanout_sites',
    'l4_cap_suppressed','l4_noise_suppressed','l4_no_owner']
out=[]; agg=[0]*7
for a,disp in APPS:
    d=rep[a]; S=sum(d.get(k,0) for k in SK)
    L0=d.get('l0_const',0)+d.get('l0_chain_base',0)+d.get('l0_chain_typed',0)
    L1=d.get('l1_var_typed',0); L2=d.get('l2_mixin',0); L3=d.get('l3_naming',0); L4=d.get('l4_fanout_sites',0)
    edge=L0+L1+L2+L3+L4
    refus=d.get('l1_typed_no_method',0)+d.get('l2_self_unknown',0)+d.get('l4_cap_suppressed',0)+d.get('l4_noise_suppressed',0)+d.get('l4_no_owner',0)
    p=lambda x:100.0*x/S
    ex=100.0*(edge-L4)/edge
    st=lambda n: f"{n:,}".replace(",","{,}")
    out.append(f"{disp} & {st(S)} & {p(L0):.1f} & {p(L1):.1f} & {p(L2):.1f} & {p(L3):.1f} & {p(L4):.1f} & {p(edge):.1f} & {p(refus):.1f} & {ex:.0f} \\\\")
    for i,v in enumerate([S,L0,L1,L2,L3,L4,refus]): agg[i]+=v
S=agg[0]; edge=sum(agg[1:6]); p=lambda x:100.0*x/S
out.append("\\midrule")
st=lambda n: f"{n:,}".replace(",","{,}")
out.append(f"All & {st(S)} & {p(agg[1]):.1f} & {p(agg[2]):.1f} & {p(agg[3]):.1f} & {p(agg[4]):.1f} & {p(agg[5]):.1f} & {p(edge):.1f} & {p(agg[6]):.1f} & {100.0*(edge-agg[5])/edge:.0f} \\\\")
open("tab_layers.tex","w").write("\n".join(out))

# --- subjects table ---
out=[]
# domain labels and snapshot dates as printed in Table II of the paper
snap={"Astuto":"2026-01-09","Huginn":"2026-04-05","Pyx4":"---","Feedbin":"2026-03-16","Chatwoot":"2026-04-02",
      "Mastodon":"2026-04-03","Discourse":"2026-06-04","Canvas":"2026-06-06"}
dom={"Astuto":"Feedback board","Huginn":"Automation agents","Pyx4":"Business process mgmt.",
     "Feedbin":"Feed reader","Chatwoot":"Customer engagement","Mastodon":"Federated social network",
     "Discourse":"Community discussion","Canvas":"Learning management"}
for a,disp in APPS:
    m=by[(a,0.9)]; d=rep[a]
    S=sum(d.get(k,0) for k in SK)
    cls=("%d"%m["num_classes"]).replace("1133","1{,}133")
    st=lambda n: f"{n:,}".replace(",","{,}")
    out.append(f"{disp} & {snap[disp]} & {cls} & {st(S)} & {dom[disp]} \\\\")
open("tab_subjects.tex","w").write("\n".join(out))
print(open("tab_layers.tex").read())
print("---- subjects ----"); print(open("tab_subjects.tex").read())
