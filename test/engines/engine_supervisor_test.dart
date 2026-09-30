import 'dart:io';

import 'package:chess_auto_prep/diagnostics/log.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/engines/hivemind_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
      final start = engines.startHivemind((
        executable: fifo,
        model: p.join(dir.path, 'model'),
        directory: dir.path,
      ), cores: 1);
      addTearDown(() async {
        // Lets the blocked read end, and the start with it, so nothing
        // outlives the test.
        await Process.run('timeout', ['5', 'sh', '-c', ': > "\$0"', fifo]);
        expect(
          await start.timeout(const Duration(seconds: 5)),
          isA<HivemindStartFailed>(),
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
}
