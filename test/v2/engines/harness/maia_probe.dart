// A human sanity check of the whole opponent model, not an automatic test:
// it loads the 45 MB network and prints what it expects a 2200 to play, from
// the start and as Black after 1.e4. e2e4 and d2d4 should be far ahead of
// everything else, and Black's answer should be in Black's own moves, which
// is the mirror going out and coming back.
//
// `package:onnxruntime` reaches Flutter, so this cannot run under plain
// `dart run`; and the runtime ships inside the app bundle rather than on the
// system, so its folder has to be named:
//
//   scripts/ci.sh with -- env \
//     LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib \
//     ~/sdk/flutter/bin/flutter test test/v2/engines/harness/maia_probe.dart
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/maia/maia_model.dart';
import 'package:chess_auto_prep/v2/engines/maia/move_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const Fen _afterE4 = Fen(
  'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
);

Future<MaiaModel> _load() async {
  final load = await MaiaModel.load(
    model: File('assets/maia3_simplified.onnx').readAsBytesSync(),
    moveVocabulary: File('assets/data/all_moves_maia3.json').readAsStringSync(),
  );
  return switch (load) {
    MaiaUnavailable(:final reason) => fail(reason),
    MaiaReady(:final model) => model,
  };
}

Future<Map<String, double>> _shares(MaiaModel model, Fen fen) async {
  final answer = await model.policy(fen, 2200);
  return switch (answer) {
    MaiaFailed(:final reason) => fail(reason),
    MaiaPolicy(:final shares) => shares,
  };
}

void _print(String what, Map<String, double> shares) {
  // ignore: avoid_print
  print(
    '$what: ${shares.entries.take(6).map((e) => '${e.key} '
        '${(e.value * 100).toStringAsFixed(1)}%').join(', ')}',
  );
}

void main() {
  test('what a 2200 plays', () async {
    final model = await _load();
    final start = await _shares(model, Fen.initial);
    final black = await _shares(model, _afterE4);
    final again = await _shares(model, Fen.initial);
    model.dispose();

    _print('from the start', start);
    _print('as Black after 1.e4', black);
    expect(start.keys.take(2), containsAll(['e2e4', 'd2d4']));
    expect(black.keys.take(3), contains('e7e5'));
    expect(
      again,
      start,
      reason: 'the same question twice has to give the same numbers',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
