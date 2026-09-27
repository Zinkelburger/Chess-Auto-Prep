import 'package:chess_auto_prep/v2/chess/players/player.dart';
import 'package:chess_auto_prep/v2/engines/engine_line.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/features/players/player_analysis.dart';
import 'package:chess_auto_prep/v2/features/players/player_hunt.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/my_games_files.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/player_reports.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_engine.dart';
import '../../support/scripted_store.dart';
import '../../support/my_games_fixture.dart';

const _game =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlayerAnalysis analysis;
  late PlayerHunt hunt;
  late ScriptedEngine engine;
  late PlayerReports reports;
  late Player player;
  setUp(() async {
    final store = ScriptedDocumentStore();
    const ref = DocumentRef('/p.pgn');
    store.documents[ref] = Opened(_game, scriptedRevision(_game));
    analysis = PlayerAnalysis(
      documents: store,
      archive: ScriptedGameStore(),
      cache: GamesCache(store, folder: '/cache'),
      sites: const [],
      pending: PendingWrites(),
      collections: '/collections',
    );
    engine = ScriptedEngine();
    reports = PlayerReports();
    hunt = PlayerHunt(analysis, () async => Started(engine), reports: reports)
      ..limit = 1;
    player = Player.create('Alex').edited({
      'pgn_files': [ref.path],
    });
    await analysis.select(player);
    await pumpEventQueue();
  });
  tearDown(() {
    hunt.dispose();
    analysis.dispose();
  });
  test(
    'engine signs are relative to the player and cached for this corpus',
    () async {
      final running = hunt.start();
      await pumpEventQueue();
      engine.current.emit(
        line(depth: 14, score: const Centipawns(-125), pv: ['g1f3']),
      );
      engine.current.end();
      await running;
      await analysis.pending.settle();
      expect(hunt.findings.single.score.text, '-1.25');
      expect(engine.quitCalled, true);
      await analysis.select(player);
      await pumpEventQueue();
      expect(hunt.findings.single.position.side, Side.white);
      expect(analysis.evals.values, contains(-125));
    },
  );
  test(
    'unseen best reply is evidence of an uncovered move, with correct sign',
    () async {
      analysis.configure(minPly: 1);
      await pumpEventQueue();
      final running = hunt.start();
      await pumpEventQueue();
      engine.current.emit(
        line(depth: 14, score: const Centipawns(80), pv: ['c7c5']),
      );
      engine.current.end();
      await running;
      expect(hunt.findings.single.unseen, true);
      expect(hunt.findings.single.score.text, '-0.80');
    },
  );
  test(
    'switching colour cancels the job without publishing into the other colour',
    () async {
      final running = hunt.start();
      await pumpEventQueue();
      analysis.setSide(Side.black);
      await running;
      await pumpEventQueue();
      expect(hunt.running, false);
      expect(hunt.findings, isEmpty);
      expect(hunt.done, 0);
      expect(engine.quitCalled, true);
      expect(analysis.evals, isEmpty);
    },
  );
  test(
    'a truncated engine search is a failure, never a level evaluation',
    () async {
      final running = hunt.start();
      await pumpEventQueue();
      engine.current.emit(line(depth: 5, score: const Centipawns(-200)));
      engine.current.end();
      await running;
      expect(hunt.error, contains('requested depth'));
      expect(analysis.evals, isEmpty);
    },
  );
  test('mate cache scores keep both sides of mate zero', () {
    expect((scoreFromPacked(10000) as MateIn).mating, true);
    expect((scoreFromPacked(-10000) as MateIn).mating, false);
  });
}
