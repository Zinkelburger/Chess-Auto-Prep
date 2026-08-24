@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:chess_auto_prep/features/engine_tournament/services/engine_verification.dart';
import 'package:flutter_test/flutter_test.dart';

/// Short, because every one of these cases is meant to *fail* fast — the
/// point of the check is that a wrong pick is reported, not waited on.
const _quick = Duration(milliseconds: 400);

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('engine_verification_test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('a path that is not there says so', () async {
    final report = await verifyUciEngine('${temp.path}/nope');
    expect(report.ok, isFalse);
    expect(report.message, contains('No such file'));
  });

  test('a directory is not an engine', () async {
    final report = await verifyUciEngine(temp.path);
    expect(report.ok, isFalse);
    expect(report.message, contains('folder'));
  });

  test('a file without the execute bit is called out as such', () async {
    final file = File('${temp.path}/engine');
    await file.writeAsString('#!/bin/sh\n');
    final report = await verifyUciEngine(file.path);
    expect(report.ok, isFalse);
    expect(report.message, contains('not executable'));
  });

  test('a binary that exits immediately is reported, not waited on', () async {
    final file = File('${temp.path}/quitter');
    await file.writeAsString('#!/bin/sh\nexit 0\n');
    await Process.run('chmod', ['+x', file.path]);
    final report = await verifyUciEngine(file.path, handshakeTimeout: _quick);
    expect(report.ok, isFalse);
    expect(report.message, isNotEmpty);
  });

  test('a program that never answers "uci" is not a UCI engine', () async {
    // `cat` speaks back but says nothing of its own — exactly what a
    // non-engine looks like from the outside.
    final file = File('${temp.path}/silent');
    await file.writeAsString('#!/bin/sh\nexec cat\n');
    await Process.run('chmod', ['+x', file.path]);
    final report = await verifyUciEngine(file.path, handshakeTimeout: _quick);
    expect(report.ok, isFalse);
    expect(report.message, contains('not a UCI engine'));
  });

  test('speaking UCI but not playing chess is still a failure', () async {
    // Answers the handshake, then offers a move that is not legal.
    final file = File('${temp.path}/liar');
    await file.writeAsString('''
#!/bin/sh
while read -r line; do
  case "\$line" in
    uci) echo "id name Liar"; echo "id author test"; echo "uciok" ;;
    isready) echo "readyok" ;;
    go*) echo "bestmove e2e5" ;;
    quit) exit 0 ;;
  esac
done
''');
    await Process.run('chmod', ['+x', file.path]);
    final report = await verifyUciEngine(
      file.path,
      handshakeTimeout: const Duration(seconds: 5),
      moveTimeout: const Duration(seconds: 5),
    );
    expect(report.ok, isFalse);
    expect(report.name, 'Liar');
    expect(report.message, contains('not a legal move'));
  });

  test('a well-behaved engine passes and reports its identity', () async {
    final file = File('${temp.path}/toy');
    await file.writeAsString('''
#!/bin/sh
while read -r line; do
  case "\$line" in
    uci)
      echo "id name Toy Engine 1.0"
      echo "id author Nobody"
      echo "option name Hash type spin default 16 min 1 max 1024"
      echo "option name Threads type spin default 1 min 1 max 8"
      echo "uciok"
      ;;
    isready) echo "readyok" ;;
    go*) echo "info depth 1 score cp 12 pv e2e4"; echo "bestmove e2e4" ;;
    quit) exit 0 ;;
  esac
done
''');
    await Process.run('chmod', ['+x', file.path]);
    final report = await verifyUciEngine(
      file.path,
      handshakeTimeout: const Duration(seconds: 5),
      moveTimeout: const Duration(seconds: 5),
    );
    expect(report.ok, isTrue, reason: report.message);
    expect(report.name, 'Toy Engine 1.0');
    expect(report.author, 'Nobody');
    expect(report.sampleMove, 'e4');
    expect(report.supportsHash, isTrue);
    expect(report.supportsThreads, isTrue);
    expect(report.supportsMultiPv, isFalse);
  });
}
