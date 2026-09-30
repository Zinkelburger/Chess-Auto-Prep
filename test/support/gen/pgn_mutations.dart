/// Damage done to PGN text, the way files really arrive broken: a byte
/// changed, a span lost or doubled, a file cut short, a tag or a brace left
/// open, `[Event` inside a comment, games swapped, line endings flipped, a
/// byte-order mark in the middle, a move that is not legal.
///
/// A mutated text has no truth; the laws over it are the ones that hold for
/// any text at all.
library;

import '../props.dart';

/// Characters that have a meaning somewhere in the format, so a mutation is
/// far likelier to reach a decision than a random byte would be.
const _poison =
    r'[]{}();%$"\*.-+#=xXzZ0189abhqQKNO '
    '\n\r\t﻿';

/// One way to damage a text, by name so a failure says which.
typedef Mutation = ({String name, String Function(String text, Rand r) apply});

final List<Mutation> mutations = [
  (name: 'replace a character', apply: replaceCharacter),
  (name: 'flip a bit', apply: _flipBit),
  (name: 'delete a span', apply: _deleteSpan),
  (name: 'duplicate a span', apply: _duplicateSpan),
  (name: 'truncate', apply: _truncate),
  (name: 'open a brace', apply: (t, r) => _insert(t, r, '{')),
  (name: 'open a variation', apply: (t, r) => _insert(t, r, '(')),
  (name: 'damage a tag', apply: _damageTag),
  (name: 'an [Event inside a comment', apply: _eventInComment),
  (name: 'swap two games', apply: _swapGames),
  (name: 'flip line endings', apply: _flipLineEndings),
  (name: 'a byte-order mark mid-file', apply: (t, r) => _insert(t, r, '﻿')),
  (name: 'insert an illegal move', apply: _illegalMove),
];

/// [text] with 1 to [most] mutations applied, and their names in order.
({String text, List<String> applied}) mutate(
  String text,
  Rand r, {
  int most = 3,
}) {
  var result = text;
  final applied = <String>[];
  for (var i = r.between(1, most); i > 0; i--) {
    final mutation = r.pick(mutations);
    result = mutation.apply(result, r);
    applied.add(mutation.name);
  }
  return (text: result, applied: applied);
}

/// [text] with one character replaced by one that means something in PGN.
String replaceCharacter(String text, Rand r) {
  if (text.isEmpty) return _poison[r.nextInt(_poison.length)];
  final at = r.nextInt(text.length);
  return text.replaceRange(at, at + 1, _poison[r.nextInt(_poison.length)]);
}

String _flipBit(String text, Rand r) {
  if (text.isEmpty) return text;
  final at = r.nextInt(text.length);
  final flipped = text.codeUnitAt(at) ^ (1 << r.nextInt(8));
  return text.replaceRange(at, at + 1, String.fromCharCode(flipped));
}

(int, int) _span(String text, Rand r) {
  final start = r.nextInt(text.length + 1);
  final end = start + r.nextInt(40);
  return (start, end > text.length ? text.length : end);
}

String _deleteSpan(String text, Rand r) {
  final (start, end) = _span(text, r);
  return text.replaceRange(start, end, '');
}

String _duplicateSpan(String text, Rand r) {
  final (start, end) = _span(text, r);
  return text.replaceRange(end, end, text.substring(start, end));
}

String _truncate(String text, Rand r) =>
    text.substring(0, r.nextInt(text.length + 1));

String _insert(String text, Rand r, String what) {
  final at = r.nextInt(text.length + 1);
  return text.replaceRange(at, at, what);
}

/// A tag's closing bracket or one of its quotes lost.
String _damageTag(String text, Rand r) {
  final tags = RegExp(r'\[\w+ +"[^"\n]*"\]').allMatches(text).toList();
  if (tags.isEmpty) return replaceCharacter(text, r);
  final tag = r.pick(tags);
  final at = r.nextBool() ? tag.end - 1 : text.indexOf('"', tag.start);
  return text.replaceRange(at, at + 1, '');
}

String _eventInComment(String text, Rand r) {
  final starts = _lineStarts(text);
  final at = r.pick(starts);
  return text.replaceRange(at, at, '{ quoted:\n[Event "Inside"]\n}\n');
}

String _swapGames(String text, Rand r) {
  final starts = [
    for (final at in _lineStarts(text))
      if (text.startsWith('[Event ', at)) at,
  ];
  if (starts.length < 2) return text;
  final i = r.nextInt(starts.length - 1);
  final (a, b) = (starts[i], starts[i + 1]);
  final end = i + 2 < starts.length ? starts[i + 2] : text.length;
  return text.replaceRange(
    a,
    end,
    '${text.substring(b, end)}${text.substring(a, b)}',
  );
}

String _flipLineEndings(String text, Rand r) {
  if (text.contains('\r\n') && r.nextBool()) {
    return text.replaceAll('\r\n', '\n');
  }
  final lines = _lineStarts(text).where((at) => at > 0).toList();
  if (lines.isEmpty || r.nextBool()) {
    return text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
  }
  final at = r.pick(lines) - 1;
  return text.replaceRange(at, at + 1, '\r\n');
}

/// A move that reads as SAN, somewhere after a space.
String _illegalMove(String text, Rand r) {
  final spaces = [
    for (var i = 0; i < text.length; i++)
      if (text.codeUnitAt(i) == 0x20) i,
  ];
  if (spaces.isEmpty) return text;
  final at = r.pick(spaces) + 1;
  final move = r.pick(const ['Kh8 ', 'Qd4 ', 'e5 ', 'Nf3 ', 'O-O ']);
  return text.replaceRange(at, at, move);
}

List<int> _lineStarts(String text) => [
  0,
  for (var i = 0; i < text.length; i++)
    if (text.codeUnitAt(i) == 0x0A) i + 1,
];
