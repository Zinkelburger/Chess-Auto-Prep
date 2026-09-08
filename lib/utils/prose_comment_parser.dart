/// Display-only parsing for moves embedded in ordinary, single-spaced prose.
library;

import 'package:dartchess/dartchess.dart';

import 'pgn_comment_utils.dart';

final _lexeme = RegExp(
  r'\[--\]|\n\s*\n|•|[()]|'
  r'(?<![\w.])(?:(\d+)(\.{3}|\.)\s*|(…|\.{3}))?'
  '$kSanCorePattern'
  r'([+#]?[!?]{0,2})(?![\w])',
);
final _bareSquare = RegExp(r'^[a-h][1-8]$');
final _nullMarker = RegExp(r'(?<!\w)\d+\.{3}\s*(?:--|Z0)(?!\w)\s*');
final _duplicate = RegExp(
  r'(?<!\w)(\d+)\.\.\.\s*'
  '$kSanCorePattern'
  r'\s+(\d+)\.\s*'
  '$kSanCorePattern',
);
int _ply(Position pos) =>
    (pos.fullmoves - 1) * 2 + (pos.turn == Side.white ? 0 : 1);

/// Paragraphs retain their text, punctuation and bold markers. Only legal SAN
/// becomes a move. Numbered moves can restart from a known earlier position;
/// parentheses save/restore the surrounding line. No guessed null moves fill
/// gaps, and a bare square in prose never starts a line.
List<List<CommentToken>> parseProseComment(
  String text, {
  required Position anchor,
  List<Position> positions = const [],
}) {
  final known = {
    for (final pos in positions) _ply(pos): pos,
    _ply(anchor): anchor,
  };
  final courseExport = text.contains('[--]') || text.contains('•');
  if (courseExport) {
    // Some exporters insert fake null-move counters and repeat a White move
    // with a Black prefix. Remove the latter only when that Black move is
    // impossible and the repeated White move is legal at the known position.
    text = text.replaceAll(_nullMarker, '');
    text = text.replaceAllMapped(_duplicate, (m) {
      if (m[1] != m[3] || m[2] != m[4]) return m[0]!;
      final ply = (int.parse(m[1]!) - 1) * 2;
      final white = known[ply];
      final black = known[ply + 1];
      if (white?.parseSan(m[2]!) == null || black?.parseSan(m[2]!) != null) {
        return m[0]!;
      }
      return '${m[3]}.${m[4]}';
    });
  }
  var history = Map<int, Position>.of(known);
  var position = anchor;
  var run = <CommentMove>[];
  var runId = 0;
  final stack =
      <
        ({Map<int, Position> history, Position position, List<CommentMove> run})
      >[];
  final paragraphs = <List<CommentToken>>[[]];
  var offset = 0;
  var previousWasMove = false;

  void prose(String value) {
    if (value.isEmpty) return;
    final paragraph = paragraphs.last;
    if (paragraph.lastOrNull case CommentProse(:final text)) {
      paragraph[paragraph.length - 1] = CommentProse('$text$value');
    } else {
      paragraph.add(CommentProse(value));
    }
  }

  for (final match in _lexeme.allMatches(text)) {
    final between = text.substring(offset, match.start);
    prose(between);
    final adjacent = previousWasMove && between.trim().isEmpty;
    final value = match[0]!;
    offset = match.end;
    previousWasMove = false;
    if (value == '[--]' || value.startsWith('\n') || value == '•') {
      if (paragraphs.last.isNotEmpty) paragraphs.add([]);
      if (value == '•') {
        prose('• ');
        history = Map.of(known);
        position = anchor;
        run = [];
      }
      continue;
    }
    if (value == '(') {
      stack.add((history: Map.of(history), position: position, run: run));
      prose(value);
      continue;
    }
    if (value == ')') {
      if (stack.isNotEmpty) {
        final saved = stack.removeLast();
        history = saved.history;
        position = saved.position;
        run = saved.run;
        previousWasMove = run.isNotEmpty;
      }
      prose(value);
      continue;
    }
    final number = int.tryParse(match[1] ?? '');
    final ellipsis = match[3] != null;
    final san = '${match[4]}${match[5]!.replaceAll(RegExp(r'[!?]'), '')}';
    final bare = number == null && !ellipsis;
    if (bare && !adjacent && _bareSquare.hasMatch(san)) {
      prose(value);
      continue;
    }
    Position? base;
    if (number != null) {
      final ply = (number - 1) * 2 + (match[2] == '.' ? 0 : 1);
      base = history[ply];
    } else {
      base = adjacent ? position : anchor;
      if (ellipsis && base.turn != Side.black) base = null;
    }
    final move = base?.parseSan(san);
    if (base == null || move == null) {
      prose(value);
      continue;
    }
    if (run.isEmpty || base.fen != position.fen) {
      run = [];
      runId++;
    }
    final token = CommentMove(
      san: san,
      display: value.replaceAll(RegExp(r'(?<=\.)\s+'), ''),
      moveNumber: base.fullmoves,
      isWhite: base.turn == Side.white,
      runId: run.isEmpty ? runId : run.first.runId,
      anchorFen: run.isEmpty ? base.fen : run.first.anchorFen,
    );
    run.add(token);
    paragraphs.last.add(token);
    history.removeWhere((ply, _) => ply > _ply(base!));
    position = base.play(move);
    history[_ply(position)] = position;
    previousWasMove = true;
  }
  prose(text.substring(offset));
  return paragraphs
      .where(
        (p) => p.any((t) => t is! CommentProse || t.text.trim().isNotEmpty),
      )
      .toList();
}
