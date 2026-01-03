#!/usr/bin/env python3
"""
LC0 Experiments Demo

This script demonstrates all three analysis tools working together
to provide comprehensive position and game analysis.
"""

import asyncio
from wld_calculator import calculate_wld
from sharpness_analyzer import GameAnalyzer
from game_analyzer import GameAnalyzer as GameFullAnalyzer

async def demo():
    print("LC0 EXPERIMENTS DEMO")
    print("=" * 60)

    # Demo 1: Basic WLD calculation
    print("\n1. BASIC WLD CALCULATION")
    print("-" * 30)

    # Analyze a sharp tactical position
    tactical_fen = "r1bq1rk1/pp2nppp/2n1b3/3p4/2PP4/2N1PN2/PP3PPP/R2QKB1R w KQ - 0 9"
    print(f"Analyzing tactical position...")

    wld_result = await calculate_wld(tactical_fen, analysis_time=1.0)

    if "error" not in wld_result:
        print(f"Win: {wld_result['win_pct']:.1f}%")
        print(f"Draw: {wld_result['draw_pct']:.1f}%")
        print(f"Loss: {wld_result['loss_pct']:.1f}%")
        print(f"Best move: {wld_result['best_move']}")

        # Calculate sharpness manually
        draw_pct = wld_result['draw_pct']
        sharpness = 100 / draw_pct if draw_pct > 0 else 100.0
        print(f"Sharpness score: {sharpness:.2f}")

        if sharpness > 4.0:
            print("Assessment: SHARP POSITION")
        elif sharpness > 3.0:
            print("Assessment: BALANCED POSITION")
        else:
            print("Assessment: DRAWISH POSITION")
    else:
        print(f"Error: {wld_result['error']}")

    # Demo 2: Compare different position types
    print("\n\n2. POSITION TYPE COMPARISON")
    print("-" * 30)

    positions = [
        ("Starting Position", "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"),
        ("Tactical Position", "r1bq1rk1/pp2nppp/2n1b3/3p4/2PP4/2N1PN2/PP3PPP/R2QKB1R w KQ - 0 9"),
        ("Endgame", "8/8/8/8/8/3k4/3p4/3K4 w - - 0 1")
    ]

    for name, fen in positions:
        print(f"\n{name}:")
        result = await calculate_wld(fen, analysis_time=0.5)

        if "error" not in result:
            draw_pct = result['draw_pct']
            sharpness = 100 / draw_pct if draw_pct > 0 else 100.0
            print(f"  WLD: {result['win_pct']:.1f}% / {result['draw_pct']:.1f}% / {result['loss_pct']:.1f}%")
            print(f"  Sharpness: {sharpness:.2f}")
        else:
            print(f"  Error: {result['error']}")

    print("\n\n3. MINI GAME ANALYSIS")
    print("-" * 30)

    # Analyze first few moves of a famous game
    print("Analyzing opening moves of Kasparov vs Deep Blue (1997)...")

    moves_to_analyze = [
        ("Starting", "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"),
        ("1.e4", "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"),
        ("1...c5", "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2"),
        ("2.Nf3", "rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2")
    ]

    previous_advantage = None

    for move_desc, fen in moves_to_analyze:
        result = await calculate_wld(fen, analysis_time=0.5)

        if "error" not in result:
            advantage = result['win_pct'] - result['loss_pct']

            print(f"\n{move_desc}:")
            print(f"  White advantage: {advantage:+.1f}%")

            if previous_advantage is not None:
                change = advantage - previous_advantage
                direction = "↗" if change > 0 else "↘" if change < 0 else "→"
                print(f"  Change: {change:+.1f}% {direction}")

            previous_advantage = advantage

    print("\n\nDEMO COMPLETE!")
    print("=" * 60)
    print("\nTo explore further:")
    print("• Run individual scripts with --help for more options")
    print("• Try the game analyzer with --sample-game")
    print("• Experiment with different positions and time controls")
    print("• Check the README.md for detailed usage instructions")

if __name__ == "__main__":
    asyncio.run(demo())