import 'dart:io';

import 'package:chess_auto_prep/diagnostics/log.dart';
import 'package:chess_auto_prep/storage/log_file.dart';
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

  test('a log that fills up during a session stops at one line', () async {
    final logs = Directory(p.join(root.path, 'logs'));
    final file = LogFile(logs, rotateAt: 100);
    final write = await file.open();
    for (var i = 0; i < 50; i++) {
      write(entry('entry $i'));
    }
    await file.close();
    // 34 bytes a line: the third passes 100, and then only the notice.
    final lines = await file.file.readAsLines();
    expect(lines, hasLength(4));
    expect(lines[2], endsWith('entry 2'));
    expect(lines.last, endsWith(' W log capped for this session'));
  });

  test(
    'a log near the rotation size still takes a session of entries',
    () async {
      final logs = Directory(p.join(root.path, 'logs'));
      await logs.create();
      // 99 bytes: below rotateAt, so the file is kept as it is.
      await File(p.join(logs.path, 'app.log')).writeAsString('${'x' * 98}\n');
      final file = LogFile(logs, rotateAt: 100);
      final write = await file.open();
      write(entry('entry 0'));
      write(entry('entry 1'));
      await file.close();
      final lines = await file.file.readAsLines();
      expect(lines.skip(1), [
        '2026-09-19T12:00:00.000 E entry 0',
        '2026-09-19T12:00:00.000 E entry 1',
      ]);
    },
  );

  test('a session adds at most rotateAt to a log it did not rotate', () async {
    final logs = Directory(p.join(root.path, 'logs'));
    await logs.create();
    await File(p.join(logs.path, 'app.log')).writeAsString('${'x' * 98}\n');
    final file = LogFile(logs, rotateAt: 100);
    final write = await file.open();
    for (var i = 0; i < 50; i++) {
      write(entry('entry $i'));
    }
    await file.close();
    const entryBytes = 34;
    const noticeBytes =
        '2026-09-19T12:00:00.000 W log capped for this session\n'.length;
    expect(
      await file.file.length(),
      lessThanOrEqualTo(99 + 100 + entryBytes + noticeBytes),
    );
    final lines = await file.file.readAsLines();
    expect(lines.last, endsWith(' W log capped for this session'));
  });

  test('a log rotates past two megabytes by default', () {
    expect(LogFile(root).rotateAt, 2 * 1024 * 1024);
  });

  test('a logs folder not made yet is made, parents and all', () async {
    final file = LogFile(Directory(p.join(root.path, 'a', 'logs')));
    (await file.open())(entry('first'));
    await file.close();
    expect(await file.file.readAsLines(), hasLength(1));
  });

  test('a log of exactly the rotation size is kept as it is', () async {
    final logs = await Directory(p.join(root.path, 'logs')).create();
    await File(p.join(logs.path, 'app.log')).writeAsString('${'x' * 99}\n');
    final file = LogFile(logs, rotateAt: 100);
    await file.open();
    await file.close();
    expect(File('${file.file.path}.1').existsSync(), isFalse);
  });

  test('a session stops once it has written the rotation size', () async {
    final logs = Directory(p.join(root.path, 'logs'));
    // 34 bytes a line.
    for (final (rotateAt, kept) in [(35, 2), (68, 2), (69, 3)]) {
      final file = LogFile(logs, rotateAt: rotateAt);
      if (file.file.existsSync()) file.file.deleteSync();
      final write = await file.open();
      for (var i = 0; i < 5; i++) {
        write(entry('entry $i'));
      }
      await file.close();
      final lines = await file.file.readAsLines();
      expect(lines, hasLength(kept + 1), reason: '$rotateAt');
      expect(lines.last, endsWith(' W log capped for this session'));
    }
  });

  test('a log that could not be opened still closes', () async {
    final logs = Directory(p.join(root.path, 'logs'));
    await Directory(p.join(logs.path, 'app.log')).create(recursive: true);
    final file = LogFile(logs);
    (await file.open())(entry('nowhere to go'));
    await pumpEventQueue();
    await expectLater(
      file.close().timeout(const Duration(seconds: 5)),
      completes,
    );
  });
}
