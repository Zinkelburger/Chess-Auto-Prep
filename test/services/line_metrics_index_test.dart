import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/models/trap_line_info.dart';
import 'package:chess_auto_prep/services/line_metrics_helpers.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// The lines browser re-derives metrics on every change to the line list, so
/// the pass is incremental.  What it may reuse is the question these pin: a
/// line the controller handed back untouched, and nothing else — an edit
/// rebuilds a line as a new object under the *same id*, so reuse keyed on the
/// id would leave its quality, bottleneck and trap counts describing moves it
/// no longer has.
void main() {
  RepertoireLine line(String id, List<String> moves) => RepertoireLine(
    id: id,
    name: id,
    moves: moves,
    color: 'white',
    startPosition: Chess.initial,
    fullPgn: '',
  );

  TrapLineInfo trap(List<String> moves) => TrapLineInfo(
    movesSan: moves,
    trapScore: 0.5,
    popularProb: 0.4,
    popularMove: 'Nd7',
    bestMove: 'b4',
    popularEvalCp: 252,
    bestEvalCp: 10,
    evalDiffCp: 200,
    cumulativeProb: 0.01,
    trickSurplus: 0.08,
    expectimaxValue: 0.593,
    wpEval: 0.510,
  );

  Map<String, LineQualityInfo> index(
    List<RepertoireLine> lines, {
    List<TrapLineInfo> traps = const [],
    Map<String, LineQualityInfo>? previous,
    List<RepertoireLine>? previousLines,
  }) => buildLineMetricsIndex(
    lines: lines,
    treeRoot: null,
    isWhiteRepertoire: true,
    traps: traps,
    previous: previous,
    previousLines: previousLines,
  );

  // A trap sitting on 1.e4 e5, so a line that plays it counts one and a line
  // that plays something else counts none.
  final traps = [
    trap(['e4', 'e5']),
  ];

  test('derives every line when there is nothing to carry over', () {
    final lines = [
      line('a', ['e4', 'e5']),
      line('b', ['d4', 'd5']),
    ];

    final result = index(lines, traps: traps);

    expect(result.keys, unorderedEquals(['a', 'b']));
    expect(result['a']!.trapCount, 1);
    expect(result['b']!.trapCount, 0);
  });

  test('carries over a line the controller handed back untouched', () {
    final kept = line('a', ['e4', 'e5']);
    final first = index([kept], traps: traps);

    // Re-run with no traps at all: a recomputed entry would read 0, so the
    // old count surviving is what proves it was reused rather than derived.
    final second = index(
      [
        kept,
        line('b', ['d4', 'd5']),
      ],
      previous: first,
      previousLines: [kept],
    );

    expect(second['a']!.trapCount, 1, reason: 'reused, not recomputed');
    expect(second['b']!.trapCount, 0, reason: 'new line, derived');
  });

  test('recomputes a line that was edited under the same id', () {
    final before = line('a', ['e4', 'e5']);
    final first = index([before], traps: traps);
    expect(first['a']!.trapCount, 1);

    // The edit: same id, new object, different moves — the trap no longer
    // applies.  Reuse keyed on the id would keep the stale count of 1.
    final after = line('a', ['d4', 'd5']);
    final second = index(
      [after],
      traps: traps,
      previous: first,
      previousLines: [before],
    );

    expect(second['a']!.trapCount, 0);
  });

  test('an edit does not disturb its untouched siblings', () {
    final keptA = line('a', ['e4', 'e5']);
    final keptC = line('c', ['e4', 'e5']);
    final beforeB = line('b', ['d4', 'd5']);
    final first = index([keptA, beforeB, keptC], traps: traps);

    final afterB = line('b', ['e4', 'e5']);
    final second = index(
      [keptA, afterB, keptC],
      traps: traps,
      previous: first,
      previousLines: [keptA, beforeB, keptC],
    );

    expect(second['b']!.trapCount, 1, reason: 'edited: re-derived');
    expect(identical(second['a'], first['a']), isTrue);
    expect(identical(second['c'], first['c']), isTrue);
  });

  test('drops metrics for lines that are gone', () {
    final a = line('a', ['e4', 'e5']);
    final b = line('b', ['d4', 'd5']);
    final first = index([a, b], traps: traps);

    final second = index([a], previous: first, previousLines: [a, b]);

    expect(second.keys, ['a']);
  });

  test('an unchanged list re-derives nothing', () {
    final lines = [
      line('a', ['e4', 'e5']),
      line('b', ['d4', 'd5']),
    ];
    final first = index(lines, traps: traps);

    final second = index(lines, previous: first, previousLines: lines);

    expect(identical(second['a'], first['a']), isTrue);
    expect(identical(second['b'], first['b']), isTrue);
  });

  test('fills in a line the previous pass never saw', () {
    final a = line('a', ['e4', 'e5']);
    final b = line('b', ['e4', 'e5']);
    // `previous` is missing 'b' even though `previousLines` lists it — the
    // state a failed or partial earlier pass leaves behind.
    final partial = index([a], traps: traps);

    final second = index(
      [a, b],
      traps: traps,
      previous: partial,
      previousLines: [a, b],
    );

    expect(second['b'], isNotNull);
    expect(second['b']!.trapCount, 1);
  });
}
