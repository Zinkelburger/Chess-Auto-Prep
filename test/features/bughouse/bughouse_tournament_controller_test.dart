import 'dart:async';
import 'dart:io';
import 'package:chess_auto_prep/features/bughouse/controllers/bughouse_tournament_controller.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_tournament.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_tournament_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_bughouse_engine.dart';

void main() {
  test(
    'engine failure remains failed on disk with the partial game excluded',
    () async {
      final dir = await Directory.systemTemp.createTemp('bughouse-controller-');
      addTearDown(() => dir.delete(recursive: true));
      final store = BughouseTournamentStore(dir);
      final idle = Completer<void>();
      final engine = FakeBughouseEngine()
        ..failNextSearch = BughouseEngineFailure('test crash');
      final controller = BughouseTournamentController(
        acquireEngine: () async => engine,
        showLine: (_) {},
        onIdle: idle.complete,
        store: store,
      );
      addTearDown(controller.dispose);
      while (controller.isLoading) {
        await Future<void>.delayed(Duration.zero);
      }
      await controller.start(
        BughouseTournamentConfig(
          name: 'failure',
          startDualFen: BughouseState.initial().dualFen,
          games: 3,
        ),
      );
      await idle.future.timeout(const Duration(seconds: 10));
      final match = controller.selected!;
      expect(match.status, BughouseTournamentStatus.failed);
      expect(match.games, hasLength(1));
      expect(match.openingScore.played, 0);
      final loaded = (await store.load(match.id))!;
      expect(loaded.status, BughouseTournamentStatus.failed);
      expect(loaded.games, hasLength(1));
      expect(loaded.error, contains('test crash'));
    },
  );
}
