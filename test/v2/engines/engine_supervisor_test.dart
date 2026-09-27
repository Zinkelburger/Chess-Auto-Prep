import 'dart:io';

import 'package:chess_auto_prep/v2/diagnostics/log.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
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
        startsWith('Could not start no-such-engine: '),
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
        'mute did not answer as a UCI engine',
      );
      expect(engines.pids, isEmpty);
      expect(entries.single.action, 'start mute');
      await dir.delete(recursive: true);
    },
    skip: Platform.isWindows ? 'needs a shell script' : false,
    timeout: const Timeout(Duration(seconds: 30)),
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
