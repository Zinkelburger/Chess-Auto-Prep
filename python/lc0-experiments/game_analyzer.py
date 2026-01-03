#!/usr/bin/env python3
"""
LC0 Game Analyzer - WLD Evolution Over Time

This script analyzes complete chess games and tracks how Win/Loss/Draw percentages
evolve throughout the game. Useful for identifying critical moments, blunders,
and the overall flow of the game.
"""

import asyncio
import chess
import chess.engine
import chess.pgn
import sys
import argparse
import json
import io
import matplotlib
matplotlib.use('Agg')  # Use non-interactive backend
import matplotlib.pyplot as plt
from wld_calculator import calculate_wld, DEFAULT_LC0_PATH

class GameAnalyzer:
    def __init__(self, engine_path=DEFAULT_LC0_PATH, analysis_time=1.0, backend="opencl"):
        self.engine_path = engine_path
        self.analysis_time = analysis_time
        self.backend = backend

    async def analyze_game(self, pgn_text, max_moves=None):
        """
        Analyze a complete game from PGN format.

        Args:
            pgn_text (str): PGN text of the game
            max_moves (int, optional): Maximum number of moves to analyze

        Returns:
            dict: Game analysis results with move-by-move WLD data
        """
        try:
            # Parse PGN
            pgn_io = io.StringIO(pgn_text)
            game = chess.pgn.read_game(pgn_io)

            if not game:
                return {"error": "Could not parse PGN"}

            # Extract game metadata
            headers = {
                "white": game.headers.get("White", "Unknown"),
                "black": game.headers.get("Black", "Unknown"),
                "result": game.headers.get("Result", "*"),
                "date": game.headers.get("Date", "Unknown"),
                "event": game.headers.get("Event", "Unknown")
            }

            # Analyze positions move by move
            board = game.board()
            moves_analysis = []
            move_count = 0

            # Analyze starting position
            print("Analyzing starting position...")
            start_wld = await calculate_wld(
                board.fen(),
                engine_path=self.engine_path,
                analysis_time=self.analysis_time,
                backend=self.backend
            )

            moves_analysis.append({
                "move_number": 0,
                "move": None,
                "fen": board.fen(),
                "wld": start_wld
            })

            # Analyze each move
            for move in game.mainline_moves():
                move_count += 1
                if max_moves and move_count > max_moves:
                    break

                board.push(move)
                print(f"Analyzing move {move_count}: {move}")

                wld_result = await calculate_wld(
                    board.fen(),
                    engine_path=self.engine_path,
                    analysis_time=self.analysis_time,
                    backend=self.backend
                )

                moves_analysis.append({
                    "move_number": move_count,
                    "move": str(move),
                    "fen": board.fen(),
                    "wld": wld_result
                })

            return {
                "headers": headers,
                "moves_analysis": moves_analysis,
                "total_moves": move_count
            }

        except Exception as e:
            return {"error": str(e)}

    def calculate_momentum_shifts(self, game_analysis):
        """Calculate momentum shifts based on WLD changes"""
        if "error" in game_analysis:
            return []

        moves = game_analysis["moves_analysis"]
        momentum_shifts = []

        for i in range(1, len(moves)):
            current = moves[i]["wld"]
            previous = moves[i-1]["wld"]

            if "error" in current or "error" in previous:
                continue

            # Calculate change in winning chances (from White's perspective)
            current_advantage = current["win_pct"] - current["loss_pct"]
            previous_advantage = previous["win_pct"] - previous["loss_pct"]
            advantage_change = current_advantage - previous_advantage

            # Identify significant shifts (>10% change in advantage)
            if abs(advantage_change) > 10:
                shift_type = "GAIN" if advantage_change > 0 else "LOSS"
                magnitude = "MAJOR" if abs(advantage_change) > 20 else "MINOR"

                momentum_shifts.append({
                    "move_number": moves[i]["move_number"],
                    "move": moves[i]["move"],
                    "shift_type": shift_type,
                    "magnitude": magnitude,
                    "advantage_change": advantage_change,
                    "new_advantage": current_advantage
                })

        return momentum_shifts

    def generate_wld_plot(self, game_analysis, output_file="game_wld_analysis.png"):
        """Generate a plot showing WLD evolution over the game"""
        if "error" in game_analysis:
            return None

        moves = game_analysis["moves_analysis"]
        headers = game_analysis["headers"]

        move_numbers = []
        win_percentages = []
        draw_percentages = []
        loss_percentages = []

        for move_data in moves:
            wld = move_data["wld"]
            if "error" not in wld:
                move_numbers.append(move_data["move_number"])
                win_percentages.append(wld["win_pct"])
                draw_percentages.append(wld["draw_pct"])
                loss_percentages.append(wld["loss_pct"])

        if not move_numbers:
            return None

        # Create the plot
        plt.figure(figsize=(12, 8))

        # Plot WLD percentages
        plt.plot(move_numbers, win_percentages, 'g-', label='White Win %', linewidth=2)
        plt.plot(move_numbers, draw_percentages, 'b-', label='Draw %', linewidth=2)
        plt.plot(move_numbers, loss_percentages, 'r-', label='Black Win %', linewidth=2)

        plt.xlabel('Move Number')
        plt.ylabel('Percentage')
        plt.title(f'Game Analysis: {headers["white"]} vs {headers["black"]}\n{headers["event"]} - {headers["date"]} (Result: {headers["result"]})')
        plt.legend()
        plt.grid(True, alpha=0.3)
        plt.ylim(0, 100)

        # Add vertical lines for significant momentum shifts
        momentum_shifts = self.calculate_momentum_shifts(game_analysis)
        for shift in momentum_shifts:
            color = 'green' if shift["shift_type"] == "GAIN" else 'red'
            alpha = 0.7 if shift["magnitude"] == "MAJOR" else 0.4
            plt.axvline(x=shift["move_number"], color=color, alpha=alpha, linestyle='--')

        plt.tight_layout()
        plt.savefig(output_file, dpi=300, bbox_inches='tight')
        plt.close()

        return output_file

    def format_game_analysis(self, game_analysis):
        """Format game analysis results for display"""
        if "error" in game_analysis:
            return f"Error: {game_analysis['error']}"

        headers = game_analysis["headers"]
        moves = game_analysis["moves_analysis"]

        output = []
        output.append("GAME ANALYSIS REPORT")
        output.append("=" * 60)
        output.append(f"White: {headers['white']}")
        output.append(f"Black: {headers['black']}")
        output.append(f"Result: {headers['result']}")
        output.append(f"Event: {headers['event']}")
        output.append(f"Date: {headers['date']}")
        output.append(f"Total moves analyzed: {game_analysis['total_moves']}")
        output.append("")

        # Starting position analysis
        if moves and "error" not in moves[0]["wld"]:
            start_wld = moves[0]["wld"]
            output.append("STARTING POSITION:")
            output.append("-" * 20)
            output.append(f"White: {start_wld['win_pct']:.1f}%, Draw: {start_wld['draw_pct']:.1f}%, Black: {start_wld['loss_pct']:.1f}%")
            output.append("")

        # Final position analysis
        if moves and "error" not in moves[-1]["wld"]:
            final_wld = moves[-1]["wld"]
            output.append("FINAL POSITION:")
            output.append("-" * 20)
            output.append(f"White: {final_wld['win_pct']:.1f}%, Draw: {final_wld['draw_pct']:.1f}%, Black: {final_wld['loss_pct']:.1f}%")
            output.append("")

        # Momentum shifts
        momentum_shifts = self.calculate_momentum_shifts(game_analysis)
        if momentum_shifts:
            output.append("CRITICAL MOMENTS:")
            output.append("-" * 20)
            for shift in momentum_shifts:
                direction = "↗" if shift["shift_type"] == "GAIN" else "↘"
                output.append(f"Move {shift['move_number']}: {shift['move']} {direction} {shift['magnitude']} {shift['shift_type']}")
                output.append(f"  Advantage change: {shift['advantage_change']:+.1f}%")
            output.append("")

        # Game statistics
        valid_moves = [m for m in moves if "error" not in m["wld"]]
        if valid_moves:
            avg_white_win = sum(m["wld"]["win_pct"] for m in valid_moves) / len(valid_moves)
            avg_draw = sum(m["wld"]["draw_pct"] for m in valid_moves) / len(valid_moves)
            avg_black_win = sum(m["wld"]["loss_pct"] for m in valid_moves) / len(valid_moves)

            output.append("GAME STATISTICS:")
            output.append("-" * 20)
            output.append(f"Average White win probability: {avg_white_win:.1f}%")
            output.append(f"Average Draw probability: {avg_draw:.1f}%")
            output.append(f"Average Black win probability: {avg_black_win:.1f}%")

        return "\n".join(output)

async def main():
    parser = argparse.ArgumentParser(description="Analyze complete chess games with LC0")
    parser.add_argument("--pgn-file", type=str,
                       help="PGN file to analyze")
    parser.add_argument("--pgn-text", type=str,
                       help="PGN text directly")
    parser.add_argument("--max-moves", type=int,
                       help="Maximum number of moves to analyze")
    parser.add_argument("--time", type=float, default=1.0,
                       help="Analysis time per position in seconds (default: 1.0)")
    parser.add_argument("--engine-path", type=str, default=DEFAULT_LC0_PATH,
                       help=f"Path to lc0 binary (default: {DEFAULT_LC0_PATH})")
    parser.add_argument("--backend", type=str, default="opencl",
                       choices=["opencl", "cuda", "cpu"],
                       help="Engine backend (default: opencl)")
    parser.add_argument("--output", type=str,
                       help="Save results to JSON file")
    parser.add_argument("--plot", type=str,
                       help="Generate WLD plot and save to file")
    parser.add_argument("--sample-game", action="store_true",
                       help="Analyze a sample game for demonstration")

    args = parser.parse_args()

    # Sample game for demonstration
    sample_pgn = '''[Event "World Championship"]
[Site "New York"]
[Date "1995.10.17"]
[Round "10"]
[White "Kasparov, Garry"]
[Black "Anand, Viswanathan"]
[Result "1-0"]

1.e4 e5 2.Nf3 Nc6 3.Bb5 a6 4.Ba4 Nf6 5.O-O Be7 6.Re1 b5 7.Bb3 d6 8.c3 O-O 9.h3 Nb8 10.d4 Nbd7 11.c4 c6 12.cxb5 axb5 13.Nc3 Bb7 14.Bg5 b4 15.Nd5 cxd5 16.exd5 h6 17.Bh4 Nh5 18.Bxe7 Qxe7 19.dxe5 Nxe5 20.Nxe5 dxe5 21.Qf3 Rfd8 22.Rad1 Rd6 23.Qg3 Nf6 24.h4 Rad8 25.h5 R8d7 26.Qg5 Rd2 27.Rxd2 Rxd2 28.Re2 Rxe2 29.Qxe2 Qd6 30.a3 bxa3 31.bxa3 Qd1+ 32.Qxd1 Bxd5 33.Bxd5 Nxd5 34.Qd3 f6 35.Qb5 Kf7 36.a4 Ke6 37.a5 Kd6 38.a6 Kc7 39.Qa5+ Kb8 40.Qb6+ Ka8 41.a7 1-0'''

    pgn_text = ""

    if args.sample_game:
        pgn_text = sample_pgn
        print("Analyzing sample game: Kasparov vs Anand, 1995")
    elif args.pgn_file:
        try:
            with open(args.pgn_file, 'r') as f:
                pgn_text = f.read()
        except FileNotFoundError:
            print(f"Error: File '{args.pgn_file}' not found")
            sys.exit(1)
    elif args.pgn_text:
        pgn_text = args.pgn_text
    else:
        print("Error: Please provide --pgn-file, --pgn-text, or --sample-game")
        sys.exit(1)

    print("LC0 Game Analyzer")
    print("=" * 50)
    print(f"Engine: {args.engine_path}")
    print(f"Backend: {args.backend}")
    print(f"Analysis time: {args.time}s per position")
    if args.max_moves:
        print(f"Max moves: {args.max_moves}")
    print("=" * 50)
    print()

    # Create analyzer and run analysis
    analyzer = GameAnalyzer(
        engine_path=args.engine_path,
        analysis_time=args.time,
        backend=args.backend
    )

    print("Starting game analysis...")
    result = await analyzer.analyze_game(pgn_text, max_moves=args.max_moves)

    # Display results
    print(analyzer.format_game_analysis(result))

    # Generate plot if requested
    if args.plot and "error" not in result:
        plot_file = analyzer.generate_wld_plot(result, args.plot)
        if plot_file:
            print(f"\nWLD evolution plot saved to: {plot_file}")

    # Save to JSON if requested
    if args.output:
        with open(args.output, 'w') as f:
            json.dump(result, f, indent=2)
        print(f"\nDetailed analysis saved to: {args.output}")

if __name__ == "__main__":
    asyncio.run(main())