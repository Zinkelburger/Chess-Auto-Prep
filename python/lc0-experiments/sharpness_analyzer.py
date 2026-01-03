#!/usr/bin/env python3
"""
LC0 Position Sharpness Analyzer

This script calculates the "sharpness" of chess positions using LC0's WLD evaluation.
Sharpness is defined as the inverse of draw probability - sharp positions have
fewer draws and more decisive results.
"""

import asyncio
import chess
import chess.engine
import sys
import argparse
import json
from wld_calculator import calculate_wld, DEFAULT_LC0_PATH

def calculate_sharpness(wld_result):
    """
    Calculate sharpness score based on WLD percentages.

    Formula: Sharpness = 100 / Draw_Percentage
    - Higher draw percentage = Lower sharpness (boring/drawish)
    - Lower draw percentage = Higher sharpness (tactical/sharp)

    Args:
        wld_result (dict): Result from calculate_wld function

    Returns:
        dict: Enhanced result with sharpness metrics
    """
    if "error" in wld_result:
        return wld_result

    draw_pct = wld_result["draw_pct"]

    # Calculate sharpness score
    if draw_pct > 0:
        sharpness_score = 100 / draw_pct
    else:
        sharpness_score = 100.0  # Maximum sharpness (0% draws)

    # Calculate decisiveness (how likely the position is to be decisive)
    decisive_pct = wld_result["win_pct"] + wld_result["loss_pct"]

    # Classify sharpness
    if sharpness_score < 2.0:
        classification = "VERY_DRAWISH"
        description = "Boring/Technical"
    elif sharpness_score < 3.0:
        classification = "DRAWISH"
        description = "Slightly drawish"
    elif sharpness_score < 4.0:
        classification = "BALANCED"
        description = "Balanced/Dynamic"
    elif sharpness_score < 6.0:
        classification = "SHARP"
        description = "Sharp/Tactical"
    else:
        classification = "VERY_SHARP"
        description = "Extremely sharp/Complex"

    # Add sharpness data to result
    wld_result.update({
        "sharpness_score": round(sharpness_score, 2),
        "decisive_pct": round(decisive_pct, 1),
        "classification": classification,
        "description": description
    })

    return wld_result

def format_sharpness_results(result):
    """Format sharpness analysis results for display"""
    if "error" in result:
        return f"Error: {result['error']}"

    output = []
    output.append("POSITION SHARPNESS ANALYSIS")
    output.append("=" * 50)
    output.append(f"Position: {result['fen']}")
    output.append(f"Best Move: {result['best_move']} ({result['evaluation']})")
    output.append(f"Analysis: {result['depth']} depth, {result['total_nodes']:,} nodes")
    output.append("")

    # WLD Statistics
    output.append("WLD PERCENTAGES:")
    output.append("-" * 20)
    output.append(f"Win:  {result['win_pct']:5.1f}%")
    output.append(f"Draw: {result['draw_pct']:5.1f}%")
    output.append(f"Loss: {result['loss_pct']:5.1f}%")
    output.append("")

    # Sharpness Analysis
    output.append("SHARPNESS ANALYSIS:")
    output.append("-" * 20)
    output.append(f"Sharpness Score: {result['sharpness_score']}")
    output.append(f"Decisive Results: {result['decisive_pct']}%")
    output.append(f"Classification: {result['classification']}")
    output.append(f"Description: {result['description']}")
    output.append("")

    # Interpretation
    output.append("INTERPRETATION:")
    output.append("-" * 15)
    if result['sharpness_score'] < 2.0:
        output.append("• Very drawish position - likely technical endgame")
        output.append("• Low tactical complexity")
        output.append("• Good for practice positional play")
    elif result['sharpness_score'] < 3.0:
        output.append("• Slightly drawish - some imbalance but manageable")
        output.append("• Moderate complexity")
    elif result['sharpness_score'] < 4.0:
        output.append("• Balanced position with good fighting chances")
        output.append("• Dynamic potential for both sides")
        output.append("• Good for practical play")
    elif result['sharpness_score'] < 6.0:
        output.append("• Sharp position with tactical opportunities")
        output.append("• High risk/reward potential")
        output.append("• Requires precise calculation")
    else:
        output.append("• Extremely sharp and complex position")
        output.append("• Very high tactical content")
        output.append("• Dangerous for both sides - one mistake is decisive")

    return "\n".join(output)

async def analyze_multiple_positions(positions, **kwargs):
    """Analyze multiple positions for sharpness comparison"""
    results = []
    for i, fen in enumerate(positions):
        print(f"Analyzing position {i+1}/{len(positions)}...")
        wld_result = await calculate_wld(fen, **kwargs)
        sharpness_result = calculate_sharpness(wld_result)
        results.append(sharpness_result)
    return results

async def main():
    parser = argparse.ArgumentParser(description="Analyze position sharpness using LC0")
    parser.add_argument("--fen", type=str,
                       help="Single FEN string to analyze")
    parser.add_argument("--positions-file", type=str,
                       help="File containing FEN positions (one per line)")
    parser.add_argument("--preset", type=str,
                       choices=["tactical", "endgame", "opening", "middlegame"],
                       help="Use preset positions for analysis")
    parser.add_argument("--time", type=float, default=3.0,
                       help="Analysis time per position in seconds (default: 3.0)")
    parser.add_argument("--engine-path", type=str, default=,
                       help=f"Path to lc0 binary (default: {DEFAULT_LC0_PATH})")
    parser.add_argument("--backend", type=str, default="opencl",
                       choices=["opencl", "cuda", "cpu"],
                       help="Engine backend (default: opencl)")
    parser.add_argument("--output", type=str,
                       help="Save results to JSON file")

    args = parser.parse_args()

    # Preset positions for different types of analysis
    presets = {
        "tactical": [
            "r1bq1rk1/pp2nppp/2n1b3/3p4/2PP4/2N1PN2/PP3PPP/R2QKB1R w KQ - 0 9",  # Sharp Sicilian
            "r2q1rk1/1b2bppp/p2p1n2/1p2p3/4P3/1BN2N2/PPP2PPP/R2QR1K1 w - - 0 12",  # Sharp Spanish
            "r1b2rk1/pp2qppp/2np1n2/2p1p3/2B1P3/3P1N1P/PPP2PP1/RNBQR1K1 w - - 0 9"  # King's Indian Attack
        ],
        "endgame": [
            "8/8/8/8/8/3k4/3p4/3K4 w - - 0 1",  # Basic pawn endgame
            "8/8/8/8/8/3k4/8/2BK4 w - - 0 1",  # Bishop vs King
            "8/8/8/8/8/2k5/8/1R1K4 w - - 0 1"   # Rook vs King
        ],
        "opening": [
            "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",  # e4
            "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2",  # e4 e5
            "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2"  # e4 e5 Nf3
        ],
        "middlegame": [
            "r1bq1rk1/pp3ppp/2n1pn2/3p4/2PP4/2N2N2/PP2PPPP/R2QKB1R w KQ - 0 7",  # QGD
            "r2qkb1r/pb1n1ppp/1p2pn2/3p4/2PP4/1QN2N2/PP2PPPP/R1B1KB1R w KQkq - 0 7"  # QGA
        ]
    }

    positions = []

    if args.fen:
        positions = [args.fen]
    elif args.positions_file:
        try:
            with open(args.positions_file, 'r') as f:
                positions = [line.strip() for line in f if line.strip()]
        except FileNotFoundError:
            print(f"Error: File '{args.positions_file}' not found")
            sys.exit(1)
    elif args.preset:
        positions = presets[args.preset]
    else:
        # Default: analyze a sharp King's Indian position
        positions = ["r1b2rk1/pp2npbp/2npp1p1/q7/2PPP3/P1N1BN2/1P3PPP/R2QKB1R w KQ - 3 10"]

    print("LC0 Position Sharpness Analyzer")
    print("=" * 60)
    print(f"Engine: {args.engine_path}")
    print(f"Backend: {args.backend}")
    print(f"Analysis time: {args.time}s per position")
    print(f"Positions to analyze: {len(positions)}")
    print("=" * 60)
    print()

    # Analyze positions
    results = await analyze_multiple_positions(
        positions,
        engine_path=args.engine_path,
        analysis_time=args.time,
        backend=args.backend
    )

    # Display results
    for i, result in enumerate(results):
        if len(positions) > 1:
            print(f"\nPOSITION {i+1}:")
            print("=" * 20)
        print(format_sharpness_results(result))
        if i < len(results) - 1:
            print("\n" + "="*60 + "\n")

    # Save to file if requested
    if args.output:
        with open(args.output, 'w') as f:
            json.dump(results, f, indent=2)
        print(f"\nResults saved to: {args.output}")

    # Summary for multiple positions
    if len(results) > 1:
        print("\nSUMMARY:")
        print("-" * 20)
        sharpness_scores = [r["sharpness_score"] for r in results if "sharpness_score" in r]
        if sharpness_scores:
            avg_sharpness = sum(sharpness_scores) / len(sharpness_scores)
            max_sharpness = max(sharpness_scores)
            min_sharpness = min(sharpness_scores)

            print(f"Average sharpness: {avg_sharpness:.2f}")
            print(f"Sharpest position: {max_sharpness:.2f}")
            print(f"Most drawish position: {min_sharpness:.2f}")

if __name__ == "__main__":
    asyncio.run(main())