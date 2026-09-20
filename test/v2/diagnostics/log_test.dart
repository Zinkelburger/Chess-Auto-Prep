import 'package:chess_auto_prep/v2/diagnostics/log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('entries reach every installed sink, with the level and action', () {
    final log = Log();
    final seen = <LogEntry>[];
    log.install(seen.add);
    log.i('start');
    log.w('open /x/Main.pgn', 'Main is no longer on disk');
    log.e('start stockfish-linux', 'No such file');
    expect(seen.map((e) => e.level), [
      LogLevel.info,
      LogLevel.warning,
      LogLevel.error,
    ]);
    expect(seen[2].line, endsWith(' E start stockfish-linux: No such file'));
    expect(seen[0].line, endsWith(' I start'));
  });

  test('a line carries an ISO timestamp first', () {
    final entry = LogEntry(
      time: DateTime(2026, 9, 19, 20, 31, 4, 123),
      level: LogLevel.warning,
      action: 'list repertoires',
      error: 'Permission denied',
    );
    expect(
      entry.line,
      '2026-09-19T20:31:04.123 W list repertoires: Permission denied',
    );
  });
}
