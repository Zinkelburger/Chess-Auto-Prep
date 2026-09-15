/// Inline analysis lines embedded in book-style PGN comments.
///
/// Book PGNs (Chessable / Forward Chess exports) put analysis directly in
/// comment text, with double spaces separating each move token (e.g.
/// `Or  40.cxb5  c4!-+  , winning the pawn ending.`). [parseCommentTokens]
/// recovers that structure so the viewer can render the moves as clickable
/// chips and flow the prose naturally instead of one-token-per-line.
/// `prose_comment_parser.dart` is the sibling for ordinary single-spaced
/// prose; both produce the same [CommentToken]s.
library;

import 'package:dartchess/dartchess.dart';

import 'fen_utils.dart';

/// A comment token: prose, an embedded position, or a preview move.
sealed class CommentToken {
  const CommentToken();
}

/// An embedded FEN to render independently of the main board.
class CommentDiagram extends CommentToken {
  final String fen;
  const CommentDiagram(this.fen);
}

/// A run of human-readable prose.
class CommentProse extends CommentToken {
  final String text;
  const CommentProse(this.text);

  @override
  String toString() => 'CommentProse("$text")';
}

/// A single chess move embedded in a comment.
class CommentMove extends CommentToken {
  /// The playable SAN core (e.g. `cxb5`, `Rxc4`, `O-O`), with move numbers,
  /// check/mate glyphs, annotations (`!?`) and eval symbols (`-+`) stripped.
  final String san;

  /// The original text as written, for display (e.g. `40.cxb5`, `42...Kc3?`).
  final String display;

  /// Fullmove number this move belongs to, or -1 when it could not be
  /// determined (in which case the move is shown but not clickable).
  final int moveNumber;

  /// Whether it is White's move.
  final bool isWhite;

  /// Identifier of the contiguous run of moves this belongs to. Clicking a
  /// move replays its whole run from the run's first move.
  final int runId;

  /// When non-null, the run this move belongs to starts from this FEN position
  /// (a bare FEN dropped in the comment prose) rather than the mainline. Book
  /// PGNs use this to attach analysis lines to positions unrelated to the
  /// current move. Replayed from the FEN instead of by move number.
  final String? anchorFen;

  const CommentMove({
    required this.san,
    required this.display,
    required this.moveNumber,
    required this.isWhite,
    required this.runId,
    this.anchorFen,
  });

  bool get isClickable => moveNumber >= 0;

  @override
  String toString() => 'CommentMove($display)';
}

/// The SAN move-core grammar (no move number, check/mate, or annotation
/// glyphs): castling, or a piece/pawn move with optional disambiguation,
/// capture, and promotion. The alternation is a single capturing group so
/// callers embedding it can capture the core. Shared by [_commentMoveRe] here,
/// the prose comment parser and the prose move detector in the movetext view.
const String kSanCorePattern =
    r'(O-O-O|O-O|'
    r'(?:[KQRBN][a-h1-8]?x?[a-h][1-8]|[a-h]x[a-h][1-8]|[a-h][1-8])(?:=[QRBN])?)';

/// Matches one move token: optional move number + dots, SAN core, optional
/// check/mate, annotation glyphs, and eval symbols.
final _commentMoveRe = RegExp(
  r'^(?:(\d+)(\.{3}|\.))?'
  '$kSanCorePattern'
  r'([+#]?)'
  r'(?:[!?]{1,2})?'
  r'(?:[-+=]{1,2}|[-+]/[-+]|±|∓|⩲|⩱)?$',
);

/// Splits a comment into tokens: double-space, newline, and `---` are all
/// token separators in the book-PGN convention.
final _commentTokenSplitRe = RegExp(r'\n|---|\s{2,}');

/// Matches a full FEN embedded in comment prose: board (8 ranks) / side /
/// castling / en-passant / halfmove / fullmove. Book PGNs (Chessable) drop a
/// bare FEN in front of an analysis line to mark that line's start position.
final _fenRe = RegExp(
  r'(?:[pnbrqkPNBRQK1-8]+/){7}[pnbrqkPNBRQK1-8]+ [wb] (?:-|[KQkq]+) '
  r'(?:-|[a-h][36]) \d+ \d+',
);

/// Whether [comment] carries a bare six-field FEN somewhere in its prose.
bool hasEmbeddedFen(String comment) => _fenRe.hasMatch(comment);

/// True when [fen] parses as a legal position setup.
bool _isValidFen(String fen) {
  try {
    Setup.parseFen(fen);
    return true;
  } catch (_) {
    return false;
  }
}

/// The (moveNumber, isWhite) of the ply *before* the side to move in [fen],
/// used to seed inline move-number continuity so an unnumbered first move after
/// the FEN lands on the right ply. Null when the FEN is the very first ply.
({int number, bool white})? _fenPrevPly(String fen) {
  final fields = fen.split(' ');
  if (fields.length < 6) return null;
  final fullmove = int.tryParse(fields[5]);
  if (fullmove == null) return null;
  if (isWhiteToMove(fen)) {
    // White to move on `fullmove`: previous ply was Black's move fullmove-1.
    if (fullmove <= 1) return null;
    return (number: fullmove - 1, white: false);
  }
  // Black to move: White has just moved on `fullmove`.
  return (number: fullmove, white: true);
}

/// Parse engine-stripped comment text into prose / move tokens.
///
/// Pass the output of `stripEngineTokens` (which preserves the double-space
/// structure), or a `RichSegment` text body (whose `\n`s mark token breaks).
List<CommentToken> parseCommentTokens(String text) {
  final parser = _CommentTokenParser();
  for (final raw in text.split(_commentTokenSplitRe)) {
    final part = raw.trim();
    if (part.isEmpty) continue;
    parser.addPart(part);
  }
  return parser.tokens;
}

/// The state one pass of [parseCommentTokens] carries between parts: the last
/// move seen (to number unnumbered successors and decide run membership) and
/// the FEN anchor armed for the next run.
class _CommentTokenParser {
  final tokens = <CommentToken>[];
  var _runId = 0;

  // Last move seen (regardless of interspersed prose), used both to derive
  // unnumbered moves and to decide run membership by move-number continuity.
  int? _lastNumber;
  bool? _lastWhite;

  // A bare FEN in the prose anchors the *next* run to that position instead of
  // the mainline. `pending` is armed by a FEN and consumed by the first move of
  // the run it opens; the anchor then stays attached to that run's moves.
  String? _pendingAnchorFen;
  String? _activeRunAnchorFen;
  int? _anchoredRunId;
  var _forceNewRun = false;

  /// One separator-delimited part: a move token, or prose that may carry
  /// embedded FENs.
  void addPart(String part) {
    // Move tokens never contain a FEN — handle directly.
    if (_commentMoveRe.hasMatch(part)) {
      _addMoveOrProse(part);
      return;
    }

    // Prose: pull out any embedded FEN(s), emitting the surrounding text and
    // arming the anchor for the following run and preserving its diagram.
    var cursor = 0;
    for (final match in _fenRe.allMatches(part)) {
      final fen = match.group(0)!;
      if (!_isValidFen(fen)) continue;
      final before = part.substring(cursor, match.start).trim();
      if (before.isNotEmpty) _addMoveOrProse(before);
      _addDiagram(fen);
      cursor = match.end;
    }
    final after = part.substring(cursor).trim();
    if (after.isNotEmpty) _addMoveOrProse(after);
  }

  void _addDiagram(String fen) {
    tokens.add(CommentDiagram(fen));
    _pendingAnchorFen = fen;
    _forceNewRun = true;
    final seed = _fenPrevPly(fen);
    _lastNumber = seed?.number;
    _lastWhite = seed?.white;
  }

  void _addMoveOrProse(String part) {
    final m = _commentMoveRe.firstMatch(part);
    if (m == null) {
      tokens.add(CommentProse(part));
      return;
    }

    final numStr = m.group(1);
    final dots = m.group(2);

    // Expected successor ply of the previous move.
    final lastNumber = _lastNumber;
    final lastWhite = _lastWhite;
    int? expectedNumber;
    bool? expectedWhite;
    if (lastNumber != null && lastWhite != null) {
      expectedNumber = lastWhite ? lastNumber : lastNumber + 1;
      expectedWhite = !lastWhite;
    }

    int number;
    bool white;
    if (numStr != null) {
      number = int.parse(numStr);
      white = dots != '...';
    } else if (expectedNumber != null) {
      // Unnumbered move: it is the successor of the previous move.
      number = expectedNumber;
      white = expectedWhite!;
    } else {
      number = -1;
      white = true;
    }

    // A move continues the current line when it is exactly the expected
    // successor of the previous move; otherwise it starts a new run. Lines
    // survive interspersed prose ("... is a draw: 43.Rxc4+ ...") but break
    // when the analysis jumps back to try a different move. A FEN always forces
    // a fresh run so its line isn't glued onto the preceding one.
    final continues =
        !_forceNewRun &&
        number >= 0 &&
        expectedNumber != null &&
        number == expectedNumber &&
        white == expectedWhite;
    if (!continues) _runId++;

    // Attach a freshly-armed FEN anchor to the run this move opens; the anchor
    // then carries to the run's continuation moves.
    if (_forceNewRun && _pendingAnchorFen != null) {
      _activeRunAnchorFen = _pendingAnchorFen;
      _anchoredRunId = _runId;
      _pendingAnchorFen = null;
    }
    _forceNewRun = false;

    tokens.add(
      CommentMove(
        san: m.group(3)!,
        display: part,
        moveNumber: number,
        isWhite: white,
        runId: _runId,
        anchorFen: _runId == _anchoredRunId ? _activeRunAnchorFen : null,
      ),
    );

    if (number >= 0) {
      _lastNumber = number;
      _lastWhite = white;
    } else {
      _lastNumber = null;
      _lastWhite = null;
    }
  }
}
