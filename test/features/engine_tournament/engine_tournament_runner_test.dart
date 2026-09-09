/// The whole-tournament loop against scripted shell engines.
///
/// `EngineTournamentRunner` launches its processes itself (`UciEngine.launch`
/// has no seam), so these run tiny `/bin/sh` scripts that speak just enough
/// UCI to play a fixed line — the same device `engine_verification_test.dart`
/// uses. Every script appends to a launch log on start and a quit log on
/// `quit`, which is how the tests know processes were actually started and
/// actually stopped rather than merely forgotten.
@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:chess_auto_prep/core/pgn/pgn_collection_helpers.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/adjudication_rules.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/engine_spec.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/stored_tournament.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/time_control.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/tournament_config.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/engine_tournament_runner.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/tournament_store.dart';
import 'package:chess_auto_prep/models/game_outcome.dart';
import 'package:chess_auto_prep/services/crosstable_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// How a scripted engine answers `go`.
enum _Behaviour {
  /// Play the fool's mate line by ply, whichever colour it holds — so every
  /// game is `1. f3 e5 2. g4 Qh4#` and Black always wins.
  foolsMate,

  /// Always answer `e2e5`, which is never legal.
  liar,

  /// Exit the process instead of answering.
  quitter,
}

const _foolsMate = 'f2f3 e7e5 g2g4 d8h4';

/// Scripted UCI engine as a shell script. `$moves` tracks the moves in the
/// last `position` command so the reply can be chosen by ply.
String _script({
  required String name,
  required _Behaviour behaviour,
  required String launchLog,
  required String quitLog,
}) {
  final body = switch (behaviour) {
    _Behaviour.foolsMate =>
      '''
      n=0; for m in \$moves; do n=\$((n+1)); done
      set -- $_foolsMate
      i=0; best="(none)"
      for m in "\$@"; do if [ "\$i" -eq "\$n" ]; then best="\$m"; fi; i=\$((i+1)); done
      echo "info depth 1 score cp 0"
      echo "bestmove \$best"''',
    _Behaviour.liar => 'echo "bestmove e2e5"',
    _Behaviour.quitter => 'exit 1',
  };
  return '''
#!/bin/sh
echo launch >> "$launchLog"
moves=""
while read -r line; do
  case "\$line" in
    uci) echo "id name $name"; echo "id author test"
         echo "option name Hash type spin default 16 min 1 max 1024"
         echo "uciok" ;;
    isready) echo "readyok" ;;
    position*) case "\$line" in
      *" moves "*) moves="\${line#* moves }" ;;
      *) moves="" ;;
    esac ;;
    go*)
$body
      ;;
    quit) echo quit >> "$quitLog"; exit 0 ;;
  esac
done
''';
}

class _Rig {
  _Rig(this.temp);

  final Directory temp;

  late final store = TournamentStore(Directory(p.join(temp.path, 'store')));
  String get launchLog => p.join(temp.path, 'launches.log');
  String get quitLog => p.join(temp.path, 'quits.log');

  Future<int> get launches => _count(launchLog);
  Future<int> get quits => _count(quitLog);

  Future<int> _count(String path) async {
    final file = File(path);
    if (!await file.exists()) return 0;
    return (await file.readAsLines()).where((l) => l.isNotEmpty).length;
  }

  Future<EngineSpec> engine(String name, _Behaviour behaviour) async {
    final file = File(p.join(temp.path, name.toLowerCase()));
    await file.writeAsString(
      _script(
        name: name,
        behaviour: behaviour,
        launchLog: launchLog,
        quitLog: quitLog,
      ),
    );
    await Process.run('chmod', ['+x', file.path]);
    return EngineSpec(id: name, name: name, executablePath: file.path);
  }

  EngineTournamentRunner runner({ExecutableResolver? resolve}) =>
      EngineTournamentRunner(
        store: store,
        resolveExecutable: resolve ?? (spec) async => spec.executablePath!,
      );
}

TournamentConfig _config(
  List<EngineSpec> engines, {
  int gamesPerPairing = 2,
  int concurrency = 1,
}) => TournamentConfig(
  name: 'Runner test',
  engines: engines,
  gamesPerPairing: gamesPerPairing,
  concurrency: concurrency,
  // Generous: a shell script answers in milliseconds, but a loaded box
  // must not turn a scripted move into a time forfeit.
  timeControl: const TimeControl.perMove(2000),
  adjudication: AdjudicationRules.none,
);

void main() {
  late _Rig rig;

  setUp(() async {
    rig = _Rig(await Directory.systemTemp.createTemp('tournament_runner'));
  });

  tearDown(() async {
    if (await rig.temp.exists()) await rig.temp.delete(recursive: true);
  });

  test('colours alternate and each engine is credited by index', () async {
    final a = await rig.engine('Alpha', _Behaviour.foolsMate);
    final b = await rig.engine('Beta', _Behaviour.foolsMate);
    final created = await rig.store.create(_config([a, b]));

    final finished = await rig.runner().run(created);

    expect(finished.status, TournamentStatus.completed);
    expect(finished.error, isNull);
    expect(finished.games.length, 2);
    final first = finished.games[0], second = finished.games[1];
    expect((first.whiteIndex, first.blackIndex), (0, 1));
    expect((second.whiteIndex, second.blackIndex), (1, 0));
    expect((second.whiteName, second.blackName), ('Beta', 'Alpha'));
    expect(
      finished.games.map((g) => g.result),
      everyElement(GameResult.blackWins),
    );
    expect(
      finished.games.map((g) => g.termination),
      everyElement(TerminationReason.checkmate),
    );
    expect(finished.games.map((g) => g.plies), [4, 4]);
    expect(finished.games.map((g) => g.gameIndex), [0, 1]);

    // Black won both, so Beta took game 1 and Alpha took game 2.
    final table = buildCrosstable(['Alpha', 'Beta'], finished.games);
    final byIndex = {for (final r in table.standings) r.engineIndex: r};
    expect(byIndex[0]!.points, 1);
    expect(byIndex[1]!.points, 1);
    expect(byIndex[0]!.wins, 1);
    expect(byIndex[1]!.wins, 1);
    expect(table.cell(0, 1)!.results, ['0', '1']);

    // One process per engine per lane, and every one of them told to quit.
    expect(await rig.launches, 2);
    expect(await rig.quits, 2);
  });

  test('every game is on disk before the next one starts', () async {
    final a = await rig.engine('Alpha', _Behaviour.foolsMate);
    final b = await rig.engine('Beta', _Behaviour.foolsMate);
    final created = await rig.store.create(_config([a, b]));

    final recorded = <int>[];
    final onDiskPgnGames = <int>[];
    final onDiskStatus = <String>[];
    final finished = await rig.runner().run(
      created,
      onUpdate: (state) {
        recorded.add(state.games.length);
        // The callback fires after the write, so the disk must already agree.
        final pgn = File(state.pgnPath).readAsStringSync();
        onDiskPgnGames.add(parseMultiGamePgn(pgn).length);
        onDiskStatus.add(
          File(
                rig.store.metadataPathFor(state.id),
              ).readAsStringSync().contains('"status": "${state.status.name}"')
              ? state.status.name
              : 'stale',
        );
      },
    );

    expect(recorded, [0, 1, 2, 2]);
    expect(onDiskPgnGames, [0, 1, 2, 2]);
    expect(onDiskStatus, ['running', 'running', 'running', 'completed']);

    final reloaded = await rig.store.load(created.id);
    expect(reloaded!.status, TournamentStatus.completed);
    expect(reloaded.games.length, 2);
    expect(reloaded.finishedAt, isNotNull);

    final games = parseMultiGamePgn(
      await File(finished.pgnPath).readAsString(),
    );
    expect(games.map((g) => g.headers['Round']), ['1', '2']);
    expect(games.map((g) => g.headers['White']), ['Alpha', 'Beta']);
    expect(games.map((g) => g.headers['Result']), ['0-1', '0-1']);
    expect(games.first.pgnText, contains('1. f3 e5 2. g4 Qh4# 0-1'));
  });

  test('an engine that plays illegal moves loses with either colour', () async {
    final honest = await rig.engine('Honest', _Behaviour.foolsMate);
    final liar = await rig.engine('Liar', _Behaviour.liar);
    final created = await rig.store.create(_config([liar, honest]));

    final finished = await rig.runner().run(created);

    expect(finished.status, TournamentStatus.completed);
    expect(
      finished.games.map((g) => g.termination),
      everyElement(TerminationReason.illegalMove),
    );
    // Game 1: Liar is White and loses. Game 2: Liar is Black and loses.
    expect(finished.games.map((g) => g.result), [
      GameResult.blackWins,
      GameResult.whiteWins,
    ]);
    expect(finished.games.map((g) => g.plies), [0, 1]);
    expect(finished.games.map((g) => g.detail), everyElement(contains('Liar')));
    final table = buildCrosstable(['Liar', 'Honest'], finished.games);
    expect(table.standings.first.name, 'Honest');
    expect(table.standings.first.points, 2);
  });

  test('a crashed engine is relaunched for its next game', () async {
    final honest = await rig.engine('Honest', _Behaviour.foolsMate);
    final quitter = await rig.engine('Quitter', _Behaviour.quitter);
    final created = await rig.store.create(_config([quitter, honest]));

    final finished = await rig.runner().run(created);

    expect(finished.status, TournamentStatus.completed);
    expect(
      finished.games.map((g) => g.termination),
      everyElement(TerminationReason.engineFailure),
    );
    expect(finished.games.map((g) => g.result), [
      GameResult.blackWins,
      GameResult.whiteWins,
    ]);
    expect(
      finished.games.map((g) => g.detail),
      everyElement(contains('Quitter')),
    );
    // Honest once, Quitter once per game.
    expect(await rig.launches, 3);
    // Only the survivor is around to be told to quit.
    expect(await rig.quits, 1);
  });

  test('stopping records the interrupted game and stops the engines', () async {
    final a = await rig.engine('Alpha', _Behaviour.foolsMate);
    final b = await rig.engine('Beta', _Behaviour.foolsMate);
    final created = await rig.store.create(_config([a, b], gamesPerPairing: 4));
    final runner = rig.runner();

    final started = <int>[];
    final finished = await runner.run(
      created,
      onGameStarted: (slot) {
        started.add(slot.index);
        if (slot.index == 1) runner.cancel();
      },
    );

    expect(runner.isCancelled, isTrue);
    expect(finished.status, TournamentStatus.cancelled);
    expect(started, [0, 1]);
    // The interrupted game is filed, unfinished, so the PGN and the table
    // agree about what was played; nothing after it is touched.
    expect(finished.games.length, 2);
    expect(finished.games.last.termination, TerminationReason.aborted);
    expect(finished.games.last.result, GameResult.unfinished);
    expect(finished.games.last.plies, 0);
    expect(
      (await rig.store.load(created.id))!.status,
      TournamentStatus.cancelled,
    );
    expect(await rig.quits, 2);
  });

  test('a launch failure after a played game keeps that game', () async {
    final honest = await rig.engine('Honest', _Behaviour.foolsMate);
    final quitter = await rig.engine('Quitter', _Behaviour.quitter);
    final created = await rig.store.create(_config([quitter, honest]));

    // Game 1 launches both; Quitter dies, so game 2 asks for it again — and
    // this time the binary is gone.
    var resolved = 0;
    final finished = await rig
        .runner(
          resolve: (spec) async {
            resolved++;
            if (resolved > 2) return p.join(rig.temp.path, 'missing');
            return spec.executablePath!;
          },
        )
        .run(created);

    expect(finished.status, TournamentStatus.failed);
    expect(finished.error, contains('cannot start'));
    expect(finished.games.length, 1);
    expect(finished.games.single.termination, TerminationReason.engineFailure);
    expect((await rig.store.load(created.id))!.error, finished.error);
    expect(await rig.quits, 1);
  });

  test('concurrent lanes keep the file in schedule order', () async {
    final a = await rig.engine('Alpha', _Behaviour.foolsMate);
    final b = await rig.engine('Beta', _Behaviour.foolsMate);
    final created = await rig.store.create(
      _config([a, b], gamesPerPairing: 4, concurrency: 2),
    );

    final finished = await rig.runner().run(created);

    expect(finished.status, TournamentStatus.completed);
    expect(finished.games.map((g) => g.gameIndex), [0, 1, 2, 3]);
    expect(finished.games.map((g) => g.round), [1, 2, 3, 4]);
    expect(finished.games.map((g) => g.whiteName), [
      'Alpha',
      'Beta',
      'Alpha',
      'Beta',
    ]);
    final games = parseMultiGamePgn(
      await File(finished.pgnPath).readAsString(),
    );
    expect(games.map((g) => g.headers['Round']), ['1', '2', '3', '4']);
    expect(games.map((g) => g.headers['White']), [
      'Alpha',
      'Beta',
      'Alpha',
      'Beta',
    ]);
    // Two lanes, two engines each — and all four told to quit.
    expect(await rig.launches, 4);
    expect(await rig.quits, 4);
  });

  test('fewer than two engines fails before touching a process', () async {
    final a = await rig.engine('Alpha', _Behaviour.foolsMate);
    final created = await rig.store.create(_config([a]));

    final finished = await rig.runner().run(created);

    expect(finished.status, TournamentStatus.failed);
    expect(finished.error, contains('two engines'));
    expect((await rig.store.load(created.id))!.status, TournamentStatus.failed);
    expect(await rig.launches, 0);
  });
}
