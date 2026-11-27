import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/diagnostics/log.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/hypebeast_engine.dart';
import 'package:chess_auto_prep/engines/hypebeast_install.dart'
    show HypeBeastFiles;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A process SIGKILL does not end, as one stuck in the kernel on a GPU
/// driver is: it says nothing and never exits.
final class StuckProcess implements Process {
  @override
  IOSink get stdin => IOSink(_Ignored());
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  int get pid => 0;
  @override
  Future<int> get exitCode => Completer<int>().future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

/// The first signal leaves this process alive; the next one ends it.
final class _SurvivesFirstKill extends StuckProcess {
  final exit = Completer<int>();
  int kills = 0;

  @override
  int get pid => 4100;

  @override
  Future<int> get exitCode => exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (++kills == 2) exit.complete(137);
    return true;
  }
}

/// Takes what is written and keeps none of it.
final class _Ignored implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();
  @override
  Future<void> close() async {}
}

void main() {
  final entries = <LogEntry>[];

  setUp(() {
    entries.clear();
    log.install(entries.add);
  });

  tearDown(() => log.remove(entries.add));

  test(
    'an executable that is not there is a sentence and a log line',
    () async {
      final missing = p.join(Directory.systemTemp.path, 'no-such-engine');
      final start = await EngineSupervisor().start(missing);
      expect(
        (start as StartFailed).reason,
        'no-such-engine is not there: $missing',
      );
      expect(entries.single.level, LogLevel.error);
      expect(entries.single.action, 'start no-such-engine');
    },
  );

  test(
    'a program that is not a UCI engine is killed and reported',
    () async {
      final dir = await Directory.systemTemp.createTemp('v2-engine-');
      final fake = File(p.join(dir.path, 'mute'));
      await fake.writeAsString('#!/bin/sh\nsleep 30\n');
      await Process.run('chmod', ['+x', fake.path]);
      final engines = EngineSupervisor();
      final start = await engines.start(
        fake.path,
        patience: const Duration(seconds: 1),
      );
      expect(
        (start as StartFailed).reason,
        'mute did not answer as a UCI engine: no uciok within 1 s',
      );
      expect(engines.pids, isEmpty);
      expect(entries.single.action, 'start mute');
      await dir.delete(recursive: true);
    },
    skip: Platform.isWindows ? 'needs a shell script' : false,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'closing does not wait without limit for a start that never returns',
    () async {
      // Reading a pipe nobody writes blocks like an engine on a hung network
      // mount: hashing the "engine" before its spawn never finishes.
      final dir = await Directory.systemTemp.createTemp('v2-engine-');
      final fifo = p.join(dir.path, 'hung');
      await Process.run('mkfifo', [fifo]);
      final engines = EngineSupervisor(
        closingPatience: const Duration(milliseconds: 200),
      );
      final start = engines.startHypeBeast((
        executable: fifo,
        net: p.join(dir.path, 'net'),
        directory: dir.path,
      ));
      addTearDown(() async {
        // Lets the blocked read end, and the start with it, so nothing
        // outlives the test.
        await Process.run('timeout', ['5', 'sh', '-c', ': > "\$0"', fifo]);
        expect(
          await start.timeout(const Duration(seconds: 5)),
          isA<HypeBeastStartFailed>(),
        );
        await dir.delete(recursive: true);
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final clock = Stopwatch()..start();
      await engines.dispose();
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      expect(entries.map((entry) => entry.action), contains('close engines'));
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test('a failed handshake stays supervised until the process exits', () {
    fakeAsync((time) {
      final child = _SurvivesFirstKill();
      final engines = EngineSupervisor(
        startProcess: (_, _, {workingDirectory, environment}) async => child,
      );
      EngineStart? result;
      unawaited(
        engines
            .start('engine', patience: const Duration(seconds: 1))
            .then((value) => result = value),
      );
      time.elapse(const Duration(seconds: 6));
      expect(result, isA<StartFailed>());
      expect(child.exit.isCompleted, isFalse);
      expect(engines.pids, contains(child.pid));
      unawaited(engines.dispose());
      time.flushMicrotasks();
      expect(child.kills, 2);
      expect(child.exit.isCompleted, isTrue);
      expect(engines.pids, isEmpty);
    });
  });

  test('engine hashes are worked out once per file version and a missing '
      'file is no hash, not a failed start', () async {
    final dir = await Directory.systemTemp.createTemp('hash-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(p.join(dir.path, 'engine'));
    await file.writeAsString('one');
    final first = await fileSha256(file.path);
    expect(first, hasLength(64));
    expect(await fileSha256(file.path), first);
    await file.writeAsString('two, longer');
    expect(await fileSha256(file.path), isNot(first));
    expect(await fileSha256(p.join(dir.path, 'missing')), isNull);
  });

  test('a bughouse engine that failed to start and outlives its kill still '
      'answers that it did not start', () async {
    final dir = await Directory.systemTemp.createTemp('hypebeast-');
    addTearDown(() => dir.delete(recursive: true));
    final HypeBeastFiles files = (
      executable: p.join(dir.path, 'hypebeast'),
      net: p.join(dir.path, 'net'),
      directory: dir.path,
    );
    await File(files.executable).writeAsString('');
    await File(files.net).writeAsString('');
    final engines = EngineSupervisor(
      startProcess: (_, _, {workingDirectory, environment}) async =>
          StuckProcess(),
    );
    // The kill waits five seconds and the exit code one more.
    final start = await engines
        .startHypeBeast(files, patience: const Duration(milliseconds: 100))
        .timeout(const Duration(seconds: 10));
    expect(
      (start as HypeBeastStartFailed).reason,
      startsWith('The bughouse engine did not start.'),
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a Windows loader failure is said in words; another exit is not', () {
    expect(engineExitReason(-1073741515), contains('0xC0000135'));
    expect(engineExitReason(0xC000001D), contains('instruction'));
    expect(engineExitReason(1), isNull);
    expect(engineExitReason(null), isNull);
  });

  test('an engine that answers only after the app began closing is let go, not '
      'kept', () async {
    final folder = await Directory.systemTemp.createTemp('late-engine');
    addTearDown(() => folder.delete(recursive: true));
    final script = File(p.join(folder.path, 'late'))
      ..writeAsStringSync('''#!/bin/sh
while read -r line; do
  case "\$line" in
    uci) sleep 1; echo "id name Late"; echo "uciok" ;;
    isready) echo "readyok" ;;
    quit) exit 0 ;;
  esac
done
''');
    await Process.run('chmod', ['+x', script.path]);
    final engines = EngineSupervisor();
    final starting = engines.start(script.path);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await engines.dispose();
    expect(await starting, isA<StartFailed>());
  }, skip: !Platform.isLinux);
}
