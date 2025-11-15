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
import glob

app = Flask(__name__)
CORS(app)

# Default repertoire file (for backward compatibility)
REPERTOIRE_FILE = 'repertoire.pgn'

# Get the Flutter app's repertoire directory
def get_repertoire_directory():
    """Get the repertoire directory path - Flutter app's actual location"""
    import platform

    # Check environment variable override first
    if 'REPERTOIRE_DIR' in os.environ:
        return Path(os.environ['REPERTOIRE_DIR'])

    home = Path.home()
    system = platform.system()

    # Flutter's getApplicationDocumentsDirectory() returns different paths per platform:
    # https://pub.dev/packages/path_provider

    if system == 'Windows':
        # Windows: C:\Users\<username>\Documents
        return home / 'Documents' / 'repertoires'
    elif system == 'Darwin':  # macOS
        # macOS: ~/Documents
        return home / 'Documents' / 'repertoires'
    elif system == 'Linux':
        # Linux: ~/Documents (on desktop)
        # But could also be ~/.local/share/<app_name> on some distros
        return home / 'Documents' / 'repertoires'
    else:
        # Fallback to Documents
        return home / 'Documents' / 'repertoires'

REPERTOIRE_DIR = get_repertoire_directory()

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
        # Try SAN first (from DOM extraction), then fall back to UCI
        san = move_data.get('san')
        uci = move_data.get('uci')

        if not san and not uci:
            continue

        try:
            # Parse move from SAN or UCI
            if san:
                move = board.parse_san(san)
            else:
                move = chess.Move.from_uci(uci)

            if move not in board.legal_moves:
                print(f"Warning: Illegal move {san or uci} in position {board.fen()}")
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
            print(f"Error parsing move {san or uci}: {e}")
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

    # Create signature from variant, start FEN, and move SANs (more reliable than UCI for DOM extraction)
    san_sequence = [m.get('san', '') for m in moves if m.get('san')]
    signature = f"{variant}:{start_fen}:{':'.join(san_sequence)}"
    return signature


def is_duplicate(line_data, target_file=None):
    """Check if this line already exists in the repertoire"""
    if target_file is None:
        target_file = REPERTOIRE_FILE

    print(f"[DUPLICATE CHECK] Checking for duplicates in: {target_file}")

    if not os.path.exists(target_file):
        print(f"[DUPLICATE CHECK] File does not exist, no duplicates")
        return False

    new_signature = get_line_signature(line_data)
    print(f"[DUPLICATE CHECK] New line signature: {new_signature}")

    # Read existing games and check for duplicates
    game_count = 0
    with open(target_file) as f:
        while True:
            game = chess.pgn.read_game(f)
            if game is None:
                break

            game_count += 1

            # Extract SAN moves from existing game
            board = game.board()
            existing_sans = []
            node = game
            while node.variations:
                next_node = node.variation(0)
                move = next_node.move
                existing_sans.append(board.san(move))
                board.push(move)
                node = next_node

            # Create signature for existing game
            existing_variant = game.headers.get('Variant', 'Standard').lower()
            existing_fen = game.headers.get('FEN', 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1')
            existing_signature = f"{existing_variant}:{existing_fen}:{':'.join(existing_sans)}"

            if new_signature == existing_signature:
                print(f"[DUPLICATE CHECK] MATCH FOUND in game #{game_count}")
                print(f"[DUPLICATE CHECK] Existing signature: {existing_signature}")
                return True

    print(f"[DUPLICATE CHECK] No duplicates found after checking {game_count} games")
    return False


def append_to_pgn_file(game, target_file=None):
    """Append a game to the repertoire PGN file"""
    if target_file is None:
        target_file = REPERTOIRE_FILE

    # Create file if it doesn't exist
    if not os.path.exists(target_file):
        Path(target_file).touch()

    # Append the game
    with open(target_file, 'a') as f:
        # Add newline separator if file is not empty
        if os.path.getsize(target_file) > 0:
            f.write('\n\n')

        exporter = chess.pgn.FileExporter(f)
        game.accept(exporter)


def count_games_in_pgn(target_file=None):
    """Count the number of games in the PGN file"""
    if target_file is None:
        target_file = REPERTOIRE_FILE

    if not os.path.exists(target_file):
        return 0

    count = 0
    with open(target_file) as f:
        while chess.pgn.read_game(f):
            count += 1
    return count


def process_add_line_request(line_data, target_file=None):
    """Process a single add-line request (runs in queue)"""
    with processing_lock:
        if target_file is None:
            target_file = REPERTOIRE_FILE

        # Check for duplicates
        if is_duplicate(line_data, target_file):
            return {
                'status': 'duplicate',
                'message': 'Line already exists in repertoire',
                'lineCount': count_games_in_pgn(target_file)
            }

        # Create PGN game from the line data
        game = create_pgn_game(line_data)

        # Append to PGN file
        append_to_pgn_file(game, target_file)

        # Get total count
        total_games = count_games_in_pgn(target_file)

        # Print summary
        pgn_text = line_data.get('pgn', '')
        print(f"✓ Added line to {target_file}")
        print(f"  {pgn_text[:80]}{'...' if len(pgn_text) > 80 else ''}")
        print(f"  Moves: {len(line_data.get('moves', []))}")
        print(f"  Total: {total_games}")

        return {
            'status': 'success',
            'lineCount': total_games,
            'message': f'Line added to {os.path.basename(target_file)}'
        }


def request_worker():
    """Worker thread that processes queued requests"""
    while True:
        try:
            # Get request from queue (blocks until available)
            task = request_queue.get()
            if task is None:  # Shutdown signal
                break

            line_data, result_queue, target_file = task

            # Process the request
            try:
                result = process_add_line_request(line_data, target_file)
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


@app.route('/list-repertoires', methods=['GET'])
def list_repertoires():
    """List all repertoire files with metadata"""
    try:
        # Ensure directory exists
        if not REPERTOIRE_DIR.exists():
            REPERTOIRE_DIR.mkdir(parents=True, exist_ok=True)
            return jsonify({'repertoires': []}), 200

        repertoires = []
        for pgn_file in REPERTOIRE_DIR.glob('*.pgn'):
            stat = pgn_file.stat()
            repertoires.append({
                'name': pgn_file.stem,  # filename without .pgn
                'filename': pgn_file.name,
                'path': str(pgn_file),
                'modified': stat.st_mtime,
                'size': stat.st_size,
                'lineCount': count_games_in_pgn(str(pgn_file))
            })

        # Sort by modification time (most recent first)
        repertoires.sort(key=lambda x: x['modified'], reverse=True)

        return jsonify({'repertoires': repertoires}), 200

    except Exception as e:
        print(f"✗ Error listing repertoires: {str(e)}")
        import traceback
        traceback.print_exc()
        return jsonify({'error': str(e)}), 500


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

        # Get target repertoire file (optional)
        target_filename = data.get('targetRepertoire')
        target_file = None

        if target_filename:
            # Sanitize filename
            target_filename = os.path.basename(target_filename)
            if not target_filename.endswith('.pgn'):
                target_filename += '.pgn'

            target_file = str(REPERTOIRE_DIR / target_filename)

            # Create directory if needed
            REPERTOIRE_DIR.mkdir(parents=True, exist_ok=True)
        else:
            # Use default file for backward compatibility
            target_file = REPERTOIRE_FILE

        # Queue the request
        result_queue = queue.Queue()
        request_queue.put((data, result_queue, target_file))

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
    print(f"Repertoire dir: {REPERTOIRE_DIR}")
    print(f"Fallback file:  {os.path.abspath(REPERTOIRE_FILE)}")
    print()
    print("Endpoints:")
    print("  GET  /list-repertoires - List all repertoires")
    print("  POST /add-line         - Add a line to repertoire (queued)")
    print("  GET  /health           - Health check")
    print()
    print("Features:")
    print("  ✓ Flutter app integration (reads from app's repertoire directory)")
    print("  ✓ Duplicate detection (won't add same line twice)")
    print("  ✓ Request queueing (handles concurrent requests)")
    print("  ✓ Comments and annotations preserved")
    print()
    print("Usage:")
    print("  1. Install extension in Chrome (chrome://extensions/)")
    print("  2. Go to lichess.org/analysis")
    print("  3. Right-click any move → Select repertoire → Add line")
    print()
    print("Test endpoints:")
    print(f"  curl http://localhost:9812/list-repertoires")
    print(f"  curl http://localhost:9812/health")
    print()
    print("Set custom directory:")
    print("  export REPERTOIRE_DIR=/path/to/repertoires")
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
