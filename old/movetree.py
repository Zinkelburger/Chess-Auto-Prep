# Construct a move tree from the player's PGNs
import chess.pgn
import io
from collections import defaultdict
from download_games import download_games_for_last_two_months

class FEN_Node:
    def __init__(self):
        self.games = 0
        self.wins = 0
        self.losses = 0
        self.draws = 0

    def update_results(self, result):
        self.games += 1
        if result == '1-0':
            self.wins += 1
        elif result == '0-1':
            self.losses += 1
        elif result == '1/2-1/2':
            self.draws += 1

# Function to build a map of FENs to PositionStats
def build_fen_map(pgns):
    fen_map = defaultdict(FEN_Node)
    for pgn_text in pgns:
        game = chess.pgn.read_game(io.StringIO(pgn_text))
        board = game.board()
        for move in game.mainline_moves():
            board.push(move)
            fen = board.fen().split(' ')[0]  # Extract position part of the FEN
            fen_map[fen].update_results(game.headers['Result'])

    return fen_map

def output_fen_map_stats(fen_map, output_file):
    for fen, stats in fen_map.items():
        output_file.write(f"FEN: {fen}, Games: {stats.games}, Wins: {stats.wins}, Losses: {stats.losses}, Draws: {stats.draws}\n")

pgns = download_games_for_last_two_months("BigManArkhangelsk", is_black=False)  # Use the function to download PGNs
with open("pgns.pgn", 'w') as file:
        for pgn in pgns:
            file.write(pgn + "\n\n")
fen_map = build_fen_map(pgns)
with open("output.txt", "w") as file:
    output_fen_map_stats(fen_map, file)