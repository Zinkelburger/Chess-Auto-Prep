#!/usr/bin/env python3
"""
Extract annotated chess games from the Wojo's Weapons EPUB.

Strategy:
  1. Extract plain text from each XHTML chapter.
  2. Segment text into individual games using headers (player names, ECO, event).
  3. For each game, try to match it against known PGN databases (Wojtkiewicz.pgn,
     Kasparov.zip, Nakamura.zip, etc.) — if found, use the clean moves as the
     skeleton.
  4. For unmatched games, parse moves from the EPUB text using board-state
     inference to resolve garbled chess-font piece symbols.
  5. In both cases, attach the EPUB commentary as PGN annotations.

Output:
  - output/games.pgn   — all extracted games with annotations
  - output/errors.json  — issues that may need manual review
"""

import argparse
import json
import os
import re
import sys
import zipfile
from html import unescape
from pathlib import Path

import chess
import chess.pgn


# ---------------------------------------------------------------------------
#  EPUB text extraction
# ---------------------------------------------------------------------------

def extract_epub_text(epub_path: str) -> list[dict]:
    """Return list of {file, text} for each XHTML chapter, in spine order."""
    chapters = []
    with zipfile.ZipFile(epub_path) as z:
        names = sorted(
            [n for n in z.namelist() if n.endswith('.xhtml') and n != 'main.xhtml'],
            key=_xhtml_sort_key,
        )
        for name in names:
            raw = z.read(name).decode('utf-8')
            text = _html_to_text(raw)
            if text.strip():
                chapters.append({'file': name, 'text': text})
    return chapters


def _xhtml_sort_key(name: str):
    m = re.search(r'main-(\d+)', name)
    return int(m.group(1)) if m else 0


def _html_to_text(html: str) -> str:
    text = re.sub(r'<br\s*/?>', '\n', html)
    text = re.sub(r'</p>', '\n', text)
    text = re.sub(r'<[^>]+>', ' ', text)
    text = unescape(text)
    text = re.sub(r'[^\S\n]+', ' ', text)
    text = re.sub(r'\n{3,}', '\n\n', text)
    return text.strip()


# ---------------------------------------------------------------------------
#  PGN database loading
# ---------------------------------------------------------------------------

def load_pgn_databases(paths: list[str]) -> dict:
    """Load PGN files, return index: (white_last, black_last, year) -> game_text."""
    index = {}
    for p in paths:
        if not os.path.exists(p):
            continue
        if p.endswith('.zip'):
            import tempfile
            with zipfile.ZipFile(p) as z:
                for member in z.namelist():
                    if member.endswith('.pgn'):
                        data = z.read(member).decode('utf-8', errors='replace')
                        _index_pgn_text(data, index)
        else:
            with open(p, encoding='utf-8', errors='replace') as f:
                _index_pgn_text(f.read(), index)
    return index


def _index_pgn_text(text: str, index: dict):
    """Parse PGN text into the index."""
    games = re.split(r'\n(?=\[Event )', text)
    for game_text in games:
        headers = dict(re.findall(r'\[(\w+)\s+"([^"]*)"\]', game_text))
        if not headers.get('White'):
            continue
        moves_start = game_text.rfind(']\n')
        if moves_start < 0:
            continue
        moves = game_text[moves_start + 2:].strip()
        moves = re.sub(r'\s+', ' ', moves)

        w = _last_name(headers.get('White', '')).lower()
        b = _last_name(headers.get('Black', '')).lower()
        yr = headers.get('Date', '')[:4]

        entry = {'headers': headers, 'moves': moves, 'raw': game_text}
        key = (w, b, yr)
        if key not in index:
            index[key] = entry


def _last_name(full: str) -> str:
    return full.split(',')[0].strip()


# ---------------------------------------------------------------------------
#  Game segmentation from EPUB text
# ---------------------------------------------------------------------------

# Matches headers like: Kasparov, Garry (2805)
PLAYER_RE = re.compile(
    r'([A-Z][a-zéèêëàáâãäåæçñšžćčůúý]+(?:[ -][A-Z][a-zéèêëàáâãäåæçñšžćčůúý]*)*)'
    r',\s*'
    r'([A-Za-zéèêëàáâãäåæçñšžćčůúý .]+?)'
    r'\s*\((?:USCF\s*)?(\d{4})\)'
)

ECO_RE = re.compile(r'\[([A-E]\d{2})\]')


def segment_games(chapters: list[dict]) -> list[dict]:
    """Find all games across chapters. Return list of game info dicts."""
    games = []

    for chap in chapters:
        text = chap['text']
        file = chap['file']

        eco_matches = list(ECO_RE.finditer(text))
        if not eco_matches:
            continue

        for i, em in enumerate(eco_matches):
            eco = em.group(1)
            eco_pos = em.start()

            # Look backward for player names
            before = text[max(0, eco_pos - 500):eco_pos]
            players = list(PLAYER_RE.finditer(before))

            white_last = players[-2].group(1) if len(players) >= 2 else ''
            white_first = players[-2].group(2).strip() if len(players) >= 2 else ''
            black_last = players[-1].group(1) if len(players) >= 1 else ''
            black_first = players[-1].group(2).strip() if len(players) >= 1 else ''

            # Look forward for event and year
            after = text[em.end():em.end() + 200]
            event_year = after.strip().split('\n')[0].strip()
            year_m = re.search(r'(\d{4})', event_year)
            year = year_m.group(1) if year_m else ''
            event = event_year[:year_m.start()].strip() if year_m else event_year

            # Game text: from after the event/year line to the next game header
            game_start = em.end() + len(event_year)
            if i + 1 < len(eco_matches):
                # Find the player header before the next ECO — back up to capture it
                next_eco_pos = eco_matches[i + 1].start()
                next_before = text[max(0, next_eco_pos - 500):next_eco_pos]
                next_players = list(PLAYER_RE.finditer(next_before))
                if len(next_players) >= 2:
                    abs_start = max(0, next_eco_pos - 500) + next_players[-2].start()
                    game_end = abs_start
                else:
                    game_end = next_eco_pos
            else:
                game_end = len(text)

            game_text = text[game_start:game_end].strip()

            games.append({
                'file': file,
                'eco': eco,
                'white': f"{white_last}, {white_first}".strip(', '),
                'black': f"{black_last}, {black_first}".strip(', '),
                'white_last': white_last,
                'black_last': black_last,
                'year': year,
                'event': event,
                'game_text': game_text,
            })

    return games


# ---------------------------------------------------------------------------
#  Board-state move parser  (the core innovation)
# ---------------------------------------------------------------------------

# Destination-square pattern: optional capture 'x', file a-h, rank 1-8
DEST_SQUARE_RE = re.compile(r'(x?)([a-h])([1-8])')

RESULT_RE = re.compile(r'^(1-0|0-1|1/2-1/2|\*)$')
MOVE_NUM_RE = re.compile(r'^(\d{1,3})\.(\.\.)?$')
CASTLING_RE = re.compile(r'^[0O]-[0O](-[0O])?')

ANNOTATION_CHARS = set('!?')

# Characters that are NEVER part of a chess-font piece glyph and signal
# we've left the move token.
COMMENTARY_STARTERS = {',', ';', '(', ')', '"', "'", '"', '"', '—', '–'}


def parse_game_moves(game_text: str, verbose: bool = False) -> tuple[list[str], list[str], list[dict]]:
    """
    Parse garbled EPUB text into a move list using board-state inference.

    Returns (moves: list[str in SAN], commentary: list[str], issues: list[dict]).
    commentary[i] is the annotation text after move i (0-indexed).
    """
    board = chess.Board()
    moves = []
    commentary = []
    issues = []
    current_comment = []

    tokens = _tokenize_game_text(game_text)
    if verbose:
        print(f"  Tokens ({len(tokens)}): {tokens[:30]}...")

    i = 0
    # State: how many consecutive moves we expect before commentary.
    # After "6." → expect 2 moves (White + Black)
    # After "6..." → expect 1 move (Black only)
    # After a White move without preceding move number → expect 1 more (Black)
    # 0 = we're in commentary, only a matching move number re-arms us.
    moves_expected = 0
    commentary_depth = 0  # how many non-move tokens since last move

    while i < len(tokens):
        tok = tokens[i]

        # Skip result tokens
        if RESULT_RE.match(tok):
            if current_comment:
                commentary.append(' '.join(current_comment))
                current_comment = []
            i += 1
            continue

        # Move number: e.g. "12." or "12..."
        mn = re.match(r'^(\d{1,3})\.(\.\.)?$', tok)
        if not mn:
            mn2 = re.match(r'^(\d{1,3})\.\.\.$', tok)
            if mn2:
                mn = mn2
                # Simulate group(2) being present for Black continuation
                class _FakeMatch:
                    def group(self, n):
                        if n == 1: return mn2.group(1)
                        if n == 2: return '..'
                mn = _FakeMatch()

        if mn:
            num = int(mn.group(1))
            is_black_cont = mn.group(2) is not None

            expected_num = board.fullmove_number
            if num == expected_num:
                if is_black_cont and board.turn == chess.BLACK:
                    moves_expected = 1
                    commentary_depth = 0
                elif not is_black_cont and board.turn == chess.WHITE:
                    moves_expected = 2
                    commentary_depth = 0
                else:
                    current_comment.append(tok)
            else:
                current_comment.append(tok)
            i += 1
            continue

        # Skip commentary-style move references like "e2-e4", "a7-a6"
        if re.match(r'^\.{0,3}[a-h]\d-[a-h]\d$', tok):
            current_comment.append(tok)
            i += 1
            continue

        # Try to parse as a move if we're expecting one
        if moves_expected > 0 and _could_be_move(tok, board):
            san, issue = _resolve_move(tok, board)
            if san:
                if current_comment:
                    commentary.append(' '.join(current_comment))
                    current_comment = []
                else:
                    commentary.append('')

                pure_san = san.rstrip('!?')
                board.push_san(pure_san)
                moves.append(san)
                moves_expected -= 1
                commentary_depth = 0
                if issue:
                    issue['move_index'] = len(moves) - 1
                    issues.append(issue)
                i += 1
                continue

        # Not a move (or not expecting one) — commentary
        current_comment.append(tok)
        commentary_depth += 1
        # After several commentary tokens, stop expecting moves
        if commentary_depth > 2:
            moves_expected = 0

        i += 1

    # Final comment
    if current_comment:
        commentary.append(' '.join(current_comment))

    # Pad commentary to match moves length
    while len(commentary) < len(moves):
        commentary.append('')

    return moves, commentary, issues


def _tokenize_game_text(text: str) -> list[str]:
    """Split game text into tokens, keeping move-like sequences together."""
    text = text.replace('\u00a0', ' ')  # NBSP

    # Normalize bullets to dots for move numbers: "3•" → "3.", "4 •••" → "4..."
    text = re.sub(r'(\d{1,3})\s*•••', r'\1...', text)
    text = re.sub(r'(\d{1,3})•', r'\1.', text)
    text = text.replace('•••', '...')
    text = re.sub(r'\.\.\.(?=[a-h])', '... ', text)

    # Fix 'l' (lowercase L) used as '1' in move numbers: "l.d4" → "1.d4", "ll.Rd1" → "11.Rd1"
    text = re.sub(r'\bl(\.\S)', r'1\1', text)
    text = re.sub(r'\b(\d)l\.', r'\g<1>1.', text)
    text = re.sub(r'\bll\.', '11.', text)

    # Split stuck-together tokens where a move runs into a move number:
    # "g63.Nf3" → "g6 3.Nf3", "e612." → "e6 12."
    text = re.sub(r'([a-h][1-8])(\d{1,3}\.)', r'\1 \2', text)

    tokens = []
    raw_tokens = text.split()

    for tok in raw_tokens:
        # Keep bare move numbers as-is: "12." or "12..."
        if re.match(r'^\d{1,3}\.\.?\.*$', tok):
            tokens.append(tok)
            continue
        # Split move number from following move: "12.e4" → "12." + "e4"
        # Also: "12...e5" → "12..." + "e5"
        mn = re.match(r'^(\d{1,3}\.\.?\.)(.+)$', tok)
        if mn:
            tokens.append(mn.group(1))
            tokens.append(mn.group(2))
            continue
        mn = re.match(r'^(\d{1,3}\.)(.+)$', tok)
        if mn:
            tokens.append(mn.group(1))
            tokens.append(mn.group(2))
            continue
        tokens.append(tok)

    return tokens


def _could_be_move(tok: str, board: chess.Board) -> bool:
    """Quick heuristic: does this token potentially contain a chess move?"""
    if len(tok) > 15:
        return False
    if CASTLING_RE.match(tok):
        return True
    # Contains a destination square (file+rank)
    if DEST_SQUARE_RE.search(tok):
        return True
    # Single file letter (may be an incomplete garbled move like "f" for "Nf6")
    stripped = tok.rstrip('!?,.:;')
    if len(stripped) == 1 and stripped in 'abcdefgh':
        return True
    # Two-char file+rank pawn move
    if re.match(r'^[a-h][1-8]', stripped):
        return True
    return False


def _resolve_move(tok: str, board: chess.Board) -> tuple[str | None, dict | None]:
    """
    Try to interpret a garbled token as a legal chess move.

    Strategy:
      1. Try parsing as-is (standard SAN)
      2. Try castling normalization
      3. Extract destination square, find matching legal moves
      4. Handle completely missing piece symbols
      5. Handle incomplete tokens (missing rank digit)
      6. Use disambiguation hints from the token if multiple matches
    """
    annotation = ''
    clean = tok.rstrip(',.:;')
    while clean and clean[-1] in ANNOTATION_CHARS:
        annotation = clean[-1] + annotation
        clean = clean[:-1]

    # 1. Direct parse
    try:
        board.parse_san(clean)
        return clean + annotation, None
    except (chess.InvalidMoveError, chess.IllegalMoveError, chess.AmbiguousMoveError):
        pass

    # 2. Castling
    castle = _try_castling(clean, board)
    if castle:
        return castle + annotation, None

    # 3. Find destination square in token
    dest_match = DEST_SQUARE_RE.search(clean)

    if dest_match:
        result = _resolve_with_dest(clean, dest_match, board)
        if result:
            return result[0] + annotation, result[1]

    # 4. Incomplete token — single file letter like "f" (from garbled "Nf6")
    stripped = clean
    for c in clean:
        if c in 'abcdefgh':
            stripped = c
            break
    if len(stripped) == 1 and stripped in 'abcdefgh':
        result = _resolve_incomplete_file(stripped, board)
        if result:
            return result[0] + annotation, result[1]

    # 5. Try extracting just the last file+rank or x+file+rank pattern
    last_sq = re.search(r'(x?)([a-h])([1-8])\s*$', clean)
    if last_sq and last_sq != dest_match:
        result = _resolve_with_dest(clean, last_sq, board)
        if result:
            return result[0] + annotation, result[1]

    return None, None


def _resolve_with_dest(clean: str, dest_match: re.Match,
                       board: chess.Board) -> tuple[str, dict | None] | None:
    """Resolve a move given a known destination square match."""
    is_capture = dest_match.group(1) == 'x'
    dest_file = dest_match.group(2)
    dest_rank = dest_match.group(3)
    dest_square = chess.parse_square(dest_file + dest_rank)

    prefix = clean[:dest_match.start()]
    suffix = clean[dest_match.end():]

    promo = ''
    promo_match = re.match(r'=?([QRBN])', suffix)
    if promo_match:
        promo = '=' + promo_match.group(1)

    candidates = []
    for legal in board.legal_moves:
        if legal.to_square == dest_square:
            san = board.san(legal)
            candidates.append((legal, san))

    if not candidates:
        return None

    if len(candidates) == 1:
        return candidates[0][1], None

    # --- Disambiguation ---

    # Check prefix for disambiguation file/rank
    disambig_file = None
    disambig_rank = None
    for c in prefix:
        if c in 'abcdefgh' and c != dest_file:
            disambig_file = c
        elif c in '12345678' and c != dest_rank:
            disambig_rank = c

    narrowed = list(candidates)
    if disambig_file:
        narrowed = [(m, s) for m, s in narrowed
                     if chess.square_file(m.from_square) == ord(disambig_file) - ord('a')]
    if disambig_rank:
        narrowed = [(m, s) for m, s in narrowed
                     if chess.square_rank(m.from_square) == int(disambig_rank) - 1]

    if is_capture:
        cap = [(m, s) for m, s in (narrowed or candidates) if board.is_capture(m)]
        if cap:
            narrowed = cap

    if promo:
        piece_map = {'Q': chess.QUEEN, 'R': chess.ROOK, 'B': chess.BISHOP, 'N': chess.KNIGHT}
        promo_piece = piece_map.get(promo[-1])
        if promo_piece:
            p = [(m, s) for m, s in (narrowed or candidates) if m.promotion == promo_piece]
            if p:
                narrowed = p

    if len(narrowed) == 1:
        return narrowed[0][1], None

    pool = narrowed if narrowed else candidates
    has_prefix = bool(prefix.strip())

    # If the token starts with a file letter followed by 'x' (e.g. "cxd5"),
    # this is a pawn capture — prefer the pawn.
    pawn_capture_prefix = re.match(r'^([a-h])x', clean)
    if pawn_capture_prefix:
        from_file = ord(pawn_capture_prefix.group(1)) - ord('a')
        pawn_caps = [(m, s) for m, s in pool
                     if board.piece_at(m.from_square).piece_type == chess.PAWN
                     and chess.square_file(m.from_square) == from_file]
        if len(pawn_caps) == 1:
            return pawn_caps[0][1], None

    # Prefix has non-chess chars → garbled piece symbol → prefer piece moves
    if has_prefix and not pawn_capture_prefix:
        piece_moves = [(m, s) for m, s in pool
                       if board.piece_at(m.from_square).piece_type != chess.PAWN]
        if len(piece_moves) == 1:
            return piece_moves[0][1], None
        if piece_moves:
            pool = piece_moves

    if len(pool) == 1:
        return pool[0][1], None

    # Fall back: pick first, log issue
    return pool[0][1], _make_issue(
        'ambiguous', clean, board,
        f"Ambiguous: {[s for _, s in pool]}, picked {pool[0][1]}")


def _resolve_incomplete_file(file_char: str, board: chess.Board) -> tuple[str, dict | None] | None:
    """
    Handle a token that is just a file letter (e.g. "f" from garbled "Nf6").
    Try all legal moves whose destination is on that file.
    """
    file_idx = ord(file_char) - ord('a')
    candidates = []
    for legal in board.legal_moves:
        if chess.square_file(legal.to_square) == file_idx:
            san = board.san(legal)
            candidates.append((legal, san))

    if not candidates:
        return None

    if len(candidates) == 1:
        return candidates[0][1], _make_issue(
            'inferred_incomplete', file_char, board,
            f"Single match for file '{file_char}': {candidates[0][1]}")

    # Prefer piece moves (the piece symbol was stripped, leaving just the file)
    piece_moves = [(m, s) for m, s in candidates
                   if board.piece_at(m.from_square).piece_type != chess.PAWN]
    if len(piece_moves) == 1:
        return piece_moves[0][1], _make_issue(
            'inferred_incomplete', file_char, board,
            f"Inferred piece move for file '{file_char}': {piece_moves[0][1]}")

    # Multiple matches — can't resolve
    return None


def _try_castling(tok: str, board: chess.Board) -> str | None:
    normalized = tok.replace('0', 'O').replace('o', 'O')
    if re.match(r'^O-O-O', normalized):
        try:
            board.parse_san('O-O-O')
            return 'O-O-O'
        except (chess.InvalidMoveError, chess.IllegalMoveError):
            pass
    elif re.match(r'^O-O', normalized):
        try:
            board.parse_san('O-O')
            return 'O-O'
        except (chess.InvalidMoveError, chess.IllegalMoveError):
            pass
    return None


def _make_issue(kind: str, token: str, board: chess.Board, detail: str) -> dict:
    return {
        'kind': kind,
        'token': token,
        'fen': board.fen(),
        'move_number': board.fullmove_number,
        'turn': 'white' if board.turn == chess.WHITE else 'black',
        'detail': detail,
    }


# ---------------------------------------------------------------------------
#  Match EPUB games to PGN databases
# ---------------------------------------------------------------------------

def match_game(game: dict, db_index: dict) -> dict | None:
    """Try to find this game in the PGN database index."""
    w = game['white_last'].lower()
    b = game['black_last'].lower()
    yr = game['year']

    # Exact match
    key = (w, b, yr)
    if key in db_index:
        return db_index[key]

    # Try reversed (in case book lists Black first for some games)
    key_rev = (b, w, yr)
    if key_rev in db_index:
        return db_index[key_rev]

    return None


# ---------------------------------------------------------------------------
#  Commentary extraction
# ---------------------------------------------------------------------------

def extract_commentary_for_db_game(game_text: str, moves: list[str]) -> list[str]:
    """
    Given the EPUB game text and clean moves (from DB), extract commentary
    by scanning for move-number anchors and capturing text between them.

    Returns commentary[i] = annotation text after move i.
    """
    commentary = [''] * len(moves)

    # Split text into segments by finding move number patterns
    # Each segment starts with a move number and contains moves + commentary
    segments = _split_into_move_segments(game_text)

    # Match segments to moves using move numbers
    move_idx = 0
    for seg in segments:
        seg_num = seg.get('move_num')
        seg_text = seg.get('commentary', '').strip()
        if not seg_text:
            continue

        # Find which move this commentary belongs to
        # The commentary after a segment belongs to the LAST move in that segment
        if seg_num is not None:
            # Find the move index for this move number
            # Move number N corresponds to moves at index (N-1)*2 (White) and (N-1)*2+1 (Black)
            target_white = (seg_num - 1) * 2
            target_black = target_white + 1

            # Attach to the last move referenced in this segment
            if seg.get('is_black_cont'):
                target = target_black
            else:
                # Segment has White + Black moves, attach after Black
                target = target_black if target_black < len(moves) else target_white

            if 0 <= target < len(moves):
                commentary[target] = _clean_commentary(seg_text)
                move_idx = target + 1

    return commentary


def _split_into_move_segments(text: str) -> list[dict]:
    """
    Split game text into segments. Each segment is bounded by
    main-line move numbers (e.g. "12." or "12...").
    """
    # Find all move number positions
    move_num_pattern = re.compile(
        r'(?:^|\s)(\d{1,3})\.(\.\.)?'
        r'|(?:^|\s)(\d{1,3})•••'
        r'|(?:^|\s)(\d{1,3})\.\.\.'
    )

    positions = []
    for m in move_num_pattern.finditer(text):
        num = m.group(1) or m.group(3) or m.group(4)
        is_black = (m.group(2) is not None) or (m.group(3) is not None) or (m.group(4) is not None)
        positions.append({
            'start': m.start(),
            'end': m.end(),
            'move_num': int(num),
            'is_black_cont': is_black,
        })

    if not positions:
        return [{'move_num': None, 'commentary': text}]

    segments = []
    for i, pos in enumerate(positions):
        end = positions[i + 1]['start'] if i + 1 < len(positions) else len(text)
        seg_text = text[pos['end']:end]

        # Extract commentary: skip move-like tokens, keep prose
        commentary = _extract_prose(seg_text)

        segments.append({
            'move_num': pos['move_num'],
            'is_black_cont': pos['is_black_cont'],
            'commentary': commentary,
        })

    return segments


def _extract_prose(text: str) -> str:
    """
    From a mixed text segment, extract just the prose commentary,
    filtering out garbled move tokens and diagram noise.
    """
    lines = text.split('\n')
    prose_parts = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        # Skip lines that are entirely move tokens (no substantial words)
        words = line.split()
        english_words = sum(1 for w in words if len(w) > 2 and w.isalpha())
        total_words = len(words)
        if total_words > 0 and english_words / total_words >= 0.3:
            prose_parts.append(line)

    return ' '.join(prose_parts)


def _clean_commentary(text: str) -> str:
    """Clean up commentary text for PGN annotation."""
    text = re.sub(r'\s+', ' ', text).strip()
    # Remove PGN-illegal chars
    text = text.replace('{', '(').replace('}', ')')
    text = text.strip(',.:;')
    return text.strip()


# ---------------------------------------------------------------------------
#  PGN output
# ---------------------------------------------------------------------------

def build_pgn_game(game_info: dict, moves: list[str],
                   commentary: list[str], matched_db: dict | None) -> str:
    """Build a PGN string for one game."""
    lines = []

    # Headers
    event = game_info.get('event', '?')
    white = game_info.get('white', '?')
    black = game_info.get('black', '?')
    year = game_info.get('year', '????.??.??')
    eco = game_info.get('eco', '?')

    if matched_db:
        h = matched_db['headers']
        lines.append(f'[Event "{h.get("Event", event)}"]')
        lines.append(f'[Site "{h.get("Site", "?")}"]')
        lines.append(f'[Date "{h.get("Date", year)}"]')
        lines.append(f'[Round "{h.get("Round", "?")}"]')
        lines.append(f'[White "{h.get("White", white)}"]')
        lines.append(f'[Black "{h.get("Black", black)}"]')
        lines.append(f'[Result "{h.get("Result", "*")}"]')
        if h.get('WhiteElo'):
            lines.append(f'[WhiteElo "{h["WhiteElo"]}"]')
        if h.get('BlackElo'):
            lines.append(f'[BlackElo "{h["BlackElo"]}"]')
        lines.append(f'[ECO "{h.get("ECO", eco)}"]')
    else:
        date = f'{year}.??.??' if year else '????.??.??'
        lines.append(f'[Event "{event}"]')
        lines.append(f'[Site "?"]')
        lines.append(f'[Date "{date}"]')
        lines.append(f'[Round "?"]')
        lines.append(f'[White "{white}"]')
        lines.append(f'[Black "{black}"]')
        lines.append(f'[Result "*"]')
        lines.append(f'[ECO "{eco}"]')

    lines.append(f'[Annotator "Wojo\'s Weapons Vol.3"]')
    lines.append('')

    # Moves with annotations
    move_parts = []
    for i, san in enumerate(moves):
        if i % 2 == 0:
            move_num = i // 2 + 1
            move_parts.append(f'{move_num}.{san}')
        else:
            move_parts.append(san)

        if i < len(commentary) and commentary[i]:
            move_parts.append('{' + commentary[i] + '}')

    # Word-wrap the moves
    move_text = ' '.join(move_parts)

    # Add result
    if matched_db:
        result = matched_db['headers'].get('Result', '*')
    else:
        result_m = re.search(r'(1-0|0-1|1/2-1/2)', game_info.get('game_text', ''))
        result = result_m.group(1) if result_m else '*'

    move_text += ' ' + result

    # Wrap at ~80 chars
    wrapped = _wrap_pgn(move_text, 80)
    lines.append(wrapped)
    lines.append('')

    return '\n'.join(lines)


def _wrap_pgn(text: str, width: int) -> str:
    words = text.split()
    lines = []
    current = ''
    for w in words:
        if current and len(current) + 1 + len(w) > width:
            lines.append(current)
            current = w
        else:
            current = current + ' ' + w if current else w
    if current:
        lines.append(current)
    return '\n'.join(lines)


# ---------------------------------------------------------------------------
#  Matched-game move parsing from PGN database
# ---------------------------------------------------------------------------

def parse_pgn_moves(move_text: str) -> list[str]:
    """Parse a clean PGN move string into a list of SAN moves."""
    # Remove result
    move_text = re.sub(r'(1-0|0-1|1/2-1/2|\*)\s*$', '', move_text)
    # Remove move numbers
    move_text = re.sub(r'\d+\.+', '', move_text)
    # Remove comments
    move_text = re.sub(r'\{[^}]*\}', '', move_text)
    # Remove variations
    move_text = re.sub(r'\([^)]*\)', '', move_text)

    tokens = move_text.split()
    return [t for t in tokens if t and not RESULT_RE.match(t)]


# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description='Extract games from Wojo EPUB')
    parser.add_argument('epub', help='Path to the EPUB file')
    parser.add_argument('--pgn-db', nargs='*', default=[],
                        help='PGN files/zips to use for move matching')
    parser.add_argument('--output', '-o', default='output',
                        help='Output directory')
    parser.add_argument('--verbose', '-v', action='store_true')
    args = parser.parse_args()

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Load PGN databases
    print(f"Loading PGN databases...")
    db_index = load_pgn_databases(args.pgn_db)
    print(f"  Indexed {len(db_index)} game entries")

    # Extract text from EPUB
    print(f"Extracting text from EPUB...")
    chapters = extract_epub_text(args.epub)
    print(f"  {len(chapters)} chapters extracted")

    # Segment into games
    print(f"Segmenting games...")
    games = segment_games(chapters)
    print(f"  {len(games)} games found")

    # Process each game
    all_pgn = []
    all_issues = []
    stats = {'matched': 0, 'parsed': 0, 'failed': 0, 'total_moves': 0}

    for gi, game in enumerate(games):
        label = f"[{game['eco']}] {game['white']} vs {game['black']} ({game['year']})"
        if args.verbose:
            print(f"\n{'='*60}")
            print(f"Game {gi+1}: {label}")

        # Try database match
        db_match = match_game(game, db_index)

        if db_match:
            # Use clean PGN moves
            db_moves = parse_pgn_moves(db_match['moves'])
            if args.verbose:
                print(f"  MATCHED in database ({len(db_moves)} moves)")

            # Extract commentary from EPUB text
            commentary = extract_commentary_for_db_game(game['game_text'], db_moves)
            pgn_text = build_pgn_game(game, db_moves, commentary, db_match)
            all_pgn.append(pgn_text)
            stats['matched'] += 1
            stats['total_moves'] += len(db_moves)
        else:
            # Parse from EPUB text
            if args.verbose:
                print(f"  No database match — parsing from text...")

            moves, commentary, issues = parse_game_moves(
                game['game_text'], verbose=args.verbose)

            if moves:
                pgn_text = build_pgn_game(game, moves, commentary, None)
                all_pgn.append(pgn_text)
                stats['parsed'] += 1
                stats['total_moves'] += len(moves)
                if args.verbose:
                    print(f"  Parsed {len(moves)} moves, {len(issues)} issues")
            else:
                stats['failed'] += 1
                if args.verbose:
                    print(f"  FAILED to parse any moves")

            for iss in issues:
                iss['game'] = label
                all_issues.append(iss)

        print(f"  [{gi+1}/{len(games)}] {label} — "
              f"{'DB' if db_match else f'{len(moves) if not db_match else 0} moves parsed'}")

    # Write outputs
    pgn_path = output_dir / 'games.pgn'
    with open(pgn_path, 'w') as f:
        f.write('\n'.join(all_pgn))
    print(f"\nWrote {len(all_pgn)} games to {pgn_path}")

    errors_path = output_dir / 'errors.json'
    with open(errors_path, 'w') as f:
        json.dump(all_issues, f, indent=2)
    print(f"Wrote {len(all_issues)} issues to {errors_path}")

    print(f"\n{'='*60}")
    print(f"Summary:")
    print(f"  Total games:        {len(games)}")
    print(f"  Matched from DB:    {stats['matched']}")
    print(f"  Parsed from text:   {stats['parsed']}")
    print(f"  Failed:             {stats['failed']}")
    print(f"  Total moves:        {stats['total_moves']}")


if __name__ == '__main__':
    main()
