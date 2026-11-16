// The engine hunt over a player's positions, in the small: a position at
// exactly -0.50 is a finding, a run starts once and only over games read,
// the best line is the first, and the practical probe looks at the moves
// within half a pawn of the best on the opponent's turn, three of them,
// counted afresh each run.
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/engines/engine_line.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/maia/move_policy.dart';
import 'package:chess_auto_prep/features/players/player_analysis.dart';
import 'package:chess_auto_prep/features/players/player_hunt.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/my_games_files.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/player_reports.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_engine.dart';
import '../../support/scripted_store.dart';

const _game =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Result "1-0"]\n\n'
    '1. e4 e5 2. Nf3 Nc6 1-0';

/// Every reply is the same one move, for certain.
class _Policy implements MovePolicy {
  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) async =>
      const MaiaPolicy({'g1f3': 1});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlayerAnalysis analysis;
  late ScriptedEngine engine;
  late Player player;
  var launches = 0;

  setUp(() async {
    launches = 0;
    final store = ScriptedDocumentStore();
    const ref = DocumentRef('/p.pgn');
    store.documents[ref] = Opened(_game, scriptedRevision(_game));
    analysis = PlayerAnalysis(
      documents: store,
      cache: GamesCache(store, folder: '/cache'),
      sites: const [],
      pending: PendingWrites(),
    );
    addTearDown(analysis.dispose);
    engine = ScriptedEngine();
    player = Player.create('Alex').edited({
      'pgn_files': [ref.path],
    });
  });

  PlayerHunt hunt({MovePolicy? model}) {
    final made = PlayerHunt(
      analysis,
      () async {
        launches++;
        return Started(engine);
      },
      model: model,
      reports: PlayerReports(),
    )..configure(limit: 1);
    addTearDown(made.dispose);
    return made;
  }

  Future<void> read() async {
    await analysis.select(player);
    await pumpEventQueue();
  }

  /// Answers every open search: [first] for the first search of the run,
  /// [probe] for each one after it.
  Future<void> answer(
    PlayerHunt hunt, {
    required List<EngineLine> first,
    EngineLine? probe,
  }) async {
    for (var i = 0; i < 40 && hunt.running; i++) {
      await pumpEventQueue();
      for (final (n, search) in engine.searches.indexed) {
        if (search.ended) continue;
        for (final line in n == 0 ? first : [probe!]) {
          search.emit(line);
        }
        search.end();
      }
    }
    await pumpEventQueue();
  }

  test('a hunt does not start without games read', () async {
    final h = hunt();
    await h.start();
    expect(launches, 0);
    expect(h.running, isFalse);
    expect(h.error, isNull, reason: 'nothing was asked');
  });

  test('a hunt does not start while the games are being read', () async {
    final reading = analysis.select(player);
    expect(analysis.busy, isTrue);
    final h = hunt();
    await h.start();
    expect(launches, 0);
    await reading;
  });

  test('an unseen reply that leaves the player better than +0.30 is no '
      'finding', () async {
    analysis.configure(minPly: 1);
    await read();
    final h = hunt();
    final running = h.start();
    await pumpEventQueue();
    engine.current
      ..emit(line(depth: 14, score: const Centipawns(-31), pv: ['c7c5']))
      ..end();
    await running;
    expect(h.findings, isEmpty);
  });

  test('a hunt under way is not started again', () async {
    await read();
    final h = hunt();
    final running = h.start();
    await pumpEventQueue();
    await h.start();
    expect(launches, 1);
    engine.current
      ..emit(line(depth: 14, score: const Centipawns(-50), pv: ['g1f3']))
      ..end();
    await running;
  });

  test('a position at exactly -0.50 is a finding', () async {
    await read();
    final h = hunt();
    var told = 0;
    h.addListener(() => told++);
    final running = h.start();
    await pumpEventQueue();
    expect(told, greaterThan(0), reason: 'the start is heard');
    expect(engine.current.multiPv, 1, reason: 'the player\'s own move');
    engine.current
      ..emit(line(depth: 14, score: const Centipawns(-50), pv: ['g1f3']))
      ..end();
    await running;
    expect(h.findings, hasLength(1));
  });

  test('looks at a hundred positions unless told otherwise', () {
    final made = PlayerHunt(analysis, () async => Started(engine));
    addTearDown(made.dispose);
    expect(made.limit, 100);
  });

  group('the practical probe', () {
    /// On Black's turn after 1.e4: the best reply, one half a pawn worse,
    /// and one more than half a pawn worse.
    final lines = [
      line(depth: 14, pv: ['e7e5']),
      line(multiPv: 2, depth: 14, score: const Centipawns(-50), pv: ['c7c5']),
      line(multiPv: 3, depth: 14, score: const Centipawns(-80), pv: ['d7d5']),
    ];

    /// Two plies on, the side that chose is well ahead.
    final ahead = line(depth: 14, score: const Centipawns(300), pv: ['a2a3']);

    Future<PlayerHunt> run({PlayerHunt? again}) async {
      final h = again ?? hunt(model: _Policy());
      if (again == null) {
        analysis.configure(minPly: 1);
        h.configure(practical: true, probes: 1);
        await read();
      }
      engine = ScriptedEngine();
      final running = h.start();
      await answer(h, first: lines, probe: ahead);
      await running;
      return h;
    }

    List<PlayerWeakness> practical(PlayerHunt h) => [
      for (final f in h.findings)
        if (f.practicalGain != null) f,
    ];

    test('asks for three lines on the opponent\'s turn', () async {
      await run();
      expect(engine.searches.first.multiPv, 3);
    });

    test('keeps the best line\'s value for the position', () async {
      await run();
      expect(analysis.evals.values, contains(0));
    });

    test(
      'probes the moves within half a pawn of the best, and no other',
      () async {
        final h = await run();
        expect(practical(h), hasLength(2));
      },
    );

    test('counts its probes afresh each run', () async {
      final h = await run();
      expect(practical(h), hasLength(2));
      await run(again: h);
      expect(practical(h), hasLength(2));
    });
  });
}
