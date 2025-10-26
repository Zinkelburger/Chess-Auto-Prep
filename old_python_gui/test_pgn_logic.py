#!/usr/bin/env python3
"""
Test the core PGN formatting logic without PySide6 dependencies.
"""

import chess.pgn
import io

def format_nags(nags) -> str:
    """Convert NAG numbers to symbols like ?, ??, !, etc."""
    nag_symbols = {
        1: "!",    # good move
        2: "?",    # mistake
        3: "!!",   # brilliant move
        4: "??",   # blunder
        5: "!?",   # interesting move
        6: "?!",   # dubious move
    }
    result = ""
    for nag in nags:
        if nag in nag_symbols:
            result += nag_symbols[nag]
    return result

def format_node_fixed(node, move_number: int = 1, is_variation: bool = False) -> str:
    """Fixed version of _format_node without the break bug."""
    html = ""
    board = node.board()
    current_node = node
    current_move_number = move_number

    # Traverse the main line without breaking
    while current_node.variations:
        child = current_node.variations[0]  # Main line
        move = child.move
        san = board.san(move)

        # Add NAG symbols (?, ??, !, etc.)
        san += format_nags(child.nags)

        # Show move number for white's moves
        if board.turn == chess.WHITE:
            html += f"{current_move_number}. "

        html += f"{san} "

        # Add comment if exists
        if child.comment:
            html += f"({child.comment[:30]}...) "

        # Handle side variations (alternatives to this move)
        if len(current_node.variations) > 1:
            for variation in current_node.variations[1:]:
                html += "( "
                html += format_node_fixed(
                    variation,
                    move_number=current_move_number,
                    is_variation=True
                )
                html += ") "

        # Update for next iteration
        if board.turn == chess.BLACK:
            current_move_number += 1

        board.push(move)
        current_node = child

    return html

def format_node_old_broken(node, move_number: int = 1, is_variation: bool = False) -> str:
    """Old broken version with the break bug."""
    html = ""
    board = node.board()

    for child in node.variations:
        move = child.move
        san = board.san(move)

        # Add NAG symbols
        san += format_nags(child.nags)

        # Show move number for white's moves
        if board.turn == chess.WHITE:
            html += f"{move_number}. "

        html += f"{san} "

        # Add comment if exists
        if child.comment:
            html += f"({child.comment[:30]}...) "

        # Handle variations
        if len(child.variations) > 1:
            main_line = child.variations[0]
            html += format_node_old_broken(
                main_line,
                move_number=move_number + 1 if board.turn == chess.BLACK else move_number,
                is_variation=False
            )

            # Show side variations
            for variation in child.variations[1:]:
                html += "( "
                html += format_node_old_broken(
                    variation,
                    move_number=move_number,
                    is_variation=True
                )
                html += ") "
        else:
            # Continue main line
            if child.variations:
                next_move_number = move_number + 1 if board.turn == chess.BLACK else move_number
                html += format_node_old_broken(child, next_move_number, is_variation)

        break  # THIS IS THE BUG!

    return html

def test_comparison():
    """Compare old broken logic vs new fixed logic."""

    # Test PGN with NAG moves
    test_pgn = '''[Event "NAG Test"]
[White "Player1"]
[Black "Player2"]
[Result "1-0"]

1. d4 Nf6 2. c4 c5 3. e3 g6 4. Nc3 Bg7 5. Nf3 O-O 6. Be2 b6?! (6... cxd4 7. Qxd4) 7. d5 d6 8. e4 e6 9. dxe6?! fxe6 10. Bg5 h6 11. Bh4 Qe7?? 12. e5 dxe5 13. Nxe5 Bb7? 14. Qxg6 Qf7?? 15. Nxh6+ 1-0'''

    print("=== Testing PGN Logic Fix ===")

    # Parse the PGN
    game = chess.pgn.read_game(io.StringIO(test_pgn))
    if not game:
        print("❌ Failed to parse test PGN")
        return

    print("✅ Game parsed successfully")

    # Test old broken logic
    print("\n=== OLD BROKEN LOGIC ===")
    old_output = format_node_old_broken(game)
    print("Output:", old_output[:200] + "...")

    # Count moves in old output
    old_move_count = old_output.count(". ") + old_output.count("?") + old_output.count("!")
    print(f"Approximate moves detected: {old_move_count}")

    # Check for expected NAG moves in old output
    expected_nags = ["b6?!", "dxe6?!", "Qe7??", "Bb7?", "Qf7??"]
    old_missing = []
    for expected in expected_nags:
        if expected not in old_output:
            old_missing.append(expected)

    print(f"Missing NAG moves: {old_missing}")

    # Test new fixed logic
    print("\n=== NEW FIXED LOGIC ===")
    new_output = format_node_fixed(game)
    print("Output:", new_output[:200] + "...")

    # Count moves in new output
    new_move_count = new_output.count(". ") + new_output.count("?") + new_output.count("!")
    print(f"Approximate moves detected: {new_move_count}")

    # Check for expected NAG moves in new output
    new_missing = []
    for expected in expected_nags:
        if expected not in new_output:
            new_missing.append(expected)

    print(f"Missing NAG moves: {new_missing}")

    # Summary
    print("\n=== COMPARISON SUMMARY ===")
    print(f"Old logic detected ~{old_move_count} moves, missing {len(old_missing)} NAG moves")
    print(f"New logic detected ~{new_move_count} moves, missing {len(new_missing)} NAG moves")

    if len(new_missing) < len(old_missing):
        print("✅ NEW LOGIC IS BETTER!")
    else:
        print("❌ Fix didn't work as expected")

    print(f"\n=== FULL NEW OUTPUT ===")
    print(new_output)

if __name__ == "__main__":
    test_comparison()