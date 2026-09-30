import 'dart:io';

import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/features/tournaments/engine_check.dart';
import 'package:chess_auto_prep/features/tournaments/tournament_run.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/scripted_tournaments.dart';
import '../../support/engine_jobs_fixture.dart';

/// A shell engine that answers the handshake as `Fake 1.0` and plays [move].
String _engine(String move) =>
    '''#!/bin/sh
echo "Fake engine banner"
while read line; do
  case "\$line" in
    uci) echo "id name Fake 1.0"; echo uciok;;
    isready) echo readyok;;
    go*) echo "bestmove $move";;
    quit) exit 0;;
  esac
done
''';

void main() {
  late Directory dir;
  late EngineSupervisor engines;
  late ScriptedTournaments store;
  late TournamentRun run;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('engine-check-');
    engines = EngineSupervisor();
    store = ScriptedTournaments();
    run = TournamentRun(
      store: store,
      pending: PendingWrites(),
      jobs: await engineJobsFixture(),
      launch: (spec, transcript) => engines.start(
        spec.executable!,
        transcript: transcript,
        patience: const Duration(seconds: 1),
      ),
    );
  });

  tearDown(() async {
    run.dispose();
    await engines.dispose();
    await store.dispose();
    await dir.delete(recursive: true);
  });

  Future<String> script(
    String name,
    String text, {
    bool runnable = true,
  }) async {
    final file = File(p.join(dir.path, name));
    await file.writeAsString(text);
    if (runnable) await Process.run('chmod', ['+x', file.path]);
    return file.path;
  }

  Future<EngineCheck> check(String path) => run.verify(
    TournamentEngine({'id': 'x', 'name': 'x', 'executablePath': path}),
  );

  test(
    'a folder and a file that may not run are named before starting',
    () async {
      final folder = await check(dir.path);
      expect((folder as EngineRejected).reason, contains('is a folder'));
      expect(folder.output, isEmpty);
      final plain = await check(await script('plain', 'text', runnable: false));
      expect((plain as EngineRejected).reason, contains('is not executable'));
    },
  );

  test('silence, a crash and an illegal move each say what happened and '
      'show what the engine wrote', () async {
    final mute = await check(
      await script('mute', '#!/bin/sh\necho "usage: mute"\nsleep 30\n'),
    );
    expect(
      (mute as EngineRejected).reason,
      'mute did not answer as a UCI engine: no uciok within 1 s',
    );
    expect(mute.output, ['usage: mute']);

    final slow = await check(
      await script(
        'slow',
        '#!/bin/sh\nwhile read line; do [ "\$line" = uci ] && echo uciok; done\n',
      ),
    );
    expect(
      (slow as EngineRejected).reason,
      'slow did not answer as a UCI engine: no readyok within 1 s',
    );

    final crash = await check(
      await script('crash', '#!/bin/sh\necho "Illegal instruction"\nexit 3\n'),
    );
    expect(
      (crash as EngineRejected).reason,
      'crash crashed while starting (exit code 3)',
    );
    expect(crash.output, ['Illegal instruction']);

    final illegal = await check(await script('illegal', _engine('e2e5')));
    expect(
      (illegal as EngineRejected).reason,
      'Fake 1.0 played an illegal move: e2e5',
    );
    expect(illegal.output, containsAll(['Fake engine banner', 'uciok']));
    expect(engines.pids, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a working engine is verified under its own name', () async {
    final good = await check(await script('good', _engine('e2e4')));
    expect((good as EngineVerified).name, 'Fake 1.0');
    expect(good.move, 'e2e4');
    expect(run.engineReport, 'Fake 1.0: UCI ready; legal move verified.');
  });
}
