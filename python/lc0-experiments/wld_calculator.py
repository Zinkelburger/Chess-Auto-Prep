#!/usr/bin/env python3
"""
LC0 WLD (Win/Loss/Draw) Percentage Calculator

This script analyzes chess positions using LC0 and reports Win/Loss/Draw percentages.
"""

import asyncio
import chess
import chess.engine
import sys
import argparse

# Default path to lc0 binary
DEFAULT_LC0_PATH = "/var/home/bigman/Documents/CodingProjects/lc0/build/release/lc0"

async def calculate_wld(fen, engine_path=DEFAULT_LC0_PATH, analysis_time=2.0, backend="opencl"):
    """
    Calculate Win/Loss/Draw percentages for a given position.

    Args:
        fen (str): FEN string of the position to analyze
        engine_path (str): Path to lc0 binary
        analysis_time (float): Analysis time in seconds
        backend (str): Engine backend ("opencl", "cuda", "cpu")

    Returns:
        dict: Contains win_pct, draw_pct, loss_pct, evaluation, and best_move
    """
    try:
        # Start the engine
        transport, engine = await chess.engine.popen_uci(engine_path)

        # Configure backend
        await engine.configure({"Backend": backend})

        # Create board from FEN
        board = chess.Board(fen)

        # Analyze position
        info = await engine.analyse(board, chess.engine.Limit(time=analysis_time))

        # Extract WDL statistics
        wdl_stats = info.get("wdl")
        evaluation = info.get("score", chess.engine.PovScore(chess.engine.Cp(0), chess.WHITE))
        best_move = info.get("pv", [None])[0] if info.get("pv") else None

        result = {
            "fen": fen,
            "evaluation": str(evaluation),
            "best_move": str(best_move) if best_move else None,
            "win_pct": 0.0,
            "draw_pct": 0.0,
            "loss_pct": 0.0,
            "total_nodes": info.get("nodes", 0),
            "depth": info.get("depth", 0)
        }

        if wdl_stats:
            wins = wdl_stats.wins
            draws = wdl_stats.draws
            losses = wdl_stats.losses
            total = wins + draws + losses

            if total > 0:
                result["win_pct"] = (wins / total) * 100
                result["draw_pct"] = (draws / total) * 100
                result["loss_pct"] = (losses / total) * 100

        await engine.quit()
        return result

    except Exception as e:
        return {"error": str(e)}

def format_results(result):
    """Format analysis results for display"""
    if "error" in result:
        return f"Error: {result['error']}"

    output = []
    output.append(f"Position: {result['fen']}")
    output.append(f"Evaluation: {result['evaluation']}")
    output.append(f"Best Move: {result['best_move']}")
    output.append(f"Depth: {result['depth']}, Nodes: {result['total_nodes']:,}")
    output.append("-" * 40)
    output.append(f"Win:  {result['win_pct']:.1f}%")
    output.append(f"Draw: {result['draw_pct']:.1f}%")
    output.append(f"Loss: {result['loss_pct']:.1f}%")
    output.append("-" * 40)

    return "\n".join(output)

async def main():
    parser = argparse.ArgumentParser(description="Calculate WLD percentages using LC0")
    parser.add_argument("--fen", type=str,
                       default="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                       help="FEN string to analyze (default: starting position)")
    parser.add_argument("--time", type=float, default=2.0,
                       help="Analysis time in seconds (default: 2.0)")
    parser.add_argument("--engine-path", type=str, default=DEFAULT_LC0_PATH,
                       help=f"Path to lc0 binary (default: {DEFAULT_LC0_PATH})")
    parser.add_argument("--backend", type=str, default="opencl",
                       choices=["opencl", "cuda", "cpu"],
                       help="Engine backend (default: opencl)")

    args = parser.parse_args()

    print("LC0 WLD Calculator")
    print("=" * 50)
    print(f"Engine: {args.engine_path}")
    print(f"Backend: {args.backend}")
    print(f"Analysis time: {args.time}s")
    print("=" * 50)

    result = await calculate_wld(
        fen=args.fen,
        engine_path=args.engine_path,
        analysis_time=args.time,
        backend=args.backend
    )

    print(format_results(result))

if __name__ == "__main__":
    asyncio.run(main())