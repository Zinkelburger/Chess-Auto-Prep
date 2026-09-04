import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/game_analysis_controller.dart';

MoveEval _eval(String san) => MoveEval(
  ply: 1,
  san: san,
  fenBefore: 'before-$san',
  fenAfter: 'after-$san',
  winningChance: 0,
);

CachedGameAnalysis _analysis(String san) =>
    (evals: [_eval(san)], startWinChance: 0, totalMoves: 1);

void main() {
  test('a slower cached parse cannot replace the newest game', () async {
    final pending = <String, Completer<CachedGameAnalysis?>>{};
    final controller = GameAnalysisController(
      cachedAnalysisLoader: (pgn) =>
          (pending[pgn] ??= Completer<CachedGameAnalysis?>()).future,
    );
    addTearDown(controller.dispose);

    final oldLoad = controller.tryLoadFromPgn('old');
    final newLoad = controller.tryLoadFromPgn('new');

    pending['new']!.complete(_analysis('new'));
    expect(await newLoad, isTrue);
    expect(controller.evals.single.san, 'new');

    pending['old']!.complete(_analysis('old'));
    expect(await oldLoad, isFalse, reason: 'the old request is stale');
    expect(
      controller.evals.single.san,
      'new',
      reason: 'late work must not land on the selected game',
    );
  });

  test('cancel invalidates an in-flight cached parse', () async {
    final pending = Completer<CachedGameAnalysis?>();
    final controller = GameAnalysisController(
      cachedAnalysisLoader: (_) => pending.future,
    );
    addTearDown(controller.dispose);

    final load = controller.tryLoadFromPgn('game');
    controller.cancel();
    pending.complete(_analysis('stale'));

    expect(await load, isFalse);
    expect(controller.evals, isEmpty);
    expect(controller.isAnalyzing, isFalse);
  });
}
