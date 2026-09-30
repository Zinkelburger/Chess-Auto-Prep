/// P6: what every chess edit says it changed agrees with the store's check.
///
/// Each generated edit is made through the app's own edits and landed as
/// the workspace lands it — ids pinned, a course chapter put back into its
/// file — and the text and scope it lands with must pass
/// [changeOutsideScope] against the file it was made to. The same text with
/// one byte changed in a game the scope does not name, or in a heading it
/// does not declare, must fail it: the check is only a guard if it refuses
/// what the scope leaves out. `CAP_PROP_RUNS` and `CAP_PROP_SEED` soak or
/// replay it.
library;

import 'dart:convert';

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/gen/edit_gen.dart';
import '../support/props.dart';

void main() {
  forAll(
    'P6 every edit lands inside the scope it declares',
    editCases,
    (c) => runEdits(c).forEach(_expectInsideScope),
    regressions: confirmedCases,
  );

  forAll(
    'P6 one byte changed outside the declared scope is refused',
    editCases,
    (c) {
      for (final (index, step) in runEdits(c).indexed) {
        _expectMutantRefused(step, Rand(c.pick + index));
      }
    },
    regressions: confirmedCases,
  );
}

void _expectInsideScope(EditStep step) {
  final outcome = step.outcome;
  if (outcome is! EditLanded) return;
  expect(
    changeOutsideScope(
      previous: utf8.encode(step.before),
      next: utf8.encode(outcome.landed.text),
      scope: outcome.landed.scope,
    ),
    isNull,
    reason: '${step.spec}\nbefore:\n${step.before}\nafter:\n${step.after}',
  );
}

/// The landed text with one letter or digit changed in a game the scope
/// carries over untouched, or in a heading it does not say it wrote.
void _expectMutantRefused(EditStep step, Rand r) {
  final outcome = step.outcome;
  if (outcome is! EditLanded) return;
  final after = wholeFile(outcome.landed.text);
  final bytes = utf8.encode(outcome.landed.text);
  final at = [
    for (final (from, to) in _outsideScope(after, outcome.games))
      for (var i = from; i < to; i++)
        if (_isAlnum(bytes[i])) i,
  ];
  if (at.isEmpty) return;
  final flipped = [...bytes];
  final i = r.pick(at);
  flipped[i] = bytes[i] == 0x61 ? 0x62 : 0x61;
  expect(
    changeOutsideScope(
      previous: utf8.encode(step.before),
      next: flipped,
      scope: outcome.landed.scope,
    ),
    isNotNull,
    reason: '${step.spec}: byte $i of\n${utf8.decode(flipped)}',
  );
}

/// Byte ranges of [after]'s text the arrangement [games] promises to carry
/// over as they were: each game kept and not rewritten, and the heading
/// when the edit did not write it.
List<(int, int)> _outsideScope(Chapter after, GamesArranged games) {
  final spans = <(int, int)>[];
  var at = utf8.encode(after.preamble).length;
  if (!games.heading && at > 0) spans.add((0, at));
  for (final (place, line) in after.lines.indexed) {
    final length = utf8.encode(line.text).length;
    final from = place < games.order.length ? games.order[place] : null;
    if (from != null && !games.rewritten.contains(from)) {
      spans.add((at, at + length));
    }
    at += length + utf8.encode(line.trailer).length;
  }
  return spans;
}

bool _isAlnum(int byte) =>
    (byte >= 0x30 && byte <= 0x39) ||
    (byte >= 0x41 && byte <= 0x5a) ||
    (byte >= 0x61 && byte <= 0x7a);
