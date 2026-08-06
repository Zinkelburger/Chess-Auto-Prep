/// The one place generated PGN games are turned into text.
///
/// There used to be two independent emitters — `LineExtractor.exportPgn` and
/// `pgn_export.buildRepertoirePgnEntry` — with separately maintained copies of
/// the annotation logic, which is how they drifted apart.  Everything the
/// generator writes (repertoire lines, course chapters, model games, snapshot
/// exports) now goes through [writePgnGame].
library;

import '../../../constants/chess_constants.dart';
import '../../../utils/movetext_builder.dart';
import 'move_annotation.dart';

/// One sideline hung off a mainline move.
///
/// [movesSan] starts at the *same ply* as the move it hangs off, so a
/// continuation repeats that move (`5... Qxe4 (5... Qxe4 6. Nxd5)`) and an
/// alternative simply begins with a different one (`5... Nf6 (5... Ng4? 6.
/// Qxg4)`).  Suffix characters — `?`, `?!` — belong on the SAN itself.
class PgnSideline {
  final List<String> movesSan;

  /// Comment body (without braces) written after the sideline's first move,
  /// which is where anything worth saying about a rejected move belongs.
  final String? comment;

  const PgnSideline(this.movesSan, {this.comment});
}

/// One PGN game: tag pairs, an optional leading comment, and annotated
/// movetext terminated by a result token.
class PgnGameSpec {
  /// Tag pairs in emission order.  `Event` should come first by convention,
  /// and it is what study chapters use as their name.  `FEN`/`SetUp` are
  /// derived from [startFen] — do not pass them here.
  final Map<String, String> headers;

  final List<String> movesSan;

  /// Parallel to [movesSan] from index [annotationOffset] onward.  Shorter
  /// lists are fine; missing entries annotate nothing.
  final List<MoveAnnotation> annotations;

  /// Plies at the head of [movesSan] that carry no annotation — the shared
  /// prefix leading from the repertoire root to this line's own start.
  final int annotationOffset;

  /// Position the movetext starts from; a non-standard value emits
  /// `FEN`/`SetUp` headers.
  final String startFen;

  final bool rootWhiteToMove;

  /// Move number of the first ply (1 unless the line starts mid-game).
  final int startMoveNumber;

  /// Free text emitted as a `{...}` comment before the first move.
  final String? leadingComment;

  /// Sidelines to hang off the mainline, keyed by the index in [movesSan] of
  /// the move they belong to.  Each is written inside `( )` right after that
  /// move, in list order, numbered as if it started at that ply.
  ///
  /// Independent of [MoveAnnotationDetail]: a variation is content, not
  /// per-move detail, and is written even in a bare export.
  final Map<int, List<PgnSideline>> variations;

  /// Terminating token — `*` for a repertoire line, a real result for a
  /// model game.
  final String result;

  const PgnGameSpec({
    required this.headers,
    required this.movesSan,
    this.annotations = const [],
    this.annotationOffset = 0,
    this.startFen = kStandardStartFen,
    this.rootWhiteToMove = true,
    this.startMoveNumber = 1,
    this.leadingComment,
    this.variations = const {},
    this.result = '*',
  });
}

/// Serialize [spec] as a complete PGN game, including the trailing newline
/// that separates it from the next one.
String writePgnGame(PgnGameSpec spec, {required MoveAnnotationDetail detail}) {
  final buffer = StringBuffer();

  for (final entry in spec.headers.entries) {
    if (entry.value.isEmpty) continue;
    buffer.writeln('[${entry.key} "${escapePgnHeaderValue(entry.value)}"]');
  }
  final needsFen =
      spec.startFen.isNotEmpty && spec.startFen != kStandardStartFen;
  if (needsFen) {
    buffer
      ..writeln('[FEN "${spec.startFen}"]')
      ..writeln('[SetUp "1"]');
  }
  buffer.writeln();

  final comment = spec.leadingComment;
  if (comment != null && comment.isNotEmpty) {
    buffer.write('{$comment} ');
  }

  final movetext = buildNumberedMovetext(
    spec.movesSan,
    startMoveNumber: spec.startMoveNumber,
    whiteToMoveFirst: spec.rootWhiteToMove,
    suffix: (index) => _suffixFor(spec, index, detail),
  );
  if (movetext.isNotEmpty) buffer.write('$movetext ');
  buffer.writeln(spec.result);

  return buffer.toString();
}

String? _suffixFor(PgnGameSpec spec, int index, MoveAnnotationDetail detail) {
  final buffer = StringBuffer();

  final annotationIndex = index - spec.annotationOffset;
  if (detail.emitsAnything &&
      annotationIndex >= 0 &&
      annotationIndex < spec.annotations.length) {
    final comment = spec.annotations[annotationIndex].toPgnComment(detail);
    if (comment != null) buffer.write(' {$comment}');
  }

  for (final sideline in spec.variations[index] ?? const <PgnSideline>[]) {
    if (sideline.movesSan.isEmpty) continue;
    final note = sideline.comment;
    final inner = buildNumberedMovetext(
      sideline.movesSan,
      startMoveNumber: _moveNumberAt(spec, index),
      whiteToMoveFirst: _isWhiteAt(spec, index),
      suffix: (i) =>
          i == 0 && note != null && note.isNotEmpty ? ' {$note}' : null,
    );
    if (inner.isNotEmpty) buffer.write(' ($inner)');
  }

  return buffer.isEmpty ? null : buffer.toString();
}

/// Side to move at ply [index] of the mainline.
bool _isWhiteAt(PgnGameSpec spec, int index) =>
    index.isEven ? spec.rootWhiteToMove : !spec.rootWhiteToMove;

/// Full-move number the move at ply [index] belongs to.
int _moveNumberAt(PgnGameSpec spec, int index) => spec.rootWhiteToMove
    ? spec.startMoveNumber + index ~/ 2
    : spec.startMoveNumber + (index + 1) ~/ 2;

/// Escape a header value the way [StudyChapter.toPgn] does, so a generated
/// chapter round-trips through the study reader unchanged.
String escapePgnHeaderValue(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
