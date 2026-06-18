"""
Visualize chess.com titled player data.

Reads cached JSON from ./data/ (produced by fetch_data.py) and generates:
  1. Blitz rating distributions overlaid by title (GM/IM/FM/NM/CM)
  2. US NM blitz rating distributions broken down by time control

Usage:
  python visualize.py                    # generate all charts
  python visualize.py --output-dir ./out # custom output directory
"""

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from scipy.stats import gaussian_kde

SCRIPT_DIR = Path(__file__).resolve().parent
DATA_DIR = SCRIPT_DIR / "data"

TITLES = ["GM", "IM", "FM", "NM", "CM"]
TITLE_COLORS = {
    "GM": "#e63946",
    "IM": "#f4a261",
    "FM": "#2a9d8f",
    "NM": "#457b9d",
    "CM": "#6c757d",
}

# Common blitz time controls and their friendly labels
TC_LABELS = {
    "180": "3+0",
    "180+2": "3+2",
    "300": "5+0",
    "300+2": "5+2",
    "300+3": "5+3",
    "60": "1+0",
    "120+1": "2+1",
}


def load_json(path: Path):
    if path.exists():
        with open(path) as f:
            return json.load(f)
    return None


def extract_blitz_ratings(title: str) -> list[int]:
    """Pull last.rating from chess_blitz for every player with a title's stats."""
    stats = load_json(DATA_DIR / f"stats_{title}.json")
    if not stats:
        return []
    ratings = []
    for username, s in stats.items():
        blitz = s.get("chess_blitz", {})
        last = blitz.get("last", {})
        rating = last.get("rating")
        if rating and isinstance(rating, (int, float)):
            ratings.append(int(rating))
    return ratings


def plot_title_distributions(output_dir: Path):
    """Overlaid KDE curves of blitz rating by title."""
    fig, ax = plt.subplots(figsize=(14, 7))

    all_ratings = {}
    for title in TITLES:
        ratings = extract_blitz_ratings(title)
        if ratings:
            all_ratings[title] = ratings

    if not all_ratings:
        print("No stats data found — run fetch_data.py fetch-stats first")
        return

    x_min = min(min(r) for r in all_ratings.values()) - 100
    x_max = max(max(r) for r in all_ratings.values()) + 100
    x = np.linspace(x_min, x_max, 500)

    for title in TITLES:
        if title not in all_ratings:
            continue
        ratings = np.array(all_ratings[title])
        kde = gaussian_kde(ratings, bw_method=0.15)
        y = kde(x)
        color = TITLE_COLORS[title]
        ax.plot(x, y, color=color, linewidth=2.5, label=f"{title} (n={len(ratings)}, μ={np.mean(ratings):.0f})")
        ax.fill_between(x, y, alpha=0.12, color=color)

    ax.set_xlabel("Chess.com Blitz Rating", fontsize=13)
    ax.set_ylabel("Density", fontsize=13)
    ax.set_title("Chess.com Blitz Rating Distribution by Title", fontsize=16, fontweight="bold")
    ax.legend(fontsize=11, loc="upper left")
    ax.grid(True, alpha=0.3)
    ax.set_xlim(x_min, x_max)

    out = output_dir / "blitz_by_title.png"
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)
    print(f"Saved: {out}")


def plot_nm_by_time_control(output_dir: Path):
    """US NM blitz rating distributions broken down by time control."""
    stats = load_json(DATA_DIR / "stats_NM.json")
    profiles = load_json(DATA_DIR / "nm_profiles.json")
    games = load_json(DATA_DIR / "nm_recent_blitz.json")

    if not all([stats, profiles, games]):
        print("Missing NM data — run fetch_data.py fetch-nm-detail first")
        return

    # filter to US NMs
    us_nms = {u for u, p in profiles.items() if p.get("country", "").endswith("/US")}

    # group by time control
    tc_ratings: dict[str, list[int]] = defaultdict(list)
    tc_raw_counts: Counter = Counter()

    for username in us_nms:
        game_info = games.get(username, {})
        tc_raw = game_info.get("time_control")
        if not tc_raw:
            continue

        tc_raw_counts[tc_raw] += 1

        player_stats = stats.get(username, {})
        blitz = player_stats.get("chess_blitz", {})
        rating = blitz.get("last", {}).get("rating")
        if not rating:
            continue

        label = TC_LABELS.get(tc_raw, tc_raw)
        tc_ratings[label].append(int(rating))

    if not tc_ratings:
        print("No US NM blitz game data found")
        return

    # print summary
    print("\nUS NM time control distribution:")
    for tc, count in sorted(tc_raw_counts.items(), key=lambda x: -x[1]):
        label = TC_LABELS.get(tc, tc)
        print(f"  {label:8s} ({tc:10s}): {count} players")

    # only plot time controls with enough data
    MIN_PLAYERS = 8
    plottable = {tc: r for tc, r in tc_ratings.items() if len(r) >= MIN_PLAYERS}

    if not plottable:
        print(f"No time controls with >= {MIN_PLAYERS} players")
        return

    tc_colors = plt.cm.tab10(np.linspace(0, 1, max(len(plottable), 1)))

    fig, ax = plt.subplots(figsize=(14, 7))

    all_r = [r for rs in plottable.values() for r in rs]
    x_min = min(all_r) - 100
    x_max = max(all_r) + 100
    x = np.linspace(x_min, x_max, 500)

    for idx, (tc, ratings) in enumerate(sorted(plottable.items(), key=lambda x: -len(x[1]))):
        ratings_arr = np.array(ratings)
        kde = gaussian_kde(ratings_arr, bw_method=0.2)
        y = kde(x)
        color = tc_colors[idx % len(tc_colors)]
        ax.plot(x, y, color=color, linewidth=2.5,
                label=f"{tc} (n={len(ratings)}, μ={np.mean(ratings):.0f})")
        ax.fill_between(x, y, alpha=0.10, color=color)

    ax.set_xlabel("Chess.com Blitz Rating", fontsize=13)
    ax.set_ylabel("Density", fontsize=13)
    ax.set_title("US National Masters — Blitz Rating by Time Control", fontsize=16, fontweight="bold")
    ax.legend(fontsize=11, loc="upper left")
    ax.grid(True, alpha=0.3)
    ax.set_xlim(x_min, x_max)

    out = output_dir / "us_nm_blitz_by_tc.png"
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)
    print(f"Saved: {out}")

    # also save the dataset as CSV
    csv_out = output_dir / "us_nm_blitz_dataset.csv"
    with open(csv_out, "w") as f:
        f.write("username,name,blitz_rating,time_control\n")
        for username in sorted(us_nms):
            game_info = games.get(username, {})
            tc_raw = game_info.get("time_control")
            if not tc_raw:
                continue
            player_stats = stats.get(username, {})
            rating = player_stats.get("chess_blitz", {}).get("last", {}).get("rating")
            if not rating:
                continue
            name = profiles.get(username, {}).get("name", "").replace(",", " ")
            label = TC_LABELS.get(tc_raw, tc_raw)
            f.write(f"{username},{name},{rating},{label}\n")
    print(f"Saved: {csv_out}")


def main():
    parser = argparse.ArgumentParser(description="Visualize titled player data")
    parser.add_argument("--output-dir", type=Path, default=DATA_DIR,
                        help="Where to save charts (default: ./data)")
    args = parser.parse_args()
    args.output_dir.mkdir(exist_ok=True)

    plot_title_distributions(args.output_dir)
    plot_nm_by_time_control(args.output_dir)


if __name__ == "__main__":
    main()
