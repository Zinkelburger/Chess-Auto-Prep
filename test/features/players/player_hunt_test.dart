import 'dart:async';
import 'dart:io';

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
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/audit_fixture.dart' show after;
import '../../support/my_games_fixture.dart' show AnsweringEngine;
import '../../support/scripted_engine.dart';
import '../../support/scripted_store.dart';
import '../../support/window_fixture.dart';

const _game =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ScriptedDocumentStore store;
  late PlayerAnalysis analysis;
  late PlayerHunt hunt;
  late ScriptedEngine engine;
  late PlayerReports reports;
  late Player player;
  setUp(() async {
    store = ScriptedDocumentStore();
    const ref = DocumentRef('/p.pgn');
    store.documents[ref] = Opened(_game, scriptedRevision(_game));
    analysis = PlayerAnalysis(
      documents: store,
      cache: GamesCache(store, folder: '/cache'),
      sites: const [],
      pending: PendingWrites(),
    );
    engine = ScriptedEngine();
    reports = PlayerReports();
    hunt = PlayerHunt(analysis, () async => Started(engine), reports: reports)
      ..configure(limit: 1);
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
    'finishing obsolete analysis preserves the selected player’s cached findings',
    () async {
      final first = player;
      const file = DocumentRef('/second.pgn');
      final text = _game.replaceFirst('Alex', 'Bea');
      store.documents[file] = Opened(text, scriptedRevision(text));
      final second = Player.create('Bea').edited({
        'pgn_files': [file.path],
      });
      await analysis.select(second);
      final caching = hunt.start();
      await pumpEventQueue();
      engine.current.emit(line(depth: 14, score: const Centipawns(-180)));
      engine.current.end();
      await caching;
      await analysis.pending.settle();
      expect(hunt.findings.single.score.text, '-1.80');

      await analysis.select(first);
      engine = ScriptedEngine();
      final oldRun = hunt.start();
      await pumpEventQueue();
      final release = store.readEarly = Completer<void>();
      engine.current.emit(line(depth: 14, score: const Centipawns(-125)));
      engine.current.end();
      await pumpEventQueue();
      expect(
        store.readEarly,
        isNull,
        reason: 'final source validation is waiting',
      );
      await analysis.select(second);
      await pumpEventQueue();
      expect(hunt.findings.single.score.text, '-1.80');
      release.complete();
      await oldRun;
      expect(analysis.player?.id, second.id);
      expect(hunt.findings.map((finding) => finding.score.text), ['-1.80']);
    },
  );

  // In-memory reports: a disk read is real I/O that pumpEventQueue does not
  // wait for.
  test('a cancelled reload of the same player restores the report', () async {
    final running = hunt.start();
    await pumpEventQueue();
    engine.current.emit(
      line(depth: 14, score: const Centipawns(-125), pv: ['g1f3']),
    );
    engine.current.end();
    await running;
    await analysis.pending.settle();
    final reload = analysis.select(player);
    expect(hunt.findings, isEmpty, reason: 'nothing shown while it loads');
    analysis.cancel();
    await reload;
    await pumpEventQueue();
    expect(analysis.corpus, isNotNull);
    expect(hunt.findings.single.score.text, '-1.25');
    expect(analysis.evals.values, contains(-125));
  });
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
    'refresh does not flag a reply played under a new alias as unseen',
    () async {
      final afterE4 = after('e2e4').position;
      final window = WindowFixture(
        launchEngine: ({required cores, required memoryMb}) async => Started(
          AnsweringEngine({
            afterE4: line(depth: 14, pv: ['c7c5']),
          }),
        ),
      );
      addTearDown(window.dispose);
      const games =
          '$_game\n\n[Event "Club"]\n[White "A. Smith"]\n[Black "Bob"]\n'
          '[Result "0-1"]\n\n1. e4 c5 0-1';
      final ref = DocumentRef(player.files.single);
      window.store.documents[ref] = Opened(games, scriptedRevision(games));
      final players = window.parts.players;
      final directory = players.directory;
      final owner = players.analysis;
      final report = players.hunt;
      await directory.save(player);
      final original = directory.players.single;
      await owner.select(original);
      expect(owner.corpus!.games, hasLength(1));
      await report.start();
      expect(report.findings.single.line, ['c7c5']);
      expect(report.findings.single.unseen, isTrue);

      await directory.save(
        original.withStrings('aliases', ['A. Smith']),
        expected: original,
      );
      await report.start();
      await owner.pending.settle();
      await owner.select(directory.players.single);
      await pumpEventQueue();

      final position = owner.corpus!.positions.singleWhere(
        (p) => p.fen.position == afterE4,
      );
      expect(position.moves, {'e7e5': 1, 'c7c5': 1});
      expect(
        report.findings.where((f) => f.unseen).map((f) => f.line.first),
        isNot(contains('c7c5')),
      );
    },
  );
  test('an obsolete Maia failure leaves practical probes enabled', () async {
    final model = _WaitingPolicy();
    hunt.dispose();
    hunt = PlayerHunt(analysis, () async => Started(engine), model: model)
      ..configure(limit: 1, practical: true);
    analysis.configure(minPly: 1);
    await pumpEventQueue();
    final running = hunt.start();
    await pumpEventQueue();
    engine.current.emit(line(depth: 14, pv: ['c7c5']));
    engine.current.end();
    await model.asked.future;
    hunt.stop();
    model.answer.complete(const MaiaFailed('late failure'));
    await running;
    expect(hunt.practicalWarning, isNull);
  });

  test('a castle the games played is not an unseen reply', () async {
    // The engine names castling king to its square (e8g8); the games name
    // it king onto rook (e8h8). Both are the reply these games met.
    const castled =
        '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Result "1-0"]\n\n'
        '1. e4 e5 2. Nf3 Nf6 3. Bc4 Be7 4. d3 O-O 1-0';
    final store = ScriptedDocumentStore();
    const ref = DocumentRef('/castled.pgn');
    store.documents[ref] = Opened(castled, scriptedRevision(castled));
    final owner = PlayerAnalysis(
      documents: store,
      cache: GamesCache(store, folder: '/cache'),
      sites: const [],
      pending: PendingWrites(),
    );
    final castleHunt = PlayerHunt(
      owner,
      () async => Started(engine),
      reports: reports,
    )..configure(limit: 1);
    addTearDown(() {
      castleHunt.dispose();
      owner.dispose();
    });
    await owner.select(
      Player.create('Alex').edited({
        'pgn_files': [ref.path],
      }),
    );
    owner.configure(minPly: 7);
    await pumpEventQueue();
    final running = castleHunt.start();
    await pumpEventQueue();
    engine.current.emit(
      line(depth: 14, score: const Centipawns(20), pv: ['e8g8']),
    );
    engine.current.end();
    await running;
    expect(castleHunt.error, isNull);
    expect(castleHunt.findings, isEmpty);
  });
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
  test('settings do not change while a run is going', () async {
    final running = hunt.start();
    await pumpEventQueue();
    hunt.configure(depth: 20, limit: 5, practical: true);
    expect((hunt.depth, hunt.limit, hunt.practical), (14, 1, false));
    expect(hunt.running, true);
    engine.current.emit(
      line(depth: 14, score: const Centipawns(-125), pv: ['g1f3']),
    );
    engine.current.end();
    await running;
    expect(hunt.findings, isNotEmpty);
    expect(hunt.error, isNull);
  });
  group('with reports on disk', () {
    late PlayerAnalysis owner;
    late PlayerHunt diskHunt;
    late Player alex;
    setUp(() async {
      final folder = Directory.systemTemp.createTempSync('player_reports');
      addTearDown(() => folder.deleteSync(recursive: true));
      final store = ScriptedDocumentStore();
      const ref = DocumentRef('/p.pgn');
      store.documents[ref] = Opened(_game, scriptedRevision(_game));
      owner = PlayerAnalysis(
        documents: store,
        cache: GamesCache(store, folder: '/cache'),
        sites: const [],
        pending: PendingWrites(),
      );
      diskHunt = PlayerHunt(
        owner,
        () async => Started(engine),
        reports: PlayerReports(folder),
      )..configure(limit: 1);
      alex = Player.create('Alex').edited({
        'pgn_files': [ref.path],
      });
      await owner.select(alex);
      await pumpEventQueue();
    });
    tearDown(() {
      diskHunt.dispose();
      owner.dispose();
    });
    test('a finished run keeps its results after a setting changed', () async {
      diskHunt.configure(depth: 16);
      final running = diskHunt.start();
      await pumpEventQueue();
      engine.current.emit(
        line(depth: 16, score: const Centipawns(-125), pv: ['g1f3']),
      );
      engine.current.end();
      await running;
      await owner.pending.settle();
      await pumpEventQueue();
      expect(diskHunt.findings, isNotEmpty);
      expect((diskHunt.done, diskHunt.total), (1, 1));
      expect(owner.evals.values, contains(-125));
    });
  });
  test('mate cache scores keep both sides of mate zero', () {
    expect((scoreFromPacked(10000) as MateIn).mating, true);
    expect((scoreFromPacked(-10000) as MateIn).mating, false);
  });
}

final class _WaitingPolicy implements MovePolicy {
  final asked = Completer<void>();
  final answer = Completer<MaiaAnswer>();

  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) {
    asked.complete();
    return answer.future;
  }
}
