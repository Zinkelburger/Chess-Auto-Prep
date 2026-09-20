import 'dart:io';

import 'package:chess_auto_prep/v2/diagnostics/log.dart';
import 'package:chess_auto_prep/v2/storage/log_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('v2-log-');
  });

  tearDown(() => root.delete(recursive: true));

  LogEntry entry(String action) => LogEntry(
    time: DateTime(2026, 9, 19, 12),
    level: LogLevel.error,
    action: action,
  );

  test('appends a line per entry across runs', () async {
    final logs = Directory(p.join(root.path, 'logs'));
    var file = LogFile(logs);
    (await file.open())(entry('first run'));
    await file.close();
    file = LogFile(logs);
    (await file.open())(entry('second run'));
    await file.close();
    final lines = await file.file.readAsLines();
    expect(lines, [
      '2026-09-19T12:00:00.000 E first run',
      '2026-09-19T12:00:00.000 E second run',
    ]);
  });

  test('a large log is rotated once on open', () async {
    final logs = Directory(p.join(root.path, 'logs'));
    var file = LogFile(logs, rotateAt: 10);
    (await file.open())(entry('an entry longer than ten bytes'));
    await file.close();
    file = LogFile(logs, rotateAt: 10);
    (await file.open())(entry('fresh'));
    await file.close();
    expect(await file.file.readAsLines(), hasLength(1));
    expect(await File('${file.file.path}.1').readAsLines(), [
      '2026-09-19T12:00:00.000 E an entry longer than ten bytes',
    ]);
  });
}
