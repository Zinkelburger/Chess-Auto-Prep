#!/usr/bin/env python3
"""
Repertoire Server for Lichess Repertoire Sync extension
Simple server that appends unique lines to a PGN file

Requirements:
    pip install flask flask-cors chess

Usage:
    python server.py
"""

from flask import Flask, request, jsonify
from flask_cors import CORS
import chess
import chess.pgn
import os
import threading
import queue
from datetime import datetime
from pathlib import Path

app = Flask(__name__)
CORS(app)

REPERTOIRE_FILE = 'repertoire.pgn'

# Request queue for handling concurrent requests
request_queue = queue.Queue()
processing_lock = threading.Lock()

# Glyph ID to NAG (Numeric Annotation Glyph) mapping
GLYPH_TO_NAG = {
    1: 1,    # ! - Good move
    2: 2,    # ? - Mistake
    3: 3,    # !! - Brilliant move
    4: 4,    # ?? - Blunder
    5: 5,    # !? - Interesting move
    6: 6,    # ?! - Dubious move
    7: 7,    # □ - Only move
    10: 10,  # = - Equal position
    13: 13,  # ∞ - Unclear position
    14: 14,  # ⩲ - White is slightly better
    15: 15,  # ⩱ - Black is slightly better
    16: 16,  # ± - White is better
    17: 17,  # ∓ - Black is better
    18: 18,  # +- - White is winning
    19: 19,  # -+ - Black is winning
}


def create_pgn_game(line_data):
    """Create a chess.pgn.Game from the line data"""
    game = chess.pgn.Game()

    # Set headers
    game.headers["Event"] = "Repertoire Line"
    game.headers["Site"] = "Lichess Analysis"
    game.headers["Date"] = datetime.now().strftime("%Y.%m.%d")
    game.headers["Round"] = "?"
    game.headers["White"] = "?"
    game.headers["Black"] = "?"
    game.headers["Result"] = "*"

    # Set variant if not standard
    variant = line_data.get('variant', 'standard')
    if variant != 'standard':
        game.headers["Variant"] = variant.title()

    # Set FEN if not starting position
    start_fen = line_data.get('startFen')
    standard_fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'
    if start_fen and start_fen != standard_fen:
        game.headers["FEN"] = start_fen
        board = chess.Board(start_fen)
    else:
        board = chess.Board()

    # Add moves with annotations and comments
    node = game
    moves = line_data.get('moves', [])

    for move_data in moves:
        uci = move_data.get('uci')
        if not uci:
            continue

        try:
            move = chess.Move.from_uci(uci)
            if move not in board.legal_moves:
                print(f"Warning: Illegal move {uci} in position {board.fen()}")
                continue

            # Add the move
            node = node.add_variation(move)
            board.push(move)

            # Add NAGs (glyphs/annotations)
            glyphs = move_data.get('glyphs', [])
            for glyph in glyphs:
                glyph_id = glyph.get('id')
                nag = GLYPH_TO_NAG.get(glyph_id)
                if nag:
                    node.nags.add(nag)

            # Add comments
            comments = move_data.get('comments', [])
            if comments:
                comment_text = ' '.join(comments).strip()
                if comment_text:
                    node.comment = comment_text

            # Add evaluation as comment if present
            eval_data = move_data.get('eval')
            if eval_data:
                eval_comment = format_eval(eval_data)
                if eval_comment:
                    if node.comment:
                        node.comment += f" [{eval_comment}]"
                    else:
                        node.comment = f"[{eval_comment}]"

        except ValueError as e:
            print(f"Error parsing move {uci}: {e}")
            continue

    return game


def format_eval(eval_data):
    """Format evaluation data as a string"""
    if eval_data.get('mate') is not None:
        mate = eval_data['mate']
        return f"M{mate}" if mate > 0 else f"M{mate}"
    elif eval_data.get('cp') is not None:
        cp = eval_data['cp']
        return f"{cp/100:+.2f}"
    return None


def get_line_signature(line_data):
    """Generate a signature for a line based on moves (for duplicate detection)"""
    moves = line_data.get('moves', [])
    start_fen = line_data.get('startFen', 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1')
    variant = line_data.get('variant', 'standard')

    # Create signature from variant, start FEN, and move UCIs
    uci_sequence = [m.get('uci', '') for m in moves if m.get('uci')]
    signature = f"{variant}:{start_fen}:{':'.join(uci_sequence)}"
    return signature


def is_duplicate(line_data):
    """Check if this line already exists in the repertoire"""
    if not os.path.exists(REPERTOIRE_FILE):
        return False

    new_signature = get_line_signature(line_data)

    # Read existing games and check for duplicates
    with open(REPERTOIRE_FILE) as f:
        while True:
            game = chess.pgn.read_game(f)
            if game is None:
                break

            # Extract moves from existing game
            board = game.board()
            existing_ucis = []
            node = game
            while node.variations:
                next_node = node.variation(0)
                move = next_node.move
                existing_ucis.append(move.uci())
                board.push(move)
                node = next_node

            # Create signature for existing game
            existing_variant = game.headers.get('Variant', 'Standard').lower()
            existing_fen = game.headers.get('FEN', 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1')
            existing_signature = f"{existing_variant}:{existing_fen}:{':'.join(existing_ucis)}"

            if new_signature == existing_signature:
                return True

    return False


def append_to_pgn_file(game):
    """Append a game to the repertoire PGN file"""
    # Create file if it doesn't exist
    if not os.path.exists(REPERTOIRE_FILE):
        Path(REPERTOIRE_FILE).touch()

    # Append the game
    with open(REPERTOIRE_FILE, 'a') as f:
        # Add newline separator if file is not empty
        if os.path.getsize(REPERTOIRE_FILE) > 0:
            f.write('\n\n')

        exporter = chess.pgn.FileExporter(f)
        game.accept(exporter)


def count_games_in_pgn():
    """Count the number of games in the PGN file"""
    if not os.path.exists(REPERTOIRE_FILE):
        return 0

    count = 0
    with open(REPERTOIRE_FILE) as f:
        while chess.pgn.read_game(f):
            count += 1
    return count


def process_add_line_request(line_data):
    """Process a single add-line request (runs in queue)"""
    with processing_lock:
        # Check for duplicates
        if is_duplicate(line_data):
            return {
                'status': 'duplicate',
                'message': 'Line already exists in repertoire',
                'lineCount': count_games_in_pgn()
            }

        # Create PGN game from the line data
        game = create_pgn_game(line_data)

        # Append to PGN file
        append_to_pgn_file(game)

        # Get total count
        total_games = count_games_in_pgn()

        # Print summary
        pgn_text = line_data.get('pgn', '')
        print(f"✓ Added line to {REPERTOIRE_FILE}")
        print(f"  {pgn_text[:80]}{'...' if len(pgn_text) > 80 else ''}")
        print(f"  Moves: {len(line_data.get('moves', []))}")
        print(f"  Total: {total_games}")

        return {
            'status': 'success',
            'lineCount': total_games,
            'message': f'Line added to {REPERTOIRE_FILE}'
        }


def request_worker():
    """Worker thread that processes queued requests"""
    while True:
        try:
            # Get request from queue (blocks until available)
            task = request_queue.get()
            if task is None:  # Shutdown signal
                break

            line_data, result_queue = task

            # Process the request
            try:
                result = process_add_line_request(line_data)
                result_queue.put(('success', result))
            except Exception as e:
                print(f"✗ Error processing request: {str(e)}")
                import traceback
                traceback.print_exc()
                result_queue.put(('error', str(e)))

            # Mark task as done
            request_queue.task_done()

        except Exception as e:
            print(f"✗ Worker error: {str(e)}")


# Start worker thread
worker_thread = threading.Thread(target=request_worker, daemon=True)
worker_thread.start()


@app.route('/add-line', methods=['POST'])
def add_line():
    """Receive a line from the browser extension and queue it for processing"""
    try:
        data = request.json

        # Validate data
        if not data or 'moves' not in data:
            return jsonify({'error': 'Invalid data format'}), 400

        if len(data['moves']) == 0:
            return jsonify({'error': 'No moves provided'}), 400

        # Queue the request
        result_queue = queue.Queue()
        request_queue.put((data, result_queue))

        # Wait for result (with timeout)
        status, result = result_queue.get(timeout=30)

        if status == 'error':
            return jsonify({'error': result}), 500

        return jsonify(result), 200

    except queue.Empty:
        return jsonify({'error': 'Request timeout'}), 504
    except Exception as e:
        print(f"✗ Error: {str(e)}")
        import traceback
        traceback.print_exc()
        return jsonify({'error': str(e)}), 500


@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    try:
        line_count = count_games_in_pgn()
        file_size = os.path.getsize(REPERTOIRE_FILE) if os.path.exists(REPERTOIRE_FILE) else 0
        queue_size = request_queue.qsize()

        return jsonify({
            'status': 'ok',
            'lineCount': line_count,
            'fileSize': file_size,
            'queueSize': queue_size,
            'file': os.path.abspath(REPERTOIRE_FILE)
        }), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500


if __name__ == '__main__':
    print("=" * 70)
    print("Lichess Repertoire Server")
    print("=" * 70)
    print(f"Server:         http://localhost:9812")
    print(f"PGN file:       {os.path.abspath(REPERTOIRE_FILE)}")
    print()
    print("Endpoints:")
    print("  POST /add-line     - Add a line to repertoire (queued)")
    print("  GET  /health       - Health check")
    print()
    print("Features:")
    print("  ✓ Duplicate detection (won't add same line twice)")
    print("  ✓ Request queueing (handles concurrent requests)")
    print("  ✓ Comments and annotations preserved")
    print()
    print("Usage:")
    print("  1. Install extension in Chrome (chrome://extensions/)")
    print("  2. Go to lichess.org/analysis")
    print("  3. Right-click any move → 'Add to repertoire'")
    print()
    print("View your repertoire:")
    print(f"  cat {REPERTOIRE_FILE}")
    print(f"  curl http://localhost:9812/health")
    print()
    print("Press Ctrl+C to stop")
    print("=" * 70)

    # Check if python-chess is installed
    try:
        import chess
        import chess.pgn
    except ImportError:
        print("\n⚠️  ERROR: python-chess is not installed!")
        print("Install it with: pip install chess")
        print()
        exit(1)

    app.run(host='localhost', port=9812, debug=False)
