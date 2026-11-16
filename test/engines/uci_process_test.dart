import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/engines/uci_process.dart';
import 'package:flutter_test/flutter_test.dart';

/// A child process whose two output streams the test writes.
final class _Talking implements Process {
  final out = StreamController<List<int>>();
  final err = StreamController<List<int>>();
  final _exit = Completer<int>();

  @override
  Stream<List<int>> get stdout => out.stream;
  @override
  Stream<List<int>> get stderr => err.stream;
  @override
  IOSink get stdin => IOSink(_Ignored());
  @override
  int get pid => 99;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) _exit.complete(137);
    return true;
  }

  Future<void> end() async {
    unawaited(out.close());
    unawaited(err.close());
    if (!_exit.isCompleted) _exit.complete(0);
  }
}

final class _Ignored implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain();
  @override
  Future<void> close() async {}
}

void main() {
  Future<(SpawnedProcess, _Talking)> spawned() async {
    final child = _Talking();
    final process = await SpawnedProcess.start(
      'engine',
      startProcess:
          (executable, arguments, {workingDirectory, environment}) async =>
              child,
    );
    return (process, child);
  }

  test('standard error keeps its last twenty lines; the transcript keeps the '
      'first forty of both streams', () async {
    final (process, child) = await spawned();
    for (var i = 0; i < 50; i++) {
      child.err.add(utf8.encode('error $i\n'));
    }
    await pumpEventQueue();
    expect(process.recentErrors, [for (var i = 30; i < 50; i++) 'error $i']);
    expect(process.transcript.lines, [for (var i = 0; i < 40; i++) 'error $i']);
    await child.end();
  });

  test(
    'bytes that are not UTF-8 are read on either stream, not lost',
    () async {
      final (process, child) = await spawned();
      final read = process.lines.toList();
      child.out.add([...utf8.encode('id name Caf'), 0xE9, 10]);
      child.err.add([...utf8.encode('chemin '), 0xE9, 10]);
      await pumpEventQueue();
      await child.end();
      expect((await read).single, startsWith('id name Caf'));
      expect(process.recentErrors.single, startsWith('chemin '));
    },
  );
}
