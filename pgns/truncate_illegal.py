#!/usr/bin/env python3
"""
Truncate PGN games at the first illegal move.
Games with all legal moves are kept as-is.
"""
import chess
import re
import os
import sys


def tokenize_moves(moves_text):
    """Extract main-line move tokens, preserving RAV and comments in structure."""
    tokens = []  # list of (type, content) where type is 'move', 'rav', 'comment', 'number', 'result'
    i = 0
    depth = 0
    current_token = ''
    rav_content = ''
    comment_content = ''

    while i < len(moves_text):
        ch = moves_text[i]

        if ch == '{' and depth == 0:
            if current_token.strip():
                tokens.append(('text', current_token.strip()))
                current_token = ''
            comment_content = ''
            i += 1
            while i < len(moves_text) and moves_text[i] != '}':
                comment_content += moves_text[i]
                i += 1
            tokens.append(('comment', '{' + comment_content + '}'))
            i += 1
            continue
        elif ch == '(' and depth == 0:
            if current_token.strip():
                tokens.append(('text', current_token.strip()))
                current_token = ''
            depth = 1
            rav_content = '('
            i += 1
            while i < len(moves_text) and depth > 0:
                if moves_text[i] == '(':
                    depth += 1
                elif moves_text[i] == ')':
                    depth -= 1
                rav_content += moves_text[i]
                i += 1
            tokens.append(('rav', rav_content))
            depth = 0
            continue
        elif ch in ' \t\n':
            if current_token.strip():
                tokens.append(('text', current_token.strip()))
                current_token = ''
            i += 1
            continue
        else:
            current_token += ch
            i += 1

    if current_token.strip():
        tokens.append(('text', current_token.strip()))

    return tokens


def is_move_number(text):
    return bool(re.match(r'^\d+\.+$', text))


def is_result(text):
    return text in ('*', '1-0', '0-1', '1/2-1/2')


def san_from_token(tok):
    """Extract SAN move from a text token (strip move number prefixes)."""
    s = tok
    s = re.sub(r'^\d+\.\.\.', '', s)
    s = re.sub(r'^\d+\.', '', s)
    return s


def truncate_game_text(moves_text):
    """
    Validate and truncate moves_text at first illegal move.
    Returns (truncated_text, was_truncated).
    """
    tokens = tokenize_moves(moves_text)
    board = chess.Board()
    output_tokens = []
    truncated = False

    for ttype, content in tokens:
        if ttype == 'comment':
            output_tokens.append(content)
            continue
        elif ttype == 'rav':
            output_tokens.append(content)
            continue
        elif ttype == 'text':
            if is_move_number(content) or is_result(content):
                if is_result(content):
                    continue  # We'll add result at end
                output_tokens.append(content)
                continue

            # It's a move
            san = san_from_token(content)
            if not san:
                output_tokens.append(content)
                continue

            try:
                move = board.parse_san(san)
                board.push(move)
                output_tokens.append(content)
            except (chess.InvalidMoveError, chess.IllegalMoveError,
                    chess.AmbiguousMoveError):
                truncated = True
                output_tokens.append('{truncated, illegal move in doc: ' + san + '}')
                break

    result_text = ' '.join(output_tokens)
    # Clean up trailing move numbers with no move after them
    result_text = re.sub(r'\s*\d+\.\.\.\s*$', '', result_text)
    result_text = re.sub(r'\s*\d+\.\s*$', '', result_text)
    result_text = result_text.strip()

    return result_text, truncated


def process_pgn_file(filepath):
    """Process a PGN file, truncating games with illegal moves."""
    with open(filepath, 'r') as f:
        content = f.read()

    # Split into games
    game_chunks = re.split(r'\n(?=\[Event )', content)
    output_games = []
    truncated_count = 0

    for chunk in game_chunks:
        chunk = chunk.strip()
        if not chunk:
            continue

        # Separate headers from moves
        lines = chunk.split('\n')
        header_lines = []
        move_lines = []
        in_moves = False

        for line in lines:
            if in_moves:
                move_lines.append(line)
            elif line.startswith('['):
                header_lines.append(line)
            else:
                in_moves = True
                move_lines.append(line)

        moves_text = ' '.join(move_lines).strip()
        # Remove existing result marker
        moves_text = re.sub(r'\s*\*\s*$', '', moves_text)

        # Truncate if needed
        truncated_moves, was_truncated = truncate_game_text(moves_text)
        if was_truncated:
            truncated_count += 1

        # Rebuild game
        headers = '\n'.join(header_lines)
        if truncated_moves:
            game_output = f"{headers}\n\n{truncated_moves} *\n"
        else:
            game_output = f"{headers}\n\n*\n"

        output_games.append(game_output)

    # Write back
    with open(filepath, 'w') as f:
        f.write('\n'.join(output_games))

    return len(output_games), truncated_count


def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    files = ['Carey-White.pgn', 'Carey-Black.pgn']

    for filename in files:
        filepath = os.path.join(base_dir, filename)
        total, truncated = process_pgn_file(filepath)
        print(f"{filename}: {total} games, {truncated} truncated at illegal moves")


if __name__ == '__main__':
    main()
