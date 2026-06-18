#!/usr/bin/env python3
"""Parse OCR'd chess book text into PGN with deterministic move correction.

Reads the JSON produced by ocr_pages.py, extracts games, corrects garbled
piece-figurine OCR using python-chess legal-move validation, and writes:
  1. A .pgn file with all extracted games and inline annotations.
  2. An errors.json log of every place the script wasn't fully confident,
     so an LLM can review and resolve them afterward.

Usage:
    python build_pgn.py ocr_output.json [--out-dir output/]
"""

import argparse
import chess
import json
import re
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Optional, List, Tuple


# ---------------------------------------------------------------------------
# OCR substitution tables — learned from the Wojo's Weapons scan
# ---------------------------------------------------------------------------

# Figurine piece symbols → garbled OCR characters
PIECE_TO_OCR = {
    "N": set("AD04"),
    "B": set("2&8"),
    "R": set("28Z"),
    "Q": set("WY%"),
    "K": set("©"),
}

# Reverse: garbled char → set of pieces it could represent
OCR_TO_PIECES: dict[str, set[str]] = {}
for _piece, _chars in PIECE_TO_OCR.items():
    for _c in _chars:
        OCR_TO_PIECES.setdefault(_c, set()).add(_piece)

# Non-piece character substitutions observed in this scan
CHAR_SUBS = {
    "¢": "g",
    "©": "K",  # when it appears as part of a move token
}

# Characters that are pure OCR artifacts (delete them)
ARTIFACT_CHARS = set("\\\"'`")

# Known OCR equivalences (char_from_ocr, char_it_actually_is)
OCR_EQUIV_PAIRS = set()
for _p, _cs in PIECE_TO_OCR.items():
    for _c in _cs:
        OCR_EQUIV_PAIRS.add((_c, _p))
OCR_EQUIV_PAIRS |= {
    ("2", "g"),  # file-g often scans as 2 in this book
    ("¢", "g"),
    ("l", "1"),  # lowercase L → digit 1
    ("O", "0"),  # letter O ↔ digit 0
    ("0", "O"),
    ("S", "5"),  # rare
    ("e", "K"),  # king symbol sometimes OCRs as lowercase e
    ("h", "K"),  # or as h
    ("M", "R"),  # rook symbol occasionally
    (",", "."),  # comma ↔ period in move numbers
    ("£", "R"),  # pound sign → rook
    ("#", "R"),  # hash → rook (in some contexts)
    ("®", "N"),  # registered symbol → knight
}

# Page-header patterns to strip
PAGE_HEADER_RE = re.compile(
    r"^(CHAPTER\s+\d+|THE\s+.{5,50}DEFENSE|WOJO'?S?\s+WEAPONS"
    r"|WHITE'?S?\s+.{5,40}PUSH|BLACK'?S?\s+.{5,40}FALLS"
    r"|chesstouring\.com)\s*$",
    re.IGNORECASE,
)

# Game header patterns
PLAYER_RE = re.compile(
    r"^([A-Z][a-z]+(?:[-'][A-Z]?[a-z]+)*,\s+[A-Z][a-z]+(?:\s+[A-Z]?[a-z]+)*)"
    r"(?:\s+\((\d{3,4})\))?\s*$"
)
ECO_EVENT_RE = re.compile(
    r"^\[([A-E]\d{2})\]\s+(.+?)\s+(\d{4})\s*$"
)

# Move number regex: "14." or "14..." (with possible OCR dots)
MOVE_NUM_RE = re.compile(r"(\d{1,3})(\.{3}|\.)")

# Result patterns
RESULT_RE = re.compile(r"^(1-0|0-1|1/2-1/2|½[–-]½|\*)$")

# A token that could plausibly be a chess move (pre-filter)
MOVE_TOKEN_RE = re.compile(
    r"^[A-Za-z0-9&%©]{0,3}x?[a-h]?[1-8]"  # piece+square
    r"(?:=[A-Za-z0-9&%©])?"                  # promotion
    r"[+#]?"                                  # check/mate
    r"[!?]{0,2}$"                             # annotation glyphs
)

CASTLING_RE = re.compile(r"^[0O]-[0O](-[0O])?[+#]?$", re.IGNORECASE)


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class GameHeader:
    white: str = "?"
    black: str = "?"
    white_elo: str = ""
    black_elo: str = ""
    eco: str = ""
    event: str = "?"
    date: str = "????.??.??"
    result: str = "*"

    def pgn_headers(self) -> str:
        lines = [
            f'[Event "{self.event}"]',
            f'[Site "?"]',
            f'[Date "{self.date}"]',
            f'[White "{self.white}"]',
            f'[Black "{self.black}"]',
            f'[Result "{self.result}"]',
        ]
        if self.eco:
            lines.append(f'[ECO "{self.eco}"]')
        if self.white_elo:
            lines.append(f'[WhiteElo "{self.white_elo}"]')
        if self.black_elo:
            lines.append(f'[BlackElo "{self.black_elo}"]')
        return "\n".join(lines)


@dataclass
class ParseIssue:
    """One place where the script needs human/LLM review."""
    game_id: int
    game_label: str
    page: int
    half_move: int
    move_number: int
    color: str  # "white" | "black"
    raw_token: str
    fen: str
    issue: str  # "ambiguous" | "no_match" | "diagram_overlap" | ...
    candidates: list = field(default_factory=list)
    best_guess: str = ""
    confidence: float = 0.0
    context_before: str = ""
    context_after: str = ""


@dataclass
class GameNode:
    """One half-move in the extracted game."""
    san: str
    comment: str = ""
    is_guess: bool = False


@dataclass
class ExtractedGame:
    header: GameHeader
    moves: list  # List[GameNode]
    issues: list  # List[ParseIssue]
    raw_text: str = ""
    start_page: int = 0


# ---------------------------------------------------------------------------
# Text cleaning
# ---------------------------------------------------------------------------

def clean_raw_text(pages: dict[str, str]) -> list[tuple[int, str]]:
    """Clean OCR text per page. Returns [(page_num, cleaned_text), ...]."""
    result = []
    for page_str, text in sorted(pages.items(), key=lambda x: int(x[0])):
        page_num = int(page_str)
        lines = text.split("\n")
        cleaned_lines = []
        for line in lines:
            stripped = line.strip()
            if not stripped:
                cleaned_lines.append("")
                continue
            # Strip page headers (chapter titles, section names)
            if PAGE_HEADER_RE.match(stripped):
                continue
            # Strip bare page numbers at the bottom
            if re.match(r"^\d{1,3}$", stripped):
                continue
            # Strip "chesstouring.com" watermark pages
            if stripped.lower() == "chesstouring.com":
                continue
            cleaned_lines.append(stripped)
        result.append((page_num, "\n".join(cleaned_lines)))
    return result


def is_diagram_line(line: str) -> bool:
    """Heuristic: is this line likely garbage from a chess diagram?"""
    s = line.strip()
    if not s or len(s) > 40:
        return False
    # Lines with move number patterns (1. or 15... etc.) are chess notation
    if re.search(r"\d+\.{1,3}", s):
        return False
    # Lines with castling notation
    if re.search(r"[0O]-[0O]", s, re.IGNORECASE):
        return False
    # Lines with result patterns
    if re.search(r"[01]-[01]|1/2-1/2", s):
        return False
    alpha = sum(1 for c in s if c.isalpha())
    total = len(s.replace(" ", "")) or 1
    # Diagram garbage has lots of symbols and short nonsense
    if alpha / total < 0.4 and len(s) < 30:
        return True
    # Lines that are mostly uppercase gibberish with no spaces
    words = s.split()
    if all(len(w) <= 4 for w in words) and len(words) >= 2:
        real_words = sum(1 for w in words if w.lower() in COMMON_WORDS)
        if real_words == 0 and len(s) < 25:
            return True
    return False


# Minimal word list — just enough to distinguish prose from diagram garbage
COMMON_WORDS = {
    "the", "a", "an", "is", "was", "are", "were", "be", "been", "being",
    "have", "has", "had", "do", "does", "did", "will", "would", "could",
    "should", "may", "might", "can", "shall", "must", "need", "dare",
    "to", "of", "in", "for", "on", "with", "at", "by", "from", "as",
    "into", "through", "during", "before", "after", "above", "below",
    "between", "under", "over", "up", "down", "out", "off", "then",
    "than", "so", "if", "or", "and", "but", "nor", "not", "no", "yes",
    "it", "its", "he", "she", "they", "we", "you", "me", "him", "her",
    "us", "them", "my", "his", "our", "your", "their", "this", "that",
    "these", "those", "here", "there", "where", "when", "how", "what",
    "which", "who", "whom", "whose", "why", "all", "each", "every",
    "both", "few", "more", "most", "other", "some", "any", "such",
    "only", "same", "just", "also", "very", "still", "even", "too",
    "white", "black", "king", "queen", "rook", "bishop", "knight", "pawn",
    "move", "moves", "play", "plays", "played", "game", "games",
    "position", "square", "piece", "pieces", "attack", "defense",
    "check", "mate", "draw", "win", "wins", "won", "lose", "lost",
    "after", "before", "better", "best", "worse", "worst",
    "now", "first", "last", "next", "new", "old", "good", "bad",
    "side", "file", "rank", "diagonal", "center", "wing", "flank",
}


def strip_diagram_blocks(text: str) -> str:
    """Remove blocks of 3+ consecutive diagram-garbage lines."""
    lines = text.split("\n")
    out = []
    garbage_run = []
    for line in lines:
        if is_diagram_line(line):
            garbage_run.append(line)
        else:
            if len(garbage_run) >= 2:
                # Drop the whole garbage block
                pass
            else:
                out.extend(garbage_run)
            garbage_run = []
            out.append(line)
    # Don't forget trailing
    if len(garbage_run) < 2:
        out.extend(garbage_run)
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Game segmentation
# ---------------------------------------------------------------------------

def find_game_headers(text: str, page_num: int) -> list[tuple[int, GameHeader]]:
    """Find game headers in text. Returns [(char_offset, GameHeader), ...]."""
    lines = text.split("\n")
    headers = []
    i = 0
    while i < len(lines) - 1:
        m_white = PLAYER_RE.match(lines[i].strip())
        if m_white:
            # Look ahead for black player and ECO
            m_black = None
            m_eco = None
            for j in range(i + 1, min(i + 5, len(lines))):
                if not m_black:
                    m_black = PLAYER_RE.match(lines[j].strip())
                    if m_black:
                        continue
                if not m_eco:
                    m_eco = ECO_EVENT_RE.match(lines[j].strip())
                    if m_eco:
                        break

            if m_black and m_eco:
                offset = sum(len(lines[k]) + 1 for k in range(i))
                hdr = GameHeader(
                    white=m_white.group(1),
                    black=m_black.group(1),
                    white_elo=m_white.group(2) or "",
                    black_elo=m_black.group(2) or "",
                    eco=m_eco.group(1),
                    event=m_eco.group(2),
                    date=m_eco.group(3) + ".??.??",
                )
                headers.append((offset, hdr))
                i = j + 1
                continue
        i += 1
    return headers


# ---------------------------------------------------------------------------
# Move correction engine
# ---------------------------------------------------------------------------

def clean_move_token(token: str) -> str:
    """Remove known OCR artifacts from a move token."""
    out = []
    for ch in token:
        if ch in ARTIFACT_CHARS:
            continue
        out.append(CHAR_SUBS.get(ch, ch))
    result = "".join(out)
    # Strip trailing punctuation that isn't chess annotation
    result = result.rstrip(",.:;")
    return result


def strip_annotations(token: str) -> tuple[str, str]:
    """Split trailing annotation glyphs (!? etc.) from a move token."""
    m = re.match(r"^(.+?)([!?]{1,2})$", token)
    if m:
        return m.group(1), m.group(2)
    return token, ""


def normalize_castling(token: str) -> Optional[str]:
    """Try to read token as castling. Returns 'O-O' / 'O-O-O' or None."""
    t = token.upper().replace("0", "O")
    if t in ("O-O", "O-O+", "O-O#"):
        return t
    if t in ("O-O-O", "O-O-O+", "O-O-O#"):
        return t
    return None


def fuzzy_score(token: str, san: str) -> float:
    """Score how likely `token` is an OCR rendering of `san`. Higher = better."""
    if not token or not san:
        return -100

    # Normalize lengths by trying to align
    if len(token) == len(san):
        score = 0.0
        for t, s in zip(token, san):
            if t == s:
                score += 3.0
            elif t.lower() == s.lower():
                score += 2.5
            elif (t, s) in OCR_EQUIV_PAIRS:
                score += 1.5
            else:
                score -= 2.0
        return score

    # Length mismatch: penalize but still try
    # Try removing each character from the longer string and re-score
    if abs(len(token) - len(san)) == 1:
        longer, shorter = (token, san) if len(token) > len(san) else (san, token)
        best = -100.0
        for skip in range(len(longer)):
            reduced = longer[:skip] + longer[skip + 1:]
            s = fuzzy_score_same_len(reduced, shorter)
            best = max(best, s - 1.0)  # penalty for needing a deletion
        return best

    if abs(len(token) - len(san)) == 2:
        return -50  # too different

    return -100


def fuzzy_score_same_len(a: str, b: str) -> float:
    """Score two same-length strings for OCR equivalence."""
    score = 0.0
    for ca, cb in zip(a, b):
        if ca == cb:
            score += 3.0
        elif ca.lower() == cb.lower():
            score += 2.5
        elif (ca, cb) in OCR_EQUIV_PAIRS:
            score += 1.5
        else:
            score -= 2.0
    return score


def generate_ocr_variants(token: str) -> list[str]:
    """Generate all plausible readings of a garbled OCR token.

    For each character position, substitutes known OCR equivalences and
    returns all combinations (capped for sanity).
    """
    # Build per-position options
    char_options: list[set[str]] = []
    for ch in token:
        opts = {ch}
        for ocr_ch, real_ch in OCR_EQUIV_PAIRS:
            if ch == ocr_ch:
                opts.add(real_ch)
        char_options.append(opts)

    # Generate all combos if feasible
    from itertools import product

    total = 1
    for o in char_options:
        total *= len(o)
        if total > 500:
            break

    results: list[str] = []
    if total <= 500:
        for combo in product(*char_options):
            results.append("".join(combo))
    else:
        # Fallback: original + single-position swaps
        results.append(token)
        for i, opts in enumerate(char_options):
            for ch in opts:
                if ch != token[i]:
                    results.append(token[:i] + ch + token[i + 1 :])
    return results


def try_correct_move(
    board: chess.Board,
    raw_token: str,
    page: int,
    move_num: int,
    color: str,
    game_id: int,
    game_label: str,
    context_before: str = "",
    context_after: str = "",
) -> tuple[Optional[str], Optional[ParseIssue]]:
    """Try to match a garbled OCR token to a legal move on `board`.

    Returns (corrected_san_or_None, issue_or_None).
    Strategy:
      1. Direct parse
      2. Castling normalization
      3. OCR variant generation — try all character substitutions
      4. Fuzzy match against legal moves
    """
    cleaned = clean_move_token(raw_token)
    cleaned_body, annotation = strip_annotations(cleaned)

    def _make_issue(issue_type, candidates, best, conf):
        return ParseIssue(
            game_id=game_id, game_label=game_label, page=page,
            half_move=board.fullmove_number * 2 - (
                1 if board.turn == chess.WHITE else 0
            ),
            move_number=move_num, color=color,
            raw_token=raw_token, fen=board.fen(),
            issue=issue_type, candidates=candidates,
            best_guess=best, confidence=conf,
            context_before=context_before, context_after=context_after,
        )

    # --- 1. Direct parse ---
    try:
        move = board.parse_san(cleaned_body)
        return board.san(move) + annotation, None
    except (ValueError, chess.InvalidMoveError, chess.IllegalMoveError):
        pass

    # --- 2. Castling ---
    castle = normalize_castling(cleaned_body)
    if castle:
        try:
            move = board.parse_san(castle)
            return board.san(move) + annotation, None
        except (ValueError, chess.InvalidMoveError, chess.IllegalMoveError):
            pass

    # --- 3. OCR variant generation ---
    # Generate all plausible character substitutions and test each as SAN.
    # Also try with 1 char removed (handles artifact insertions like "0Ac3"→"Nc3").
    variants = generate_ocr_variants(cleaned_body)

    # Also try removing each character (for inserted artifacts)
    for skip in range(len(cleaned_body)):
        reduced = cleaned_body[:skip] + cleaned_body[skip + 1 :]
        if len(reduced) >= 2:
            variants.extend(generate_ocr_variants(reduced))

    seen_san: dict[str, str] = {}  # san → variant that produced it
    for variant in variants:
        try:
            move = board.parse_san(variant)
            san = board.san(move)
            if san not in seen_san:
                seen_san[san] = variant
        except (ValueError, chess.InvalidMoveError, chess.IllegalMoveError):
            pass

    if len(seen_san) == 1:
        san = next(iter(seen_san))
        return san + annotation, None
    if len(seen_san) > 1:
        candidates = list(seen_san.keys())
        # Disambiguate: if the raw token's first char is an OCR piece char,
        # prefer the piece move over a pawn move. The figurine symbol's
        # existence means the original had a piece letter.
        first_raw = cleaned_body[0] if cleaned_body else ""
        if first_raw in OCR_TO_PIECES:
            piece_moves = [s for s in candidates if s[0] in "NBRQK"]
            pawn_moves = [s for s in candidates if s[0] in "abcdefgh"]
            if len(piece_moves) == 1:
                return piece_moves[0] + annotation, None
            if piece_moves and not pawn_moves:
                candidates = piece_moves
        if len(candidates) == 1:
            return candidates[0] + annotation, None
        return candidates[0] + annotation, _make_issue(
            "ambiguous_variant", candidates, candidates[0], 0.6,
        )

    # --- 4. Fuzzy match against all legal moves ---
    scored = []
    for move in board.legal_moves:
        san = board.san(move)
        s = fuzzy_score(cleaned_body, san)
        scored.append((s, san))
    scored.sort(key=lambda x: -x[0])

    if scored:
        best_score, best_san = scored[0]
        runner_up = scored[1][0] if len(scored) > 1 else -999

        if best_score >= 3.0 and best_score - runner_up >= 2.0:
            return best_san + annotation, _make_issue(
                "fuzzy_match", [s for _, s in scored[:5]], best_san, 0.7,
            )
        if best_score >= 1.0:
            return best_san + annotation, _make_issue(
                "low_confidence_fuzzy", [s for _, s in scored[:5]],
                best_san, 0.4,
            )

    # --- 5. Total failure ---
    return None, _make_issue(
        "no_match", [s for _, s in scored[:5]] if scored else [],
        "", 0.0,
    )


# ---------------------------------------------------------------------------
# Game text parser
# ---------------------------------------------------------------------------

def looks_like_move(token: str) -> bool:
    """Pre-filter: could this token plausibly be a chess move?"""
    if not token or len(token) > 10:
        return False
    cleaned = clean_move_token(token)
    # Also try l→1 substitution (OCR confuses lowercase L and digit 1)
    candidates = [cleaned]
    if "l" in cleaned and len(cleaned) <= 7:
        candidates.append(cleaned.replace("l", "1"))
    for c in candidates:
        if CASTLING_RE.match(c):
            return True
        body, _ = strip_annotations(c)
        if not body:
            continue
        if MOVE_TOKEN_RE.match(body):
            return True
        if len(body) <= 6 and re.search(r"[a-h][1-8]", body):
            return True
        if len(body) <= 3 and re.match(r"^[0-9][1-8]$", body):
            return True
    return False


def tokenize_game_text(text: str) -> list[dict]:
    """Break game text into a stream of typed tokens.

    Returns list of dicts with keys:
      type: "move_num_white" | "move_num_black" | "word" | "result"
              | "open_paren" | "close_paren"
      value: the raw string
      num: (for move_num types) the move number as int
    """
    tokens = []
    # Normalize whitespace
    text = re.sub(r"\s+", " ", text).strip()

    i = 0
    while i < len(text):
        # Skip whitespace
        if text[i] == " ":
            i += 1
            continue

        # Parentheses for variations
        if text[i] == "(":
            tokens.append({"type": "open_paren", "value": "("})
            i += 1
            continue
        if text[i] == ")":
            tokens.append({"type": "close_paren", "value": ")"})
            i += 1
            continue

        # Try to match a move number: "14." or "14..."
        m = re.match(r"(\d{1,3})(\.{3}|\.)", text[i:])
        if m:
            num = int(m.group(1))
            dots = m.group(2)
            typ = "move_num_black" if dots == "..." else "move_num_white"
            tokens.append({"type": typ, "value": m.group(0), "num": num})
            i += m.end()
            continue

        # Read a word/token (delimited by space or parens)
        j = i
        while j < len(text) and text[j] not in " ()":
            j += 1
        word = text[i:j]
        i = j

        # Check for result
        if RESULT_RE.match(word):
            tokens.append({"type": "result", "value": word})
            continue

        tokens.append({"type": "word", "value": word})

    return tokens


def parse_game_text(
    text: str,
    header: GameHeader,
    game_id: int,
    page: int,
) -> ExtractedGame:
    """Parse a single game's text into moves and comments.

    Uses board.fullmove_number and board.turn to decide whether a move
    number in the text is a main-line continuation or a commentary
    reference — this prevents analysis-line moves from corrupting the
    main board state.
    """
    game_label = f"{header.white} - {header.black}, {header.event}"
    tokens = tokenize_game_text(text)

    board = chess.Board()
    moves: list[GameNode] = []
    issues: list[ParseIssue] = []
    comment_buf: list[str] = []
    result = "*"

    def flush_comment() -> str:
        nonlocal comment_buf
        c = " ".join(comment_buf).strip()
        comment_buf = []
        return c

    def attach_comment(comment: str):
        if comment and moves:
            if moves[-1].comment:
                moves[-1].comment += " " + comment
            else:
                moves[-1].comment = comment

    def try_push_move(raw_token: str, move_num: int, color: str) -> bool:
        nonlocal board
        ctx_before = " ".join(m.san for m in moves[-3:]) if moves else ""

        san, issue = try_correct_move(
            board, raw_token, page, move_num, color,
            game_id, game_label, context_before=ctx_before,
        )
        if issue:
            issues.append(issue)

        if san is not None:
            body, annot = strip_annotations(san)
            try:
                board.push_san(body)
                comment = flush_comment()
                moves.append(GameNode(
                    san=san, comment=comment, is_guess=issue is not None,
                ))
                return True
            except (ValueError, chess.InvalidMoveError, chess.IllegalMoveError):
                issues.append(ParseIssue(
                    game_id=game_id, game_label=game_label, page=page,
                    half_move=board.fullmove_number,
                    move_number=move_num, color=color,
                    raw_token=raw_token, fen=board.fen(),
                    issue="correction_failed_on_push",
                    best_guess=san, confidence=0.0,
                ))
                return False
        else:
            comment = flush_comment()
            moves.append(GameNode(
                san=f"{{ERROR: {raw_token}}}",
                comment=comment, is_guess=True,
            ))
            return False

    def is_main_line_white(num: int) -> bool:
        """Is 'N.' a main-line White move for the current board?"""
        if board.turn != chess.WHITE:
            return False
        fm = board.fullmove_number
        return num == fm or num == fm + 1

    def is_main_line_black(num: int) -> bool:
        """Is 'N...' a main-line Black move for the current board?"""
        if board.turn != chess.BLACK:
            return False
        return num == board.fullmove_number

    i = 0
    while i < len(tokens):
        tok = tokens[i]

        if tok["type"] == "result":
            attach_comment(flush_comment())
            result = tok["value"]
            i += 1
            continue

        if tok["type"] == "open_paren":
            attach_comment(flush_comment())
            depth = 1
            var_tokens = []
            i += 1
            while i < len(tokens) and depth > 0:
                if tokens[i]["type"] == "open_paren":
                    depth += 1
                elif tokens[i]["type"] == "close_paren":
                    depth -= 1
                    if depth == 0:
                        i += 1
                        break
                var_tokens.append(tokens[i]["value"])
                i += 1
            var_text = " ".join(var_tokens)
            if moves:
                moves[-1].comment += f" ({var_text})"
            continue

        if tok["type"] == "close_paren":
            i += 1
            continue

        if tok["type"] == "move_num_white":
            num = tok["num"]
            if is_main_line_white(num):
                attach_comment(flush_comment())
                i += 1
                # Find the move token
                while i < len(tokens) and tokens[i]["type"] == "word":
                    if looks_like_move(tokens[i]["value"]):
                        break
                    comment_buf.append(tokens[i]["value"])
                    i += 1
                if (i < len(tokens) and tokens[i]["type"] == "word"
                        and looks_like_move(tokens[i]["value"])):
                    try_push_move(tokens[i]["value"], num, "white")
                    i += 1
                    # In compact notation, Black's reply follows immediately
                    if (i < len(tokens)
                            and tokens[i]["type"] == "word"
                            and looks_like_move(tokens[i]["value"])
                            and board.turn == chess.BLACK):
                        peek = (
                            i + 1 < len(tokens) and tokens[i + 1]["type"]
                            in ("move_num_white", "move_num_black", "result")
                        )
                        if peek or board.fullmove_number <= 20:
                            try_push_move(tokens[i]["value"], num, "black")
                            i += 1
                continue
            else:
                # Commentary reference — absorb as text
                comment_buf.append(tok["value"])
                i += 1
                continue

        if tok["type"] == "move_num_black":
            num = tok["num"]
            if is_main_line_black(num):
                attach_comment(flush_comment())
                i += 1
                while i < len(tokens) and tokens[i]["type"] == "word":
                    if looks_like_move(tokens[i]["value"]):
                        break
                    comment_buf.append(tokens[i]["value"])
                    i += 1
                if (i < len(tokens) and tokens[i]["type"] == "word"
                        and looks_like_move(tokens[i]["value"])):
                    try_push_move(tokens[i]["value"], num, "black")
                    i += 1
                continue
            else:
                comment_buf.append(tok["value"])
                i += 1
                continue

        if tok["type"] == "word":
            comment_buf.append(tok["value"])
            i += 1
            continue

        i += 1

    # Finalize
    attach_comment(flush_comment())
    header.result = result

    return ExtractedGame(
        header=header,
        moves=moves,
        issues=issues,
        raw_text=text[:500],
        start_page=page,
    )


# ---------------------------------------------------------------------------
# Full-text processing: combine pages, find games, parse each
# ---------------------------------------------------------------------------

def combine_and_segment(
    pages: list[tuple[int, str]],
) -> list[tuple[str, GameHeader, int]]:
    """Find all games across all pages.

    Returns [(game_text, header, start_page), ...]
    """
    # First pass: find game headers and their page numbers
    all_headers = []  # (page_num, char_offset_in_page, GameHeader)
    for page_num, text in pages:
        headers = find_game_headers(text, page_num)
        for offset, hdr in headers:
            all_headers.append((page_num, offset, hdr))

    if not all_headers:
        print("WARNING: No game headers found!")
        return []

    # Build game texts: from each header to the next
    # We need to track which pages belong to which game
    games = []
    page_dict = {pn: txt for pn, txt in pages}
    sorted_pages = sorted(pages, key=lambda x: x[0])

    for idx, (start_page, start_offset, hdr) in enumerate(all_headers):
        # Determine end boundary
        if idx + 1 < len(all_headers):
            end_page, end_offset, _ = all_headers[idx + 1]
        else:
            end_page = sorted_pages[-1][0] + 1
            end_offset = 0

        # Collect text for this game across pages
        game_text_parts = []
        for pn, ptxt in sorted_pages:
            if pn < start_page:
                continue
            if pn > end_page:
                break
            if pn == start_page and pn == end_page:
                game_text_parts.append(ptxt[start_offset:end_offset])
            elif pn == start_page:
                game_text_parts.append(ptxt[start_offset:])
            elif pn == end_page:
                game_text_parts.append(ptxt[:end_offset])
            else:
                game_text_parts.append(ptxt)

        game_text = "\n".join(game_text_parts)
        # Clean diagram blocks
        game_text = strip_diagram_blocks(game_text)
        games.append((game_text, hdr, start_page))

    return games


# ---------------------------------------------------------------------------
# PGN output
# ---------------------------------------------------------------------------

def game_to_pgn(game: ExtractedGame) -> str:
    """Format an ExtractedGame as a PGN string."""
    parts = [game.header.pgn_headers(), ""]

    line = []
    board = chess.Board()
    for i, node in enumerate(game.moves):
        if node.san.startswith("{ERROR"):
            line.append(node.san)
            if node.comment:
                line.append("{" + node.comment + "}")
            continue

        body, annot = strip_annotations(node.san)

        # Move number prefix
        if board.turn == chess.WHITE:
            prefix = f"{board.fullmove_number}."
        else:
            # Only add black move number if it's the first move or after a comment
            if i == 0 or (i > 0 and game.moves[i - 1].comment):
                prefix = f"{board.fullmove_number}..."
            else:
                prefix = ""

        san_display = f"{prefix}{node.san}"
        if node.is_guess:
            san_display += " {?OCR}"

        line.append(san_display)

        if node.comment:
            line.append("{" + node.comment + "}")

        try:
            board.push_san(body)
        except (ValueError, chess.InvalidMoveError, chess.IllegalMoveError):
            line.append("{ERROR: board desync}")
            break

    line.append(game.header.result)
    parts.append(" ".join(line))
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Error log output
# ---------------------------------------------------------------------------

def write_error_log(issues: list[ParseIssue], path: Path):
    """Write the error log as JSON for LLM review."""
    data = {
        "total_issues": len(issues),
        "by_severity": {
            "no_match": sum(1 for i in issues if i.issue == "no_match"),
            "correction_failed": sum(1 for i in issues if i.issue == "correction_failed_on_push"),
            "low_confidence": sum(1 for i in issues if i.issue == "low_confidence_fuzzy"),
            "ambiguous": sum(1 for i in issues if i.issue in ("ambiguous_piece_sub", "fuzzy_match")),
        },
        "issues": [asdict(i) for i in issues],
    }
    with open(path, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Parse OCR'd chess book text into PGN"
    )
    parser.add_argument("ocr_json", help="Path to ocr_output.json from ocr_pages.py")
    parser.add_argument("--out-dir", default="output", help="Output directory")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Load OCR data
    with open(args.ocr_json) as f:
        raw_pages = json.load(f)
    print(f"Loaded {len(raw_pages)} OCR pages")

    # Clean text
    pages = clean_raw_text(raw_pages)
    print(f"Cleaned {len(pages)} pages")

    # Find games and segment
    games_raw = combine_and_segment(pages)
    print(f"Found {len(games_raw)} games")

    if not games_raw:
        print("No games found. Check OCR quality and game header detection.")
        sys.exit(1)

    # Parse each game
    all_games = []
    all_issues = []
    for idx, (text, header, start_page) in enumerate(games_raw):
        print(f"\n--- Game {idx + 1}: {header.white} vs {header.black} "
              f"({header.event}) page {start_page} ---")
        game = parse_game_text(text, header, idx + 1, start_page)
        all_games.append(game)
        all_issues.extend(game.issues)
        n_ok = sum(1 for m in game.moves if not m.is_guess)
        n_guess = sum(1 for m in game.moves if m.is_guess)
        print(f"  Moves: {n_ok} confident, {n_guess} guesses, "
              f"{len(game.issues)} issues")

    # Write PGN
    pgn_path = out_dir / "games.pgn"
    with open(pgn_path, "w") as f:
        for game in all_games:
            f.write(game_to_pgn(game))
            f.write("\n\n")
    print(f"\nWrote {pgn_path}")

    # Write error log
    errors_path = out_dir / "errors.json"
    write_error_log(all_issues, errors_path)
    print(f"Wrote {errors_path}")

    # Summary
    print(f"\n{'='*60}")
    print(f"SUMMARY")
    print(f"  Games extracted: {len(all_games)}")
    total_moves = sum(len(g.moves) for g in all_games)
    total_ok = sum(sum(1 for m in g.moves if not m.is_guess) for g in all_games)
    total_guess = sum(sum(1 for m in g.moves if m.is_guess) for g in all_games)
    print(f"  Total moves: {total_moves}")
    print(f"  Confident: {total_ok} ({100*total_ok/max(total_moves,1):.1f}%)")
    print(f"  Guesses/errors: {total_guess} ({100*total_guess/max(total_moves,1):.1f}%)")
    print(f"  Issues for LLM review: {len(all_issues)}")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
