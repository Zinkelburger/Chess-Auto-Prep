import 'dart:io';

import 'package:chess_auto_prep/core/pgn/pgn_collection_helpers.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/engine_spec.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/stored_tournament.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/time_control.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/tournament_config.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/tournament_game.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/tournament_store.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter_test/flutter_test.dart';

const _fen = '3r2k1/p4p2/7p/3pB1p1/8/P3P2P/1P3PP1/6K1 b - - 0 1';

TournamentConfig _config() => const TournamentConfig(
  name: 'Endgame match',
  startFen: _fen,
  openingLabel: 'Rook vs bishop ending',
  timeControl: TimeControl.perMove(2000),
  gamesPerPairing: 4,
  engines: [
    EngineSpec(id: 'a', name: 'Engine A', executablePath: '/bin/a'),
    EngineSpec(id: 'b', name: 'Engine B', executablePath: '/bin/b'),
  ],
);

TournamentGameRecord _record(int index) => TournamentGameRecord(
  gameIndex: index,
  round: index + 1,
  whiteIndex: index.isEven ? 0 : 1,
  blackIndex: index.isEven ? 1 : 0,
  whiteName: index.isEven ? 'Engine A' : 'Engine B',
  blackName: index.isEven ? 'Engine B' : 'Engine A',
  result: GameResult.draw,
  termination: TerminationReason.drawAdjudication,
  detail: 'level for 8 moves',
  plies: 60,
  startedAt: DateTime(2026, 8, 22, 12, index),
  durationMs: 42000,
);

void main() {
  late Directory root;
  late TournamentStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tournament_store_test');
    store = TournamentStore(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('a new tournament gets a slug directory and an empty PGN', () async {
    final tournament = await store.create(_config());
    expect(tournament.id, 'endgame-match');
    expect(await File(tournament.pgnPath).exists(), isTrue);
    expect(tournament.status, TournamentStatus.pending);
    expect(tournament.gamesTotal, 4);
  });

  test('a second tournament of the same name does not collide', () async {
    final first = await store.create(_config());
    final second = await store.create(_config());
    expect(second.id, isNot(first.id));
    expect((await store.list()).length, 2);
  });

  test('config and games survive the round trip', () async {
    final created = await store.create(_config());
    await store.save(
      created.copyWith(
        status: TournamentStatus.completed,
        games: [_record(0), _record(1)],
        finishedAt: DateTime(2026, 8, 22, 13),
      ),
    );

    final loaded = await store.load(created.id);
    expect(loaded, isNotNull);
    expect(loaded!.status, TournamentStatus.completed);
    expect(loaded.config.startFen, _fen);
    expect(loaded.config.openingLabel, 'Rook vs bishop ending');
    expect(loaded.config.timeControl.label, '2s/move');
    expect(loaded.games.length, 2);
    expect(loaded.games.first.termination, TerminationReason.drawAdjudication);
    expect(loaded.games.first.detail, 'level for 8 moves');
  });

  test(
    'a run cut short by a crash reads back as stopped, not running',
    () async {
      final created = await store.create(_config());
      await store.save(created.copyWith(status: TournamentStatus.running));
      final file = File(store.metadataPathFor(created.id));
      // Simulate the field being absent, as an older or partial write would be.
      await file.writeAsString(
        (await file.readAsString()).replaceAll('"status": "running",', ''),
      );
      expect(
        (await store.load(created.id))!.status,
        TournamentStatus.cancelled,
      );
    },
  );

  test(
    'an unreadable tournament hides itself instead of breaking the list',
    () async {
      final good = await store.create(_config());
      final broken = await store.create(_config().copyWith(name: 'Broken'));
      await File(store.metadataPathFor(broken.id)).writeAsString('{ not json');
      final listed = await store.list();
      expect(listed.map((t) => t.id), [good.id]);
    },
  );

  test('deleting takes the directory with it', () async {
    final created = await store.create(_config());
    await store.delete(created.id);
    expect(await Directory(created.directoryPath).exists(), isFalse);
    expect(await store.list(), isEmpty);
  });

  group('the PGN it writes is the collection the viewer opens', () {
    late String pgnPath;

    setUp(() async {
      final created = await store.create(_config());
      pgnPath = created.pgnPath;
      await store.writeGamesPgn(created.id, [
        '[Event "Endgame match"]\n[Round "1"]\n[White "Engine A"]\n'
            '[Black "Engine B"]\n[Result "1/2-1/2"]\n[FEN "$_fen"]\n'
            '[SetUp "1"]\n\n1... Rd6 {+0.10/20 2.0s} 2. Bd4 1/2-1/2\n',
        '[Event "Endgame match"]\n[Round "2"]\n[White "Engine B"]\n'
            '[Black "Engine A"]\n[Result "1-0"]\n[FEN "$_fen"]\n'
            '[SetUp "1"]\n\n1... Rd7 2. Bc7 1-0\n',
      ]);
    });

    test('parses back as one game per schedule slot, in order', () async {
      final games = parseMultiGamePgn(await File(pgnPath).readAsString());
      expect(games.length, 2);
      expect(games[0].headers['Round'], '1');
      expect(games[1].headers['Round'], '2');
      expect(games[1].headers['White'], 'Engine B');
    });

    test('replays from the position the match started from', () async {
      final games = parseMultiGamePgn(await File(pgnPath).readAsString());
      final parsed = PgnGame.parsePgn(games.first.pgnText);
      final start = PgnGame.startingPosition(parsed.headers);
      expect(start.fen, _fen);
      expect(start.turn, Side.black);
    });
  });
}
