#!/usr/bin/env python3
"""
Validate PGN files for illegal moves by replaying each game move-by-move.
Reports failures with context for diagnosis.
"""
import chess
import re
import sys
import os


def parse_pgn_games(filepath):
    """Parse PGN file into list of (headers_dict, moves_string) tuples."""
    games = []
    with open(filepath, 'r') as f:
        content = f.read()

    # Split into individual games by looking for [Event patterns
    game_chunks = re.split(r'\n(?=\[Event )', content)

    for chunk in game_chunks:
        chunk = chunk.strip()
        if not chunk:
            continue

        headers = {}
        for m in re.finditer(r'\[(\w+)\s+"([^"]*)"\]', chunk):
            headers[m.group(1)] = m.group(2)

        # Extract moves (everything after the last header line)
        lines = chunk.split('\n')
        move_lines = []
        in_moves = False
        for line in lines:
            if in_moves:
                move_lines.append(line)
            elif not line.startswith('['):
                in_moves = True
                move_lines.append(line)

        moves_text = ' '.join(move_lines).strip()
        if moves_text:
            games.append((headers, moves_text))

    return games


def tokenize_moves(moves_text):
    """
    Extract main-line moves from PGN text, skipping RAV variations and comments.
    Returns list of SAN move strings.
    """
    tokens = []
    i = 0
    depth = 0  # parentheses depth (RAV)
    in_comment = False

    current_token = ''

    while i < len(moves_text):
        ch = moves_text[i]

        if ch == '{':
            in_comment = True
            if current_token.strip():
                if depth == 0:
                    tokens.append(current_token.strip())
                current_token = ''
            i += 1
            continue
        elif ch == '}':
            in_comment = False
            i += 1
            continue
        elif in_comment:
            i += 1
            continue
        elif ch == '(':
            if current_token.strip():
                if depth == 0:
                    tokens.append(current_token.strip())
                current_token = ''
            depth += 1
            i += 1
            continue
        elif ch == ')':
            depth -= 1
            i += 1
            continue
        elif depth > 0:
            i += 1
            continue
        elif ch in ' \t\n':
            if current_token.strip():
                tokens.append(current_token.strip())
                current_token = ''
            i += 1
            continue
        else:
            current_token += ch
            i += 1
            continue

    if current_token.strip():
        tokens.append(current_token.strip())

    # Filter out move numbers, result markers, and non-move tokens
    moves = []
    for tok in tokens:
        # Skip move numbers like "1.", "12.", "1..."
        if re.match(r'^\d+\.+$', tok):
            continue
        # Skip results
        if tok in ('*', '1-0', '0-1', '1/2-1/2'):
            continue
        # Skip move number prefixes attached to moves: "1.e4" -> "e4"
        tok = re.sub(r'^\d+\.\.\.', '', tok)  # "1...e5" -> "e5"
        tok = re.sub(r'^\d+\.', '', tok)       # "1.e4" -> "e4"
        if tok:
            moves.append(tok)

    return moves


def validate_game(headers, moves_text):
    """
    Validate a single game. Returns (valid_moves_count, total_moves, error_info)
    where error_info is None if all moves are legal, or a dict with details.
    """
    moves = tokenize_moves(moves_text)
    board = chess.Board()

    for i, san in enumerate(moves):
        try:
            move = board.parse_san(san)
            board.push(move)
        except (chess.InvalidMoveError, chess.IllegalMoveError, chess.AmbiguousMoveError) as e:
            move_num = (i // 2) + 1
            color = "White" if board.turn == chess.WHITE else "Black"
            return i, len(moves), {
                'move_index': i,
                'move_num': move_num,
                'color': color,
                'san': san,
                'error': str(e),
                'fen': board.fen(),
                'prior_moves': moves[max(0, i-4):i],
                'round': headers.get('Round', '?'),
                'opening': headers.get('Opening', headers.get('Site', '?')),
            }

    return len(moves), len(moves), None


def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    files = [
        ('Carey-White.pgn', 'white'),
        ('Carey-Black.pgn', 'black'),
    ]

    all_issues = []

    for filename, color in files:
        filepath = os.path.join(base_dir, filename)
        if not os.path.exists(filepath):
            print(f"File not found: {filepath}")
            continue

        print(f"\nValidating {filename}...")
        games = parse_pgn_games(filepath)
        issue_count = 0

        for idx, (headers, moves_text) in enumerate(games):
            valid_count, total, error = validate_game(headers, moves_text)
            if error:
                issue_count += 1
                error['file'] = filename
                error['game_index'] = idx
                all_issues.append(error)

        print(f"  {len(games)} games, {issue_count} with illegal moves")

    print(f"\n{'='*70}")
    print(f"TOTAL ISSUES: {len(all_issues)}")
    print(f"{'='*70}\n")

    for issue in all_issues:
        print(f"[{issue['file']}] Round={issue['round']} ({issue['opening']})")
        print(f"  ILLEGAL: {issue['color']} move {issue['move_num']}: "
              f"'{issue['san']}' — {issue['error']}")
        print(f"  FEN:  {issue['fen']}")
        print(f"  Prior: {' '.join(issue['prior_moves'])}")
        print()


if __name__ == '__main__':
    main()
