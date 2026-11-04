"""Rebuild the latency summary table and chart from the RAW samples.

Input : evidence/latency-samples.csv  (run_id, scenario, order_in_run, sample_no, latency_ms, status)
Output: evidence/latency-benchmark.csv  (summary per run and pooled)
        docs/latency-boxplot.png

Usage (repo root):  python scripts/plot-latency.py
Needs:              pip install matplotlib
"""
import csv
import os
import sys
from collections import defaultdict

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

SAMPLES = "evidence/latency-samples.csv"
SUMMARY = "evidence/latency-benchmark.csv"
FIGURE = "docs/latency-boxplot.png"
SCENARIOS = ["baseline", "cpu_load"]
LABELS = {"baseline": "Baseline (no load)", "cpu_load": "During CPU load"}
COLORS = {"baseline": "#4C78A8", "cpu_load": "#E8833A"}

if not os.path.exists(SAMPLES):
    sys.exit("Missing %s. Run scripts/measure-latency.ps1 first." % SAMPLES)

data = defaultdict(list)      # (run, scenario) -> [latency]
errors = defaultdict(int)
with open(SAMPLES, encoding="utf-8-sig", newline="") as f:
    for row in csv.DictReader(f):
        key = (int(row["run_id"]), row["scenario"])
        if row["status"] == "ok":
            data[key].append(float(row["latency_ms"]))
        else:
            errors[key] += 1

runs = sorted({r for r, _ in data})
if not runs:
    sys.exit("No valid samples found.")


def stats(values):
    a = np.asarray(values)
    return {
        "samples": len(a),
        "avg": a.mean(),
        "median": np.median(a),
        "p95": np.percentile(a, 95),
        "max": a.max(),
    }


rows = []
for run in runs:
    for sc in SCENARIOS:
        v = data.get((run, sc), [])
        if v:
            rows.append((str(run), sc, stats(v), errors.get((run, sc), 0)))
for sc in SCENARIOS:
    pooled = [x for r in runs for x in data.get((r, sc), [])]
    if pooled:
        rows.append(("ALL", sc, stats(pooled), sum(errors.get((r, sc), 0) for r in runs)))

with open(SUMMARY, "w", encoding="utf-8", newline="") as f:
    w = csv.writer(f)
    w.writerow(["run_id", "scenario", "target_team", "samples", "avg_latency_ms",
                "median_latency_ms", "p95_latency_ms", "max_latency_ms", "errors"])
    for run, sc, s, err in rows:
        w.writerow([run, sc, "Team B API", s["samples"], "%.2f" % s["avg"],
                    "%.2f" % s["median"], "%.2f" % s["p95"], "%.2f" % s["max"], err])

# ---- Figure ----
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5), gridspec_kw={"width_ratios": [2.2, 1]})

positions, box_data, box_colors = [], [], []
tick_pos, tick_lab = [], []
for i, run in enumerate(runs):
    base = i * 3
    for j, sc in enumerate(SCENARIOS):
        positions.append(base + j)
        box_data.append(data.get((run, sc), [np.nan]))
        box_colors.append(COLORS[sc])
    tick_pos.append(base + 0.5)
    tick_lab.append("Run %d" % run)

bp = ax1.boxplot(box_data, positions=positions, widths=0.8, patch_artist=True, showfliers=True,
                 flierprops={"marker": ".", "markersize": 3, "alpha": 0.5})
for patch, c in zip(bp["boxes"], box_colors):
    patch.set_facecolor(c)
    patch.set_alpha(0.75)
for med in bp["medians"]:
    med.set_color("black")
ax1.set_xticks(tick_pos)
ax1.set_xticklabels(tick_lab)
ax1.set_ylabel("API latency (ms)")
ax1.set_title("Latency distribution per run")
ax1.grid(axis="y", alpha=0.3)
n_per = int(np.median([len(v) for v in data.values()]))
ax1.legend([plt.Rectangle((0, 0), 1, 1, color=COLORS[s], alpha=0.75) for s in SCENARIOS],
           [LABELS[s] for s in SCENARIOS], loc="upper center",
           bbox_to_anchor=(0.5, -0.08), ncol=2, frameon=False)

means = {sc: [np.mean(data[(r, sc)]) for r in runs if (r, sc) in data] for sc in SCENARIOS}
x = np.arange(len(SCENARIOS))
heights = [np.mean(means[sc]) for sc in SCENARIOS]
err = [np.std(means[sc], ddof=1) if len(means[sc]) > 1 else 0 for sc in SCENARIOS]
ax2.bar(x, heights, yerr=err, capsize=6, color=[COLORS[s] for s in SCENARIOS], alpha=0.85)
for xi, h, e in zip(x, heights, err):
    ax2.text(xi, h + e + 0.01 * max(heights), "%.1f" % h, ha="center", va="bottom")
ax2.set_ylim(0, max(h + e for h, e in zip(heights, err)) * 1.15)
ax2.set_xticks(x)
ax2.set_xticklabels(["Baseline", "CPU load"])
ax2.set_ylabel("Mean latency (ms)")
ax2.set_title("Mean of per-run means\n(error bar = std. dev. across runs)")
ax2.grid(axis="y", alpha=0.3)

fig.suptitle("Team B API latency with and without Team A CPU load "
             "(%d runs x ~%d samples per scenario)" % (len(runs), n_per))
fig.tight_layout()
os.makedirs(os.path.dirname(FIGURE), exist_ok=True)
fig.savefig(FIGURE, dpi=200)

# ---- Console summary ----
print("Saved %s and %s\n" % (SUMMARY, FIGURE))
print("%-5s %-9s %7s %9s %9s %9s %5s" % ("run", "scenario", "n", "avg", "p95", "max", "err"))
for run, sc, s, err_n in rows:
    print("%-5s %-9s %7d %9.2f %9.2f %9.2f %5d" % (run, sc, s["samples"], s["avg"], s["p95"], s["max"], err_n))
print("\nPer-run ratio of mean latency (cpu_load / baseline):")
ratios = []
for r in runs:
    if (r, "baseline") in data and (r, "cpu_load") in data:
        ratio = np.mean(data[(r, "cpu_load")]) / np.mean(data[(r, "baseline")])
        ratios.append(ratio)
        print("  run %d: %.2f" % (r, ratio))
if ratios:
    higher = sum(1 for r in ratios if r > 1.0)
    print("Load was slower in %d of %d runs." % (higher, len(ratios)))
