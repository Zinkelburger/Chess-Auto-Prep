import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chess_auto_prep/services/engine/board_engine.dart';
import 'package:chess_auto_prep/services/engine/engine_connection.dart';
import 'package:chess_auto_prep/services/engine/uci_handshake.dart';
import 'package:chess_auto_prep/models/engine_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Native implements EngineConnection {
  final Process process;
  final stream = StreamController<String>.broadcast();
  final commands = <String>[];
  String version = '';
  Native(this.process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.startsWith('id name ')) version = line;
          stream.add(line);
        }, onDone: stream.close);
    unawaited(process.stderr.drain<void>());
  }
  @override
  Stream<String> get stdout => stream.stream;
  @override
  Future<void> get done async {
    await process.exitCode;
  }

  @override
  Future<void> waitForReady() => performUciHandshake(this);
  @override
  void sendCommand(String command) {
    commands.add(command);
    process.stdin.writeln(command);
  }

  bool disposed = false;
  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    process.kill();
  }
}

int ticks(int pid) {
  final stat = File('/proc/$pid/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  return int.parse(fields[11]) + int.parse(fields[12]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final executable = Platform.environment['STOCKFISH_EXECUTABLE'];
  test(
    'native process pauses at zero CPU, reuses PID/config, and exits on last detach',
    () async {
      SharedPreferences.setMockInitialValues({});
      EngineSettings.instance.cores = 2;
      EngineSettings.instance.hashMb = 16;
      final connections = <Native>[];
      final board = BoardEngine(
        createConnection: () async {
          final c = Native(await Process.start(executable!, []));
          connections.add(c);
          return c;
        },
      );
      addTearDown(board.dispose);
      final owner = board.createSession();
      await owner.prepare();
      final native = connections.single;
      final pid = native.process.pid;
      const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
      final progress = Completer<void>();
      final search = owner.discover(
        fen: fen,
        depth: 99,
        multiPv: 3,
        whiteToMove: true,
        onProgress: (r) {
          if (r.depth >= 10 && !progress.isCompleted) progress.complete();
        },
      );
      await progress.future.timeout(const Duration(seconds: 20));
      owner.pause();
      expect(await search, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final before = ticks(pid);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final used = ticks(pid) - before;
      expect(used, 0, reason: 'Stopped native search must use zero CPU ticks');
      final result = await owner.discover(
        fen: fen,
        depth: 10,
        multiPv: 3,
        whiteToMove: true,
      );
      expect(result!.lines, isNotEmpty);
      expect(connections, hasLength(1));
      expect(
        native.commands.where((c) => c.startsWith('setoption name Threads')),
        hasLength(1),
      );
      expect(
        native.commands.where((c) => c.startsWith('setoption name Hash')),
        hasLength(1),
      );
      debugPrint(
        'NATIVE CHECK: ${native.version}; PID=$pid; idle CPU ticks/500ms=$used; reused=${connections.length == 1}; resumedDepth=${result.depth}; lines=${result.lines.length}',
      );
      owner.detach();
      await native.done.timeout(const Duration(seconds: 5));
      debugPrint('NATIVE CHECK: last detach terminated PID $pid');
    },
    skip: executable == null || !Platform.isLinux
        ? 'Set STOCKFISH_EXECUTABLE on Linux for the native CPU check'
        : false,
  );
}
