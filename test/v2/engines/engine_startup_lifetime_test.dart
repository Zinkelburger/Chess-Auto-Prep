import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/engine.dart';
import 'package:chess_auto_prep/v2/engines/hivemind_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late File executable;
  late File announced;
  late EngineSupervisor supervisor;
  Future<EngineStart>? starting;
  Future<HivemindStart>? bughouseStarting;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('v2-startup-lifetime-');
    executable = File(p.join(root.path, 'engine'));
    announced = File(p.join(root.path, 'pid'));
    supervisor = EngineSupervisor();
    starting = null;
    bughouseStarting = null;
  });

  tearDown(() async {
    // The red baseline does not own a handshaking process yet. Keep cleanup
    // explicit so even a failing regression leaves no native child behind.
    if (await announced.exists()) {
      Process.killPid(
        int.parse(await announced.readAsString()),
        ProcessSignal.sigkill,
      );
    }
    await supervisor.dispose();
    await starting;
    await bughouseStarting;
    await root.delete(recursive: true);
  });

  Future<void> writeEngine({
    bool handshake = false,
    bool closeOutput = false,
  }) async {
    await executable.writeAsString('''#!/usr/bin/env python3
import os, pathlib, sys, time
pathlib.Path(${jsonEncode(announced.path)}).write_text(str(os.getpid()))
for line in sys.stdin:
    line = line.strip()
    if line == 'uci' and ${handshake ? 'True' : 'False'}:
        print('uciok', flush=True)
    elif line == 'isready' and ${handshake ? 'True' : 'False'}:
        print('readyok', flush=True)
        if ${closeOutput ? 'True' : 'False'}:
            os.close(1)
    elif line == 'quit':
        break
''');
    await Process.run('chmod', ['+x', executable.path]);
  }

  Future<int> pid() async {
    final until = DateTime.now().add(const Duration(seconds: 5));
    while (!await announced.exists()) {
      if (DateTime.now().isAfter(until)) fail('engine did not start');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return int.parse(await announced.readAsString());
  }

  test(
    'dispose owns a spawned process throughout its handshake',
    () async {
      await writeEngine();
      starting = supervisor.start(executable.path);
      final child = await pid();
      expect(await Directory('/proc/$child').exists(), isTrue);
      await supervisor.dispose();
      expect(await Directory('/proc/$child').exists(), isFalse);
      expect(await starting, isA<StartFailed>());
      expect(supervisor.pids, isEmpty);
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'dispose waits for an accepted start whose spawn has not returned',
    () async {
      await writeEngine();
      starting = supervisor.start(executable.path);
      await supervisor.dispose();
      // Completion propagation can precede sibling listeners; a zero-timeout
      // await checks the accepted startup itself instead of their ordering.
      expect(await starting!.timeout(Duration.zero), isA<StartFailed>());
      if (await announced.exists()) {
        expect(await Directory('/proc/${await pid()}').exists(), isFalse);
      }
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test('start after disposal launches no process', () async {
    await writeEngine(handshake: true);
    await supervisor.dispose();
    starting = supervisor.start(executable.path);
    expect(await starting, isA<StartFailed>());
    expect(await announced.exists(), isFalse);
  }, skip: !Platform.isLinux);

  test('stdout closing is not native process exit', () async {
    await writeEngine(handshake: true, closeOutput: true);
    starting = supervisor.start(executable.path);
    expect(await starting, isA<Started>());
    final child = await pid();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(supervisor.pids, contains(child));
    await supervisor.dispose();
    expect(await Directory('/proc/$child').exists(), isFalse);
  }, skip: !Platform.isLinux);
  test('native first finite search uses its configured deadline', () async {
    await writeEngine(handshake: true);
    starting = supervisor.start(
      executable.path,
      finitePatience: const Duration(milliseconds: 75),
    );
    final engine = (await starting as Started).engine;
    final child = await pid();
    await expectLater(
      engine.analyse(Fen.initial, multiPv: 1, depth: 60).lines.drain<void>(),
      throwsA(isA<EngineFailure>()),
    );
    expect(await engine.exited, EngineExit.unresponsive);
    expect(await Directory('/proc/$child').exists(), isFalse);
    await supervisor.dispose();
    expect(supervisor.pids, isEmpty);
  }, skip: !Platform.isLinux);

  test('invalid finite deadline is refused before native spawn', () async {
    await writeEngine(handshake: true);
    starting = supervisor.start(executable.path, finitePatience: Duration.zero);
    expect(await starting, isA<StartFailed>());
    expect(await announced.exists(), isFalse);
  }, skip: !Platform.isLinux);
  test('dispose owns Hivemind through its native handshake', () async {
    await writeEngine();
    final model = await File(p.join(root.path, 'model')).writeAsString('model');
    bughouseStarting = supervisor.startHivemind((
      executable: executable.path,
      model: model.path,
      directory: root.path,
    ), cores: 1);
    final child = await pid();
    await supervisor.dispose();
    expect(await bughouseStarting, isA<HivemindStartFailed>());
    expect(await Directory('/proc/$child').exists(), isFalse);
    expect(supervisor.pids, isEmpty);
  }, skip: !Platform.isLinux);

  test(
    'dispose during Hivemind hashing prevents a later native spawn',
    () async {
      await writeEngine();
      final model = await File(
        p.join(root.path, 'model'),
      ).writeAsString('model');
      bughouseStarting = supervisor.startHivemind((
        executable: executable.path,
        model: model.path,
        directory: root.path,
      ), cores: 1);
      await supervisor.dispose();
      expect(
        await bughouseStarting!.timeout(Duration.zero),
        isA<HivemindStartFailed>(),
      );
      expect(await announced.exists(), isFalse);
    },
    skip: !Platform.isLinux,
  );
}
