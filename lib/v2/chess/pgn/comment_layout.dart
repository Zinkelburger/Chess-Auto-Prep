import 'package:dartchess/dartchess.dart';

import '../fen.dart';
import '../pv_text.dart';

/// A comment laid out for reading: blocks top to bottom.
///
/// A course comment is an article, not a caption: paragraphs, headings,
/// quotes, diagrams and lines of analysis to hover or click. The tree keeps
/// the comment as one string so it round-trips; this is the reading view of
/// that string, built fresh each time it is shown.
sealed class CommentBlock {
  const CommentBlock();
}

final class Paragraph extends CommentBlock {
  const Paragraph(this.spans);
  final List<CommentSpan> spans;
}

final class Heading extends CommentBlock {
  const Heading(this.text);
  final String text;
}

final class Quote extends CommentBlock {
  const Quote(this.spans);
  final List<CommentSpan> spans;
}

final class Diagram extends CommentBlock {
  const Diagram(this.fen);
  final Fen fen;
}

/// One run inside a paragraph. The runs concatenate back into the
/// paragraph's text: [Words] keep the spaces and punctuation on either side
/// of them, a [MoveRun] stands for the moves as written.
sealed class CommentSpan {
  const CommentSpan();
}

final class Words extends CommentSpan {
  const Words(this.text);
  final String text;
}

/// A sequence of moves that plays legally from some position in the comment.
final class MoveRun extends CommentSpan {
  const MoveRun({required this.moves, required this.fromComment});

  /// The moves as printed, each with the position after it for a hover
  /// board. `label` is the `3.` / `3...` prefix, empty for a Black move that
  /// follows a White move; `san` the move.
  final List<PvMove> moves;

  /// When the run chains from the position the comment is attached to,
  /// directly or through earlier runs in the same comment: every move from
  /// that position through the end of this run, so a click can play them
  /// into the document. Null when the run is anchored at a diagram instead.
  final List<PvMove>? fromComment;
}

/// Lays out [comment] as read from the position [at]: the position after the
/// move the comment is on, or the chapter's start for a root comment.
/// Machine tokens `[%...]` never appear in the output.
///
/// The conventions come from Chessable exports, the course PGNs people
/// actually read here. Markup is `@@HeaderStart@@…@@HeaderEnd@@` and its
/// siblings, though the fences arrive garbled as `îî` or `��` after a
/// round trip through the wrong encoding, so any short run of symbols on
/// each side of a marker name counts. Paragraphs break on a blank line, on
/// a bullet, and on a double space when the comment is long enough that
/// double spaces are not just spacing around moves. A diagram is a bare FEN
/// in the prose or one inside FEN markers, possibly hard-wrapped.
///
/// A line of analysis such as `3.Nc3 Bg7 4.e4 d6` becomes a [MoveRun] when it
/// plays legally from an anchor: the position before or after any move of an
/// earlier run in this comment, the last diagram, or [at]. Anchors are tried
/// latest in the text first, since an author's `5.Bg5` follows on from what
/// was just shown; the numbering must agree with the anchor so `1.e4` in a
/// move-5 comment stays words. When no anchor plays the whole line, the
/// longest legal prefix is the run and the rest stays words. Trying the
/// position before each move of an earlier run is what lets `5.Bg5` after
/// `4.e4 d6 5.Be2` read as an alternative fifth move rather than nothing.
List<CommentBlock> layoutComment(String comment, {required Fen at}) {
  var text = comment.replaceAll(_machineToken, ' ');
  for (final entry in _mojibake.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }
  final layout = _Layout(at, long: text.length > _paragraphProseLength);
  layout.walk(text);
  return layout.blocks;
}

/// The state one pass over a comment carries: the blocks so far and the
/// positions a later line of analysis may start from.
final class _Layout {
  _Layout(Fen at, {required this.long}) : _anchors = [_Anchor(at, const [])];

  final blocks = <CommentBlock>[];

  /// Whether double spaces are paragraph breaks in this comment.
  final bool long;

  /// Every position seen so far, in text order: [at] with its empty chain,
  /// each diagram, and the position before and after each move of each run.
  final List<_Anchor> _anchors;

  /// Splits [text] at its markers, reading prose between them into
  /// paragraphs and each marked stretch into its block or inline words.
  void walk(String text) {
    final prose = StringBuffer();
    final markers = _marker.allMatches(text).toList();
    var cursor = 0;
    for (var i = 0; i < markers.length; i++) {
      final open = markers[i];
      prose.write(text.substring(cursor, open.start));
      cursor = open.end;
      final closeName = _closing[open[1]!];
      final close = closeName == null
          ? -1
          : markers.indexWhere((m) => m[1] == closeName, i + 1);
      // A stray or unmatched marker is dropped and the text around it kept.
      if (close < 0) continue;
      final inner = text.substring(open.end, markers[close].start);
      _marked(open[1]!, inner, prose);
      cursor = markers[close].end;
      i = close;
    }
    prose.write(text.substring(cursor));
    _flush(prose);
  }

  void _marked(String name, String inner, StringBuffer prose) {
    switch (name) {
      case 'HeaderStart':
        _flush(prose);
        blocks.add(Heading(_collapse(inner)));
      case 'StartBlockQuote':
        _flush(prose);
        blocks.add(Quote(_spans(_collapse(inner))));
      case 'StartFEN':
        _flush(prose);
        final fen = _wrappedFen(inner);
        if (fen != null) _addDiagram(fen);
      case 'StartBracket':
        prose.write('(${inner.trim()})');
      case 'StartSquare':
        prose.write('[${inner.trim()}]');
      case 'LinkStart':
        prose.write(inner);
    }
  }

  /// Turns the prose gathered so far into paragraphs and empties the buffer.
  void _flush(StringBuffer prose) {
    final text = prose.toString();
    prose.clear();
    final breaks = long ? _longBreak : _shortBreak;
    for (final paragraph in text.split(breaks)) {
      final collapsed = _collapse(paragraph);
      if (collapsed.isNotEmpty) _addParagraph(collapsed);
    }
  }

  /// One paragraph, split around any bare FEN in it: the diagram is a block
  /// of its own and the words on either side become paragraphs.
  void _addParagraph(String text) {
    var cursor = 0;
    for (final match in _bareFen.allMatches(text)) {
      final fen = _validFen(match[0]!);
      if (fen == null) continue;
      _addProse(text.substring(cursor, match.start));
      _addDiagram(fen);
      cursor = match.end;
    }
    _addProse(text.substring(cursor));
  }

  void _addProse(String text) {
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) blocks.add(Paragraph(_spans(trimmed)));
  }

  void _addDiagram(Fen fen) {
    blocks.add(Diagram(fen));
    _anchors.add(_Anchor(fen, null));
  }

  /// The spans of one paragraph of single-spaced text: words, with each
  /// numbered line that plays from an anchor as a [MoveRun].
  List<CommentSpan> _spans(String text) {
    final words = text.split(' ');
    final starts = <int>[];
    var offset = 0;
    for (final word in words) {
      starts.add(offset);
      offset += word.length + 1;
    }
    final spans = <CommentSpan>[];
    var cursor = 0;
    var i = 0;
    while (i < words.length) {
      final candidate = _candidate(words, starts, i);
      final run = _resolve(candidate);
      if (run == null) {
        i++;
        continue;
      }
      final first = candidate.first;
      final last = candidate[run.moves.length - 1];
      if (first.start > cursor) {
        spans.add(Words(text.substring(cursor, first.start)));
      }
      spans.add(run);
      cursor = last.end;
      i = last.lastIndex + 1;
    }
    if (cursor < text.length) spans.add(Words(text.substring(cursor)));
    return spans;
  }

  /// The longest stretch of move words from [from] that could be a line: it
  /// must open with a move number, and punctuation glued to a move ends it.
  List<_MoveWord> _candidate(List<String> words, List<int> starts, int from) {
    final run = <_MoveWord>[];
    var i = from;
    while (i < words.length) {
      final word = _moveWordAt(words, starts, i);
      if (word == null || (run.isEmpty && word.number == null)) break;
      run.add(word);
      i = word.lastIndex + 1;
      if (word.glued) break;
    }
    return run;
  }

  /// The run [candidate] makes from the best anchor, as many of its move
  /// words as play, or null when no anchor plays even its first move.
  MoveRun? _resolve(List<_MoveWord> candidate) {
    if (candidate.isEmpty) return null;
    _Anchor? best;
    var bestUcis = const <String>[];
    for (final anchor in _anchors.reversed) {
      final ucis = _legalPrefix(anchor, candidate);
      if (ucis.length > bestUcis.length) (best, bestUcis) = (anchor, ucis);
      if (ucis.length == candidate.length) break;
    }
    if (best == null) return null;
    final moves = pvMoves(best.fen, bestUcis);
    final chain = best.chain;
    _remember(best, moves);
    return MoveRun(
      moves: moves,
      fromComment: chain == null ? null : [...chain, ...moves],
    );
  }

  /// Adds the position before each move of a new run and the one after its
  /// last move, so a later line can branch from any point of it.
  void _remember(_Anchor anchor, List<PvMove> moves) {
    final chain = anchor.chain;
    for (var k = 0; k <= moves.length; k++) {
      final fen = k == 0 ? anchor.fen : moves[k - 1].after;
      _anchors.add(
        _Anchor(fen, chain == null ? null : [...chain, ...moves.take(k)]),
      );
    }
  }
}

/// A position a line of analysis may start from, and the moves that reach
/// it from the comment's own position when it is reached that way.
final class _Anchor {
  const _Anchor(this.fen, this.chain);
  final Fen fen;
  final List<PvMove>? chain;
}

/// One move as written in prose: `3.Nc3`, `3... Bg7` (two words), `Bg7`.
final class _MoveWord {
  const _MoveWord({
    required this.number,
    required this.white,
    required this.san,
    required this.start,
    required this.end,
    required this.lastIndex,
    required this.glued,
  });

  /// The move number written before the move, or null for a bare move.
  final int? number;

  /// Which side the dots say is moving; meaningless without [number].
  final bool white;
  final String san;

  /// Offsets in the paragraph text of the move as written, without any
  /// punctuation glued after it.
  final int start;
  final int end;

  /// Index of the last word this move spans.
  final int lastIndex;

  /// Whether punctuation follows the move without a space, as in `5.Be2.`;
  /// the sentence ends there and so does the line.
  final bool glued;

  bool fits(Position position) =>
      number == null ||
      (number == position.fullmoves && white == (position.turn == Side.white));
}

/// The move at [i], reading a number-only word such as `5.` together with
/// the move after it, or null when the word is not a move.
_MoveWord? _moveWordAt(List<String> words, List<int> starts, int i) {
  final own = _move.firstMatch(words[i]);
  if (own != null) return _moveWord(own, own, starts, i, i);
  final number = _number.firstMatch(words[i]);
  if (number == null || i + 1 >= words.length) return null;
  final next = _move.firstMatch(words[i + 1]);
  if (next == null || next[1] != null) return null;
  return _moveWord(next, number, starts, i, i + 1);
}

/// The move [match] describes, numbered by [numbering]'s first two groups
/// (digits and dots). It spans the words [first] through [last] of the
/// paragraph, less any punctuation glued to the last one.
_MoveWord _moveWord(
  RegExpMatch match,
  RegExpMatch numbering,
  List<int> starts,
  int first,
  int last,
) {
  final tail = match[4]!;
  final number = numbering[1];
  return _MoveWord(
    number: number == null ? null : int.parse(number),
    white: numbering[2] != '...',
    san: match[3]!,
    start: starts[first],
    end: starts[last] + match[0]!.length - tail.length,
    lastIndex: last,
    glued: tail.isNotEmpty,
  );
}

/// The UCI moves of the longest prefix of [run] that plays from [anchor]
/// with the numbering the words carry.
List<String> _legalPrefix(_Anchor anchor, List<_MoveWord> run) {
  final start = _positionOf(anchor.fen);
  if (start == null) return const [];
  var position = start;
  final ucis = <String>[];
  for (final word in run) {
    if (!word.fits(position)) break;
    final move = position.parseSan(word.san);
    if (move == null) break;
    ucis.add(move.uci);
    position = position.play(move);
  }
  return ucis;
}

Position? _positionOf(Fen fen) {
  try {
    return Chess.fromSetup(Setup.parseFen(fen.value));
  } on Exception {
    return null;
  }
}

/// [text] as a diagram when it is a six-field FEN dartchess accepts.
Fen? _validFen(String text) {
  if (text.split(' ').length != 6) return null;
  try {
    Setup.parseFen(text);
    return Fen(text);
  } on Exception {
    return null;
  }
}

/// The FEN between FEN markers, which a PGN writer may have hard-wrapped.
/// A line break either replaced a space or split a word, and the text does
/// not say which, so both readings of each break are tried until one is a
/// FEN; a comment carries at most one or two breaks in a diagram.
Fen? _wrappedFen(String inner) {
  final pieces = inner.trim().split(_lineBreak);
  final breaks = pieces.length - 1;
  if (breaks > 4) return null;
  for (var mask = 0; mask < 1 << breaks; mask++) {
    final joined = StringBuffer(pieces.first);
    for (var k = 0; k < breaks; k++) {
      joined.write(mask & (1 << k) == 0 ? '' : ' ');
      joined.write(pieces[k + 1]);
    }
    final fen = _validFen(_collapse(joined.toString()));
    if (fen != null) return fen;
  }
  return null;
}

String _collapse(String text) => text.replaceAll(_whitespace, ' ').trim();

/// Comments longer than this use double spaces as paragraph breaks; shorter
/// ones have them from spacing around moves.
const _paragraphProseLength = 300;

final _machineToken = RegExp(r'\[%[^\]]*\]');
final _whitespace = RegExp(r'\s+');
final _lineBreak = RegExp(r'\r?\n');

/// A blank line or a bullet starts a paragraph; in a long comment a double
/// space does too.
final _shortBreak = RegExp(r'\n\s*\n|\s+(?=•)');
final _longBreak = RegExp(r'\n\s*\n| {2,}|\s+(?=•)');

/// A marker name with one to three symbols on each side: `@@` as exported,
/// or whatever the fence became when the file was read as the wrong
/// encoding.
final _marker = RegExp(
  r'[^\sA-Za-z0-9]{1,3}'
  r'(HeaderStart|HeaderEnd|StartBlockQuote|EndBlockQuote|StartBracket|'
  r'EndBracket|StartSquare|EndSquare|StartFEN|EndFEN|LinkStart|LinkEnd)'
  r'[^\sA-Za-z0-9]{1,3}',
);

/// The marker that closes each opening marker.
const _closing = {
  'HeaderStart': 'HeaderEnd',
  'StartBlockQuote': 'EndBlockQuote',
  'StartBracket': 'EndBracket',
  'StartSquare': 'EndSquare',
  'StartFEN': 'EndFEN',
  'LinkStart': 'LinkEnd',
};

/// A six-field FEN in prose: eight ranks, side, castling, en passant and
/// the two counters.
final _bareFen = RegExp(
  r'(?:[pnbrqkPNBRQK1-8]+/){7}[pnbrqkPNBRQK1-8]+ [wb] (?:-|[KQkq]+) '
  r'(?:-|[a-h][36]) \d+ \d+',
);

/// `5.` or `5...` on its own, the move being the next word.
final _number = RegExp(r'^(\d+)(\.{3}|\.)$');

/// One move word: optional number and dots, the SAN, then check, mate,
/// judgement and evaluation glyphs, then any punctuation glued after it.
final _move = RegExp(
  r'^(?:(\d+)(\.{3}|\.))?'
  r'(O-O-O|O-O|(?:[KQRBN][a-h1-8]?x?[a-h][1-8]|[a-h]x[a-h][1-8]|[a-h][1-8])'
  r'(?:=[QRBN])?)'
  r'[+#]?[!?]{0,2}(?:[-+=]{1,2}|±|∓|⩲|⩱)?'
  r'([,.;:)]*)$',
);

/// UTF-8 read as Latin-1, the way these files usually arrive. Longer
/// sequences come first so `â€™` is not cut short by `â€`.
const _mojibake = {
  'â€™': '’',
  'â€œ': '“',
  'â€“': '–',
  'â€”': '—',
  'â€¢': '•',
  'â€': '”',
  'Â': '',
};
