import 'package:dartchess/dartchess.dart' show Square;

import 'comment_text.dart';

/// Arrows and circles on a board, carried in a PGN comment as Lichess's
/// `[%cal …]` and `[%csl …]` tokens.
///
/// `[%csl Gd4,Re5]` circles d4 in green and e5 in red; `[%cal Gd4e5,Rf3g5]`
/// draws arrows d4→e5 and f3→g5. One letter per colour — G, R, B, Y — the
/// four Lichess writes. The tokens are machine tokens: the prose a person
/// reads never shows them (`displayComment`), and this file is the other
/// half of that — what the board draws from them, and the comment with
/// them rewritten.
enum ShapeColour {
  green('G'),
  red('R'),
  blue('B'),
  yellow('Y');

  const ShapeColour(this.letter);

  final String letter;

  /// A letter no one else writes reads as green, the colour drawn with no
  /// key held, rather than dropping the shape; [withShapes] writes it back
  /// as it was.
  static ShapeColour ofLetter(String letter) => values.firstWhere(
    (colour) => colour.letter == letter.toUpperCase(),
    orElse: () => green,
  );
}

/// One arrow from [from] to [to], or a circle when the two are the same.
final class BoardShape {
  const BoardShape(this.from, this.to, this.colour);

  const BoardShape.circle(Square on, ShapeColour colour) : this(on, on, colour);

  final Square from;
  final Square to;
  final ShapeColour colour;

  bool get isCircle => from == to;

  @override
  bool operator ==(Object other) =>
      other is BoardShape &&
      other.from == from &&
      other.to == to &&
      other.colour == colour;

  @override
  int get hashCode => Object.hash(from, to, colour);

  @override
  String toString() => '${colour.letter}${from.name}${isCircle ? '' : to.name}';
}

/// The shapes [comment] carries, circles first, in the order written.
///
/// An entry that does not name squares is skipped: these tokens arrive from
/// PGNs of every quality, and one bad entry must not cost the others.
List<BoardShape> shapesIn(String? comment) {
  if (comment == null || !comment.contains('[%c')) return const [];
  return [
    for (final (_, shape) in [
      ..._written(_circles, comment, circle: true),
      ..._written(_arrows, comment, circle: false),
    ])
      ?shape,
  ];
}

/// [comment] with its shape tokens saying exactly [shapes], its words and
/// other tokens left as they were.
///
/// The old tokens come out with the one space that held each apart from its
/// neighbour, and the new ones go at the end, circles then arrows. A shape
/// the comment had already is written as the comment wrote it, its colour
/// letter too, even one no one else writes; an entry that reads as no shape
/// stays, as written, after the shapes: this app cannot draw it, but it is
/// somebody's data. No shapes takes the tokens away, and a comment left with
/// nothing in it is null, which is how the tree says "no comment".
String? withShapes(String? comment, List<BoardShape> shapes) {
  var rest = comment ?? '';
  final circles = _written(_circles, rest, circle: true);
  final arrows = _written(_arrows, rest, circle: false);
  final old = [..._circles.allMatches(rest), ..._arrows.allMatches(rest)];
  for (final token in old.map((match) => match[0]!)) {
    rest = withoutToken(rest, token);
  }
  final circleEntries = _entriesFor(
    shapes.where((shape) => shape.isCircle),
    circles,
  );
  final arrowEntries = _entriesFor(
    shapes.where((shape) => !shape.isCircle),
    arrows,
  );
  final tokens = [
    if (circleEntries.isNotEmpty) '[%csl ${circleEntries.join(',')}]',
    if (arrowEntries.isNotEmpty) '[%cal ${arrowEntries.join(',')}]',
  ].join(' ');
  final next = [rest, tokens].where((part) => part.isNotEmpty).join(' ');
  return next.isEmpty ? null : next;
}

/// [shapes] after [drawn] was drawn over them, as Lichess does it: the same
/// shape drawn again takes it away, the same squares in another colour
/// recolour it, and anything else is added.
List<BoardShape> withShapeDrawn(List<BoardShape> shapes, BoardShape drawn) {
  final same = shapes.indexWhere(
    (shape) => shape.from == drawn.from && shape.to == drawn.to,
  );
  if (same < 0) return [...shapes, drawn];
  return [
    for (final (index, shape) in shapes.indexed)
      if (index != same) shape else if (shape.colour != drawn.colour) drawn,
  ];
}

final _circles = RegExp(r'\[%csl\s+([^\]]*)\]');
final _arrows = RegExp(r'\[%cal\s+([^\]]*)\]');
final _entry = RegExp(r'^([A-Za-z])([a-h][1-8])([a-h][1-8])?$');

Iterable<String> _entries(String list) =>
    list.split(',').map((entry) => entry.trim()).where((e) => e.isNotEmpty);

/// Every entry of the [pattern] tokens in [comment], as written, with the
/// shape it reads as, or null for one that reads as none.
List<(String, BoardShape?)> _written(
  RegExp pattern,
  String comment, {
  required bool circle,
}) => [
  for (final match in pattern.allMatches(comment))
    for (final entry in _entries(match[1]!))
      (entry, _shape(entry, circle: circle)),
];

/// [shapes] as token entries: each as [written] has it when it is there
/// already, in the app's spelling when it is new, and after them every
/// entry of [written] that reads as no shape, unchanged.
List<String> _entriesFor(
  Iterable<BoardShape> shapes,
  List<(String, BoardShape?)> written,
) {
  final unused = [...written];
  return [
    for (final shape in shapes)
      switch (unused.indexWhere((entry) => entry.$2 == shape)) {
        -1 => '$shape',
        final at => unused.removeAt(at).$1,
      },
    for (final (entry, shape) in written)
      if (shape == null) entry,
  ];
}

/// `Gd4` as a circle or `Gd4e5` as an arrow; null for anything else, and
/// for an arrow that starts and ends on one square.
BoardShape? _shape(String entry, {required bool circle}) {
  final match = _entry.firstMatch(entry);
  if (match == null || (match[3] == null) != circle) return null;
  final colour = ShapeColour.ofLetter(match[1]!);
  final from = Square.fromName(match[2]!.toLowerCase());
  if (circle) return BoardShape.circle(from, colour);
  final to = Square.fromName(match[3]!.toLowerCase());
  return from == to ? null : BoardShape(from, to, colour);
}
