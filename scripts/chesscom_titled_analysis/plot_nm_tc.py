"""
Plot US NM blitz rating distributions by time control.

Data lives in ./data/ (produced by fetch_data.py).
Only plots the three major time controls: 3+0, 3+2, 5+0.

Usage:
  python plot_nm_tc.py
"""

import json
from collections import defaultdict
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy.stats import gaussian_kde

DATA_DIR = Path(__file__).resolve().parent / "data"

TC_LABELS = {
    "180": "3+0",
    "180+2": "3+2",
    "300": "5+0",
}

KEEP = {"3+0", "3+2", "5+0"}

COLORS = {
    "3+0": "#e63946",
    "3+2": "#2a9d8f",
    "5+0": "#457b9d",
}


def load(name):
    p = DATA_DIR / name
    if p.exists():
        with open(p) as f:
            return json.load(f)
    return None


def main():
    stats = load("stats_NM.json")
    profiles = load("nm_profiles.json")
    games = load("nm_recent_blitz.json")

    if not all([stats, profiles, games]):
        print("Missing data — run fetch_data.py first")
        return

    us_nms = {u for u, p in profiles.items() if p.get("country", "").endswith("/US")}

    tc_ratings: dict[str, list[int]] = defaultdict(list)
    for username in us_nms:
        tc_raw = games.get(username, {}).get("time_control")
        if not tc_raw:
            continue
        label = TC_LABELS.get(tc_raw)
        if not label or label not in KEEP:
            continue
        rating = stats.get(username, {}).get("chess_blitz", {}).get("last", {}).get("rating")
        if not rating:
            continue
        tc_ratings[label].append(int(rating))

    if not tc_ratings:
        print("No data matched")
        return

    for tc, ratings in sorted(tc_ratings.items(), key=lambda x: -len(x[1])):
        print(f"  {tc}: {len(ratings)} players, mean {np.mean(ratings):.0f}")

    all_r = [r for rs in tc_ratings.values() for r in rs]
    x_min = min(all_r) - 100
    x_max = max(all_r) + 100
    x = np.linspace(x_min, x_max, 500)

    fig, ax = plt.subplots(figsize=(14, 7))

    for tc in ["3+0", "3+2", "5+0"]:
        if tc not in tc_ratings:
            continue
        ratings = np.array(tc_ratings[tc])
        kde = gaussian_kde(ratings, bw_method=0.2)
        y = kde(x)
        color = COLORS[tc]
        ax.plot(x, y, color=color, linewidth=2.5,
                label=f"{tc} (n={len(ratings)}, μ={np.mean(ratings):.0f})")
        ax.fill_between(x, y, alpha=0.12, color=color)

    ax.set_xlabel("Chess.com Blitz Rating", fontsize=13)
    ax.set_ylabel("Density", fontsize=13)
    ax.set_title("US National Masters — Blitz Rating by Time Control", fontsize=16, fontweight="bold")
    ax.legend(fontsize=11, loc="upper left")
    ax.grid(True, alpha=0.3)
    ax.set_xlim(x_min, x_max)
    fig.tight_layout()

    out = DATA_DIR / "us_nm_blitz_by_tc.png"
    fig.savefig(out, dpi=150)
    plt.close(fig)
    print(f"Saved: {out}")


if __name__ == "__main__":
    main()
