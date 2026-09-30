@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// The headless tournament tool the chess-prep MCP server runs. Importing it
// here keeps it compiling against the app's tournament code: a changed
// launcher signature once broke it with nothing to notice.
import '../../tools/run_engine_tournament.dart' as tool;

/// A shell engine that answers the handshake as `Fake 1.0` and plays e2e4.
const _engine = '''#!/bin/sh
while read line; do
  case "\$line" in
    uci) echo "id name Fake 1.0"; echo uciok;;
    isready) echo readyok;;
    go*) echo "bestmove e2e4";;
    quit) exit 0;;
  esac
done
''';

/// Everything written through `stdout.writeln`.
final class _Lines implements Stdout {
  final lines = <String>[];

  @override
  void writeln([Object? object = '']) => lines.add('$object');

  @override
  Future<void> close() async {}

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('tool-'));
  tearDown(() async {
    exitCode = 0;
    await dir.delete(recursive: true);
  });

  Future<Map<String, Object?>> verify(String script) async {
    final path = p.join(dir.path, 'engine');
    await File(path).writeAsString(script);
    await Process.run('chmod', ['+x', path]);
    final out = _Lines();
    await IOOverrides.runZoned(
      () => tool.main(['--root', dir.path, '--verify', path]),
      stdout: () => out,
    );
    await out.close();
    return jsonDecode(out.lines.last) as Map<String, Object?>;
  }

  test('--verify runs the app engine check on a working engine', () async {
    final report = await verify(_engine);
    expect(report['ok'], isTrue);
    expect(report['name'], 'Fake 1.0');
    expect(report['sampleMove'], 'e2e4');
    expect(exitCode, 0);
  });

  test('--verify rejects a program that is not an engine, with what it '
      'wrote', () async {
    final report = await verify('#!/bin/sh\necho "usage: engine"\nexit 3\n');
    expect(report['ok'], isFalse);
    expect(report['message'], 'engine crashed while starting (exit code 3)');
    expect(report['transcript'], ['usage: engine']);
    expect(exitCode, 3);
  });
}
