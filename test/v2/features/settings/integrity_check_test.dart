import 'dart:async';

import 'package:chess_auto_prep/v2/features/settings/integrity_check.dart';
import 'package:chess_auto_prep/v2/storage/integrity_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'read lifetime rejects overlap and ignores delivery after disposal',
    () async {
      final reader = _Reader();
      final owner = IntegrityCheck(reader);
      var notifications = 0;
      owner.addListener(() => notifications++);
      final reading = owner.refresh();
      await owner.refresh();
      expect(reader.reads, 1);
      expect(owner.reading, isTrue);
      owner.dispose();
      reader.pending.complete(_report());
      await reading;
      expect(owner.report, isNull);
      expect(notifications, 1);
      await owner.refresh();
      expect(reader.reads, 1);
    },
  );

  test('failed refresh retains a dated prior report and safe retry', () async {
    final reader = _Reader();
    final owner = IntegrityCheck(reader);
    addTearDown(owner.dispose);
    final first = owner.refresh();
    final report = _report();
    reader.pending.complete(report);
    await first;
    reader.pending = Completer<IntegrityReport>();
    final failing = owner.refresh();
    reader.pending.completeError(const FormatException('secret source'));
    await failing;
    expect(owner.report, same(report));
    expect(owner.problem, contains('could not finish'));
    expect(owner.problem, isNot(contains('secret')));
    reader.pending = Completer<IntegrityReport>();
    final retry = owner.refresh();
    reader.pending.complete(_report());
    await retry;
    expect(owner.problem, isNull);
    expect(reader.reads, 3);
  });
}

IntegrityReport _report({List<String> skipped = const []}) => IntegrityReport(
  checkedAt: DateTime(2026),
  findings: const [],
  checked: const ['Book references'],
  skipped: skipped,
);

final class _Reader implements IntegrityReader {
  Completer<IntegrityReport> pending = Completer<IntegrityReport>();
  int reads = 0;
  @override
  Future<IntegrityReport> read() {
    reads++;
    return pending.future;
  }
}
