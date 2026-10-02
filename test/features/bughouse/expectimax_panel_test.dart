import 'dart:async';

import 'package:chess_auto_prep/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/chess/bughouse/table.dart';
import 'package:chess_auto_prep/engines/bughouse_backend.dart';
import 'package:chess_auto_prep/features/bughouse/bughouse_lab.dart';
import 'package:chess_auto_prep/features/bughouse/expectimax_panel.dart';
import 'package:chess_auto_prep/features/bughouse/expectimax_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BughouseBackend backend({
  Future<double> Function()? value,
  void Function()? close,
}) => BughouseBackend(
  policy: (p, b) async {
    final legal = p.legalMoves(b);
    return {for (final m in legal) m.uci: 1 / legal.length};
  },
  evaluate: (p, b) async => (
    value: value == null ? .1 : await value(),
    best: p.legalMoves(b).first.uci,
    nodes: 1500,
    depth: 8,
  ),
  close: () async => close?.call(),
);

void main() {
  testWidgets('run, inspect a move and play it; old results disappear', (
    tester,
  ) async {
    final lab = BughouseLab();
    final owner = BughouseExpectimaxSearch(
      lab: lab,
      startBackend: (_) async => backend(),
    );
    addTearDown(owner.dispose);
    addTearDown(lab.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 480,
            child: BughouseExpectimaxPanel(search: owner),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('bughouse-expectimax-run')));
    await tester.pumpAndSettle();
    expect(owner.complete, isTrue);
    expect(owner.rows, hasLength(4));
    expect(find.text('Exp W'), findsOneWidget);
    expect(find.textContaining('no clocks or sitting'), findsOneWidget);
    expect(find.text('Play move'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Play move'));
    await tester.pumpAndSettle();
    expect(lab.line.of(BoardNumber.one), hasLength(1));
    expect(owner.rows, isEmpty);
    expect(owner.complete, isFalse);
  });

  test('clock and flip do not change results; board choice does', () async {
    final lab = BughouseLab();
    final owner = BughouseExpectimaxSearch(
      lab: lab,
      startBackend: (_) async => backend(),
    );
    await owner.start();
    lab.setClock(ClockCase.abMaySit);
    lab.flip();
    expect(owner.complete, isTrue);
    owner.configure(board: BoardNumber.two);
    expect(owner.rows, isEmpty);
    await owner.start();
    expect(owner.team, Team.cd);
    expect(owner.rows.first.child.white, closeTo(-.1, 1e-9));
    owner.dispose();
    lab.dispose();
  });

  test(
    'editing during startup rejects the late backend and releases it',
    () async {
      final lab = BughouseLab();
      final ready = Completer<BughouseBackend>();
      var closed = 0;
      final owner = BughouseExpectimaxSearch(
        lab: lab,
        startBackend: (_) => ready.future,
      );
      final work = owner.start();
      await Future<void>.delayed(Duration.zero);
      lab.play(BoardNumber.one, 'e2e4');
      ready.complete(backend(close: () => closed++));
      await work;
      expect(closed, 1);
      expect(owner.rows, isEmpty);
      expect(owner.running, isFalse);
      owner.dispose();
      lab.dispose();
    },
  );

  test(
    'stop during inference publishes no incomplete row; retry starts cleanly',
    () async {
      final lab = BughouseLab();
      final ready = Completer<double>();
      var starts = 0;
      final owner = BughouseExpectimaxSearch(
        lab: lab,
        startBackend: (_) async {
          starts++;
          return starts == 1 ? backend(value: () => ready.future) : backend();
        },
      );
      final work = owner.start();
      await Future<void>.delayed(Duration.zero);
      owner.stop();
      ready.complete(.2);
      await work;
      expect(owner.rows, isEmpty);
      expect(owner.complete, isFalse);
      await owner.start();
      expect(owner.complete, isTrue);
      expect(owner.problem, isNull);
      owner.dispose();
      lab.dispose();
    },
  );

  test('native startup failure is visible and retryable', () async {
    final lab = BughouseLab();
    final owner = BughouseExpectimaxSearch(
      lab: lab,
      startBackend: (_) async => throw StateError('CrazyAra missing'),
    );
    await owner.start();
    expect(owner.problem, contains('CrazyAra missing'));
    expect(owner.running, isFalse);
    owner.dispose();
    lab.dispose();
  });
}
