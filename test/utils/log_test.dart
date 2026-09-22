import 'dart:io';

import 'package:chess_auto_prep/infrastructure/diagnostics/app_log_file.dart';
import 'package:chess_auto_prep/utils/app_messages.dart';
import 'package:chess_auto_prep/utils/log.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> written;

  setUp(() {
    written = [];
    Log.sink = written.add;
    addTearDown(() => Log.sink = null);
  });

  test('warnings and errors reach the sink; debug and info do not', () {
    log.d('starting up');
    log.i('ready');
    log.w('slow');
    log.e('broken', name: 'Downloads', error: StateError('no route'));

    expect(written, hasLength(2));
    expect(written.first, contains('WARN'));
    expect(written.first, contains('slow'));
    expect(written.last, contains('ERROR Downloads: broken'));
    expect(written.last, contains('Bad state: no route'));
  });

  test('a line carries the time, the level and a bounded stack', () {
    final line = formatLogLine(
      LogLevel.error,
      'Startup failed',
      name: 'Startup',
      error: 'boom',
      stackTrace: StackTrace.fromString(
        List.generate(40, (i) => '#$i frame $i').join('\n'),
      ),
      at: DateTime(2026, 9, 19, 14, 42, 10),
    );

    expect(
      line,
      startsWith(
        '2026-09-19 14:42:10 ERROR Startup: Startup '
        'failed',
      ),
    );
    expect(line, contains('\n  boom'));
    expect(line, contains('#0 frame 0'));
    expect(line, isNot(contains('#12 frame 12')));
  });

  test('a sink that throws never reaches the caller', () {
    Log.sink = (_) => throw const FileSystemException('disk full');
    expect(() => log.e('still reported'), returnsNormally);
  });

  testWidgets('an error the user is shown is logged with it', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              context = ctx;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    showAppSnackBar(context, 'Could not reach Chess.com.', isError: true);
    showAppSnackBar(context, 'Add an account first.', requiresAttention: true);
    await tester.pumpAndSettle();

    expect(written, hasLength(1));
    expect(written.single, contains('WARN UI: Could not reach Chess.com.'));
  });

  group('AppLogFile', () {
    late Directory folder;

    setUp(() {
      folder = Directory.systemTemp.createTempSync('app-log-');
      addTearDown(() => folder.deleteSync(recursive: true));
    });

    test('appends lines in order', () async {
      final target = File('${folder.path}/app.log');
      final sink = AppLogFile(target)
        ..write('first')
        ..write('second');
      await sink.flush();

      expect(target.readAsStringSync(), 'first\nsecond\n');
    });

    test('rotates into app.log.1 and keeps only one previous log', () async {
      final target = File('${folder.path}/app.log');
      final sink = AppLogFile(target, maxBytes: 20);
      for (final line in ['aaaaaaaaaa', 'bbbbbbbbbb', 'cccccccccc']) {
        sink.write(line);
      }
      await sink.flush();

      expect(target.readAsStringSync(), 'cccccccccc\n');
      expect(File('${target.path}.1').readAsStringSync(), 'bbbbbbbbbb\n');
      expect(File('${target.path}.2').existsSync(), isFalse);
    });

    test('a write that cannot land leaves the app alone', () async {
      final sink = AppLogFile(File('${folder.path}/missing/app.log'));
      sink.write('into the void');
      await expectLater(sink.flush(), completes);
    });
  });
}
