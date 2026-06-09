#!/usr/bin/env python3
"""
Parse Carey's Theory notation into PGN format.
Each terminal variation line becomes a separate PGN game entry.
"""
import re
import sys
from collections import OrderedDict


def find_entries(text):
    """Find all coded entries in the text and return them in order."""
    code_pattern = re.compile(
        r'(?:^|\n)\s*([A-Z]\d*)\)\s*', re.MULTILINE
    )
    matches = list(code_pattern.finditer(text))
    entries = OrderedDict()

    for i, match in enumerate(matches):
        code = match.group(1)
        start = match.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        content = text[start:end].strip()
        # Handle duplicate codes by appending a suffix
        original_code = code
        suffix = 2
        while code in entries:
            code = f"{original_code}_{suffix}"
            suffix += 1
        entries[code] = content

    return entries


def get_parent_code(code):
    """Get parent code. A1234 -> A123, A1 -> A, A -> None."""
    base = code.split('_')[0]  # strip dedup suffix
    if len(base) <= 1:
        return None
    parent = base[:-1]
    return parent


def clean_move_text(text):
    """Extract just the moves from an entry's content, cleaning notation."""
    # Remove variation/opening names (lines without move numbers at start)
    lines = text.split('\n')
    clean_lines = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if re.search(r'\d', line) or '...' in line or '\u2026' in line:
            clean_lines.append(line)
        elif re.match(r'^[A-Z]', line) and ')' not in line[:20]:
            continue
        else:
            clean_lines.append(line)

    text = ' '.join(clean_lines)

    # Remove "and now:" suffix
    text = re.sub(r'\s*and now:\s*$', '', text, flags=re.IGNORECASE)

    # Remove "transposes to X" at the end
    text = re.sub(r'\s*transposes to [A-Z]\d*\.?\s*$', '', text)
    text = re.sub(r'\s*transposes to the text\.?\s*$', '', text)

    # Convert Unicode ellipsis to dots
    text = text.replace('\u2026', '...')

    # Remove evaluation at the very end
    # Evals are: +.23, -.05, +1.28, -2.53, 0.00 — always preceded by space
    # Must have a sign OR be exactly 0.00
    text = re.sub(r'\s+[+-]\d*\.\d+\s*$', '', text)
    text = re.sub(r'\s+0\.00\s*$', '', text)

    # Remove commas between moves
    text = re.sub(r',\s+', ' ', text)
    text = re.sub(r',\s*$', '', text)

    # Convert castling: must do 0-0-0 before 0-0
    text = re.sub(r'\b0-0-0\b', 'O-O-O', text)
    text = re.sub(r'\b0-0\b', 'O-O', text)

    # Fix "9.O-O" -> "9. O-O"
    text = re.sub(r'(\d+)\.(O-O(?:-O)?)', r'\1. \2', text)

    # Normalize spaces
    text = re.sub(r'\s+', ' ', text).strip()

    return text


def extract_eval(content):
    """Extract evaluation from the end of content."""
    clean = re.sub(r'\s*and now:\s*$', '', content, flags=re.IGNORECASE)
    # Evals: +.23, -.05, +1.28, -2.53 (sign required) OR exactly 0.00
    match = re.search(r'\s([+-]\d*\.\d+)\s*$', clean)
    if match:
        return match.group(1)
    match = re.search(r'\s(0\.00)\s*$', clean)
    if match:
        return match.group(1)
    return None


def is_terminal(content):
    """Check if an entry is terminal (has eval, no 'and now:')."""
    if 'and now:' in content.lower():
        return False
    # Check for eval at end
    ev = extract_eval(content)
    if ev is not None:
        return True
    # Check for "transposes to" at end (also terminal for our purposes)
    if re.search(r'transposes to [A-Z]\d*\.?\s*$', content):
        return True
    return False


def find_best_parent(code, entries):
    """Find the best parent code, handling deduplication.
    If parent code was deduplicated, prefer the non-terminal version
    (the one with 'and now:') since it's the one that has children."""
    parent = get_parent_code(code)
    if parent is None:
        return None
    if parent in entries:
        # Check if this parent is terminal but a dedup version is not
        content = entries[parent]
        if 'and now:' not in content.lower():
            # Look for deduplicated versions that ARE non-terminal
            for suffix in range(2, 10):
                alt = f"{parent}_{suffix}"
                if alt in entries and 'and now:' in entries[alt].lower():
                    return alt
        return parent
    # Try deduplicated versions
    for suffix in range(2, 10):
        alt = f"{parent}_{suffix}"
        if alt in entries:
            return alt
    return None


def build_full_line(code, entries):
    """Build the complete move sequence for a code by walking up parents."""
    parts = []
    current = code
    visited = set()

    while current is not None and current not in visited:
        visited.add(current)
        if current in entries:
            moves = clean_move_text(entries[current])
            if moves:
                parts.append(moves)
        current = find_best_parent(current, entries)

    parts.reverse()
    return ' '.join(parts)


def get_opening_name(code, entries):
    """Try to extract an opening name from the entry content."""
    base = code.split('_')[0]
    if base in entries:
        content = entries[base]
    elif code in entries:
        content = entries[code]
    else:
        return ""

    lines = content.split('\n')
    for line in lines:
        line = line.strip()
        # Check if first line is a name (no move numbers)
        if line and not re.search(r'\d+[\.\s]', line[:30]) and not line.startswith('('):
            # Could be a name like "Moscow Variation" or "Scotch Game"
            name = re.sub(r'\s*and now:.*$', '', line).strip()
            if name and len(name) < 60:
                return name
    return ""


def normalize_pgn_moves(moves):
    """Final cleanup of move text for PGN output."""
    # Convert inline parenthetical sidelines to proper PGN RAV
    def clean_paren(m):
        inner = m.group(1)
        inner = inner.replace('\u2026', '...')
        inner = re.sub(r',\s+', ' ', inner)
        inner = re.sub(r'\b0-0-0\b', 'O-O-O', inner)
        inner = re.sub(r'\b0-0\b', 'O-O', inner)
        # Convert eval to comment
        inner = re.sub(r'\s+([+-]\d*\.\d+)\s*$', r' {\1}', inner)
        inner = re.sub(r'\s+0\.00\s*$', r' {0.00}', inner)
        inner = re.sub(r'\s*transposes?\s*$', r' {transposes}', inner)
        inner = re.sub(r'\s*transposes to ([A-Z]\d*)\s*$', r' {transposes to \1}', inner)
        # Remove redundant black move numbers inside parens too
        inner = re.sub(r'(\d+)\.\s*(\S+)\s+\1\s*\.{2,3}\s*', r'\1. \2 ', inner)
        inner = re.sub(r'(\d+)\s+\.{2,3}\s*', r'\1... ', inner)
        return f'({inner.strip()})'

    moves = re.sub(r'\(([^()]+)\)', clean_paren, moves)

    # Normalize black move notation: "N ...X" or "N…X" -> "N... X"
    moves = re.sub(r'(\d+)\s*\.{2,3}\s*', r'\1... ', moves)

    # Fix "8.Nxd4" -> "8. Nxd4"
    moves = re.sub(r'(\d+)\.([A-Za-z])', r'\1. \2', moves)

    # Remove redundant black move numbers when they follow the same white move
    # Pattern: "2. Nf3 2... d6" -> "2. Nf3 d6"
    moves = re.sub(r'(\d+)\.\s*(\S+)\s+\1\.\.\.\s*', r'\1. \2 ', moves)

    # Remove trailing commas
    moves = re.sub(r',\s*$', '', moves)
    moves = re.sub(r',\s*\)', ')', moves)

    # Clean multiple spaces
    moves = re.sub(r'\s+', ' ', moves).strip()

    return moves


def generate_pgn(entries, color, root_moves=""):
    """Generate PGN games for all terminal entries."""
    games = []

    for code, content in entries.items():
        if not is_terminal(content):
            continue

        # Build full move line
        full_line = build_full_line(code, entries)
        if not full_line:
            continue

        # Prepend root moves if any
        if root_moves:
            full_line = root_moves + ' ' + full_line

        # Get evaluation
        ev = extract_eval(content)
        eval_comment = f" {{{ev}}}" if ev else ""

        # Clean up moves for PGN
        pgn_moves = normalize_pgn_moves(full_line)

        # Try to find opening name by walking up the tree
        opening = ""
        base = code.split('_')[0]
        for length in range(1, len(base) + 1):
            ancestor = base[:length]
            name = get_opening_name(ancestor, entries)
            if name:
                opening = name
                break

        # Determine White/Black names
        if color == "white":
            white_name = "Carey"
            black_name = "Opponent"
        else:
            white_name = "Opponent"
            black_name = "Carey"

        # Build PGN headers
        base_code = code.split('_')[0]
        event = f"Carey Repertoire ({color.title()})"
        site = opening if opening else f"Line {base_code}"

        pgn = f'[Event "{event}"]\n'
        pgn += f'[Site "{site}"]\n'
        pgn += f'[Date "????.??.??"]\n'
        pgn += f'[Round "{base_code}"]\n'
        pgn += f'[White "{white_name}"]\n'
        pgn += f'[Black "{black_name}"]\n'
        pgn += f'[Result "*"]\n'
        if opening:
            pgn += f'[Opening "{opening}"]\n'
        pgn += f'\n{pgn_moves}{eval_comment} *\n'

        games.append(pgn)

    return games


def parse_file(input_path, output_path, color, root_moves=""):
    """Parse a raw theory file and output PGN."""
    with open(input_path, 'r') as f:
        text = f.read()

    # Handle the root moves line at the very top (e.g., "1. e4 and now:")
    root_match = re.match(r'^([\d]+\.\s*\S+)\s+and now:', text)
    if root_match and not root_moves:
        root_moves = root_match.group(1)
        root_moves = root_moves.replace('0-0-0', 'O-O-O').replace('0-0', 'O-O')

    entries = find_entries(text)
    games = generate_pgn(entries, color, root_moves)

    with open(output_path, 'w') as f:
        f.write('\n'.join(games))

    print(f"Generated {len(games)} PGN games -> {output_path}")


if __name__ == '__main__':
    import os
    base_dir = os.path.dirname(os.path.abspath(__file__))

    white_input = os.path.join(base_dir, 'carey_white_raw.txt')
    white_output = os.path.join(base_dir, 'Carey-White.pgn')

    black_input = os.path.join(base_dir, 'carey_black_raw.txt')
    black_output = os.path.join(base_dir, 'Carey-Black.pgn')

    print("Parsing Carey's White repertoire...")
    parse_file(white_input, white_output, "white")

    print("\nParsing Carey's Black repertoire...")
    parse_file(black_input, black_output, "black")

    print("\nDone!")
