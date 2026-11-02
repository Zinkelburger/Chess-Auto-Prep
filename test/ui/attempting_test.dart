import 'dart:async';

import 'package:chess_auto_prep/diagnostics/log.dart';
import 'package:chess_auto_prep/ui/attempting.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with Attempting<_Probe> {
  Future<int?> run(Future<int> Function() work) =>
      attempt('probe work', work, failure: 'Could not do it.');

  @override
  Widget build(BuildContext context) =>
      Text(busy ? 'busy' : problem ?? 'idle', textDirection: TextDirection.ltr);
}

void main() {
  _ProbeState probe(WidgetTester tester) =>
      tester.state<_ProbeState>(find.byType(_Probe));

  testWidgets('holds busy while the work runs and refuses a second', (
    tester,
  ) async {
    await tester.pumpWidget(const _Probe());
    final done = Completer<int>();
    final first = probe(tester).run(() => done.future);
    await tester.pump();
    expect(find.text('busy'), findsOneWidget);
    expect(await probe(tester).run(() async => 2), isNull);
    done.complete(1);
    expect(await first, 1);
    await tester.pump();
    expect(find.text('idle'), findsOneWidget);
  });

  testWidgets('a failure is logged and said, and cleared by the next try', (
    tester,
  ) async {
    final entries = <LogEntry>[];
    log.install(entries.add);
    addTearDown(() => log.remove(entries.add));
    await tester.pumpWidget(const _Probe());
    expect(await probe(tester).run(() async => throw StateError('x')), isNull);
    await tester.pump();
    expect(find.text('Could not do it.'), findsOneWidget);
    expect(entries.single.action, 'probe work');
    expect(await probe(tester).run(() async => 3), 3);
    await tester.pump();
    expect(find.text('idle'), findsOneWidget);
  });

  testWidgets('answers null once the state has gone', (tester) async {
    await tester.pumpWidget(const _Probe());
    final done = Completer<int>();
    final result = probe(tester).run(() => done.future);
    await tester.pumpWidget(const SizedBox());
    done.complete(4);
    expect(await result, isNull);
  });
}
