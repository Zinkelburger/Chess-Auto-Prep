import 'dart:async';

import 'package:chess_auto_prep/v2/features/settings/integrity_dialog.dart';
import 'package:chess_auto_prep/v2/storage/integrity_report.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('dialog distinguishes skipped checks from clean and can retry', (
    tester,
  ) async {
    final reader = _Reader();
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: IntegrityDialog(reader: reader)),
      ),
    );
    expect(find.text('Checking saved data…'), findsOneWidget);
    reader.pending.complete(
      _report(skipped: ['Book references need recovery first.']),
    );
    await tester.pumpAndSettle();
    expect(find.text('Findings: 0; checks skipped: 1.'), findsOneWidget);
    expect(
      find.text('No problems found in the checks completed.'),
      findsNothing,
    );
    expect(find.textContaining('Skipped:'), findsOneWidget);
    expect(
      find.textContaining('Files are checked individually'),
      findsOneWidget,
    );
    reader.pending = Completer<IntegrityReport>();
    await tester.tap(find.text('Check again'));
    await tester.pump();
    expect(reader.reads, 2);
    reader.pending.complete(_report());
    await tester.pumpAndSettle();
    expect(
      find.text('No problems found in the checks completed.'),
      findsOneWidget,
    );
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
  Future<IntegrityReport> read({bool Function()? isCancelled}) {
    reads++;
    return pending.future;
  }
}
