
import chess.pgn
import sys
import os

def debug_pgn_parsing(pgn_path):
    print(f"--- Debugging {pgn_path} ---")
    
    if not os.path.exists(pgn_path):
        print("File does not exist!")
        return

    # 1. Read raw content first
    with open(pgn_path, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()
        print(f"File size: {len(content)} bytes")
        print(f"First 500 chars:\n{content[:500]}\n...\n")

    # 2. Parse with python-chess
    print("Parsing with python-chess...")
    with open(pgn_path, 'r', encoding='utf-8', errors='ignore') as pgn:
        game_count = 0
        while True:
            try:
                game = chess.pgn.read_game(pgn)
            except Exception as e:
                print(f"Error reading game {game_count}: {e}")
                break
                
            if game is None:
                break
                
            game_count += 1
            print(f"\nGame #{game_count}")
            print(f"Headers: {game.headers}")
            
            # Default board behavior (respects SetUp/FEN)
            board = game.board()
            print(f"Starting FEN (game.board().fen()): {board.fen()}")
            
            moves = list(game.mainline_moves())
            print(f"Move count: {len(moves)}")
            
            if len(moves) > 0:
                print(f"First move: {moves[0]}")
                board.push(moves[0])
                print(f"FEN after first move: {board.fen()}")
            else:
                print("NO MOVES FOUND in mainline.")
                
            if game_count >= 3:
                print("\nStopping after 3 games for brevity.")
                break

if __name__ == "__main__":
    # Use the file currently in the media directory
    pgn_file = "/home/anbernal/Documents/Chess-Auto-Prep/poopchess/media/courses/pgns/benoni.pgn"
    debug_pgn_parsing(pgn_file)

