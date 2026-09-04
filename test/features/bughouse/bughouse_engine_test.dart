@Tags(['engine'])
library;

import 'dart:io';

import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives the real Hivemind binary. Skipped unless HIVEMIND_BIN and
/// HIVEMIND_MODEL point at a build, so CI without the engine stays green.
void main() {
  final bin = Platform.environment['HIVEMIND_BIN'];
  final model = Platform.environment['HIVEMIND_MODEL'];
  final libDir = Platform.environment['HIVEMIND_LIB'];
  final available = bin != null && model != null;

  group('BughouseEngine', () {
    late BughouseEngine engine;

    setUpAll(() async {
      if (!available) return;
      engine = await BughouseEngine.launch(
        executablePath: bin,
        modelPath: model,
        libraryPath: libDir,
      );
    });

    tearDownAll(() async {
      if (available) await engine.dispose();
    });

    test('handshakes and reports its backend', () {
      expect(engine.name, isNotEmpty);
      expect(engine.backend, isNotEmpty);
      // ignore: avoid_print
      print('engine=${engine.name} backend=${engine.backend}');
    });

    test('searches the opening and returns a joint move', () async {
      await engine.configure(team: Side.white, hasTimeAdvantage: false);
      await engine.setPosition(BughouseState.initial());
      final result = await engine.search(movetime: const Duration(seconds: 4));

      expect(result.best, isNotNull, reason: 'no bestmove parsed');
      // White is on turn on board A and not on board B, so a legal joint
      // action must move on A and pass on B.
      expect(result.best!.a.isPass, isFalse);
      expect(result.best!.b.isPass, isTrue);
      expect(result.infos, isNotEmpty);
      expect(result.lastInfo!.nodes, greaterThan(0));
      // ignore: avoid_print
      print(
        'best=${result.best} nodes=${result.lastInfo!.nodes} '
        'depth=${result.lastInfo!.depth} eval=${result.lastInfo!.scorePawns}',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('honours a node budget and a dual FEN', () async {
      const state = BughouseState(
        boardA: Crazyhouse.initial,
        boardB: Crazyhouse.initial,
      );
      await engine.setPosition(state);
      final result = await engine.search(nodes: 150);
      expect(result.best, isNotNull);
      expect(state.dualFen, contains('|'));
    }, timeout: const Timeout(Duration(minutes: 3)));
  }, skip: available ? null : 'set HIVEMIND_BIN and HIVEMIND_MODEL');
}
