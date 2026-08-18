/// Board shapes (arrows and circles) carried in PGN comments as the Lichess
/// `[%cal …]` / `[%csl …]` tokens.
///
/// `[%csl Gd4,Re5]`  — circles on d4 (green) and e5 (red).
/// `[%cal Gd4e5,Rf3g5]` — arrows d4→e5 (green) and f3→g5 (red).
///
/// These tokens are deliberately stripped from *displayed prose*
/// ([filterDisplayComment]); this file is the other half of that deal — it
/// turns them into something the board can draw, and writes edits back into
/// the stored comment without disturbing the surrounding text.
library;

import '../models/board_annotation.dart';

final _cslRe = RegExp(r'\[%csl\s+([^\]]*)\]');
final _calRe = RegExp(r'\[%cal\s+([^\]]*)\]');
final _squareRe = RegExp(r'^[a-h][1-8]$');

/// Lichess uses one letter per colour. Purple has no standard letter, so it
/// round-trips as blue rather than being silently dropped.
const _letterToBrush = {
  'G': AnnotationBrush.green,
  'R': AnnotationBrush.red,
  'Y': AnnotationBrush.yellow,
  'B': AnnotationBrush.blue,
};

String _brushToLetter(AnnotationBrush brush) => switch (brush) {
  AnnotationBrush.green => 'G',
  AnnotationBrush.red => 'R',
  AnnotationBrush.yellow => 'Y',
  AnnotationBrush.blue => 'B',
  AnnotationBrush.purple => 'B',
};

/// Extract every arrow and circle encoded in [comment].
///
/// Unparseable entries are skipped rather than throwing — these tokens arrive
/// from scraped PGNs of wildly varying quality.
List<BoardAnnotation> parseBoardShapes(String? comment) {
  if (comment == null || comment.isEmpty) return const [];
  final shapes = <BoardAnnotation>[];

  for (final match in _cslRe.allMatches(comment)) {
    for (final entry in _splitEntries(match.group(1))) {
      // "Gd4" — colour letter plus one square.
      if (entry.length != 3) continue;
      final square = entry.substring(1).toLowerCase();
      if (!_squareRe.hasMatch(square)) continue;
      shapes.add(BoardAnnotation(orig: square, brush: _brushFor(entry[0])));
    }
  }

  for (final match in _calRe.allMatches(comment)) {
    for (final entry in _splitEntries(match.group(1))) {
      // "Gd4e5" — colour letter plus origin and destination squares.
      if (entry.length != 5) continue;
      final orig = entry.substring(1, 3).toLowerCase();
      final dest = entry.substring(3, 5).toLowerCase();
      if (!_squareRe.hasMatch(orig) || !_squareRe.hasMatch(dest)) continue;
      shapes.add(
        BoardAnnotation(orig: orig, dest: dest, brush: _brushFor(entry[0])),
      );
    }
  }

  return shapes;
}

/// Rewrite [comment] so its shape tokens describe exactly [shapes].
///
/// Existing `[%cal]`/`[%csl]` tokens are replaced (not appended to), prose is
/// preserved, and an empty [shapes] removes the tokens entirely. Returns null
/// when nothing is left, which is what the tree stores for "no comment".
String? writeBoardShapes(String? comment, List<BoardAnnotation> shapes) {
  var rest = (comment ?? '')
      .replaceAll(_cslRe, '')
      .replaceAll(_calRe, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  final circles = shapes.where((s) => s.isCircle).toList();
  final arrows = shapes.where((s) => s.isArrow).toList();

  final tokens = <String>[];
  if (circles.isNotEmpty) {
    tokens.add(
      '[%csl ${circles.map((s) => '${_brushToLetter(s.brush)}${s.orig}').join(',')}]',
    );
  }
  if (arrows.isNotEmpty) {
    tokens.add(
      '[%cal ${arrows.map((s) => '${_brushToLetter(s.brush)}${s.orig}${s.dest}').join(',')}]',
    );
  }

  if (tokens.isEmpty) return rest.isEmpty ? null : rest;
  final joined = tokens.join(' ');
  return rest.isEmpty ? joined : '$rest $joined';
}

/// Add [shape] to [shapes], or remove it when the same arrow/circle is already
/// there — drawing a shape twice erases it, the behaviour Lichess trained
/// everyone to expect. Same squares in a different colour recolours instead.
List<BoardAnnotation> toggleBoardShape(
  List<BoardAnnotation> shapes,
  BoardAnnotation shape,
) {
  final result = <BoardAnnotation>[];
  var matched = false;
  for (final existing in shapes) {
    final sameSquares =
        existing.orig == shape.orig &&
        (existing.dest ?? existing.orig) == (shape.dest ?? shape.orig);
    if (sameSquares) {
      matched = true;
      // Different brush on the same squares: recolour, don't erase.
      if (existing.brush != shape.brush) result.add(shape);
      continue;
    }
    result.add(existing);
  }
  if (!matched) result.add(shape);
  return result;
}

AnnotationBrush _brushFor(String letter) =>
    _letterToBrush[letter.toUpperCase()] ?? AnnotationBrush.green;

Iterable<String> _splitEntries(String? raw) =>
    (raw ?? '').split(',').map((e) => e.trim()).where((e) => e.isNotEmpty);
